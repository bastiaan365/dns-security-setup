#!/usr/bin/env bash
# =============================================================================
# install.sh - DNS Security Setup Installer
# =============================================================================
# Installs Unbound configuration, blocklist scripts, and monitoring configs
# for a privacy-first DNS resolver.
#
# Usage:
#   sudo ./install.sh [OPTIONS]
#
# Options:
#   --dry-run       Show what would be done without making changes.
#   --no-monitoring Skip Telegraf/monitoring config installation.
#   --no-blocklist  Skip blocklist setup and cron job.
#   --unbound-dir   Unbound config directory (default: /etc/unbound).
#   --help          Show this help message.
#
# Requirements:
#   - Root privileges (or sudo)
#   - Unbound installed (apt install unbound / yum install unbound)
#   - curl (for blocklist downloads)
#   - Optional: Telegraf (for monitoring)
# =============================================================================

set -euo pipefail

# --- Configuration ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNBOUND_DIR="/etc/unbound"
UNBOUND_LOG_DIR="/var/log/unbound"
BLOCKLIST_INSTALL_DIR="/opt/dns-security-setup/blocklists"
TELEGRAF_DIR="/etc/telegraf/telegraf.d"
CRON_FILE="/etc/cron.d/dns-blocklist-update"
DRY_RUN=false
INSTALL_MONITORING=true
INSTALL_BLOCKLIST=true

# --- Colors (if terminal supports them) ---------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# --- Functions ----------------------------------------------------------------

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[-]${NC} $*" >&2; }
info()    { echo -e "${BLUE}[i]${NC} $*"; }

run() {
    if [[ "${DRY_RUN}" == true ]]; then
        info "DRY RUN: $*"
    else
        "$@"
    fi
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    if ! command -v unbound >/dev/null 2>&1; then
        missing+=("unbound")
    fi

    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required packages: ${missing[*]}"
        info "Install them with:"
        info "  Debian/Ubuntu: apt install ${missing[*]}"
        info "  RHEL/CentOS:   yum install ${missing[*]}"
        exit 1
    fi

    if [[ "${INSTALL_MONITORING}" == true ]] && ! command -v telegraf >/dev/null 2>&1; then
        warn "Telegraf is not installed. Monitoring config will be copied but not activated."
        warn "Install Telegraf: https://docs.influxdata.com/telegraf/latest/install/"
    fi
}

# --- Argument Parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-monitoring)
            INSTALL_MONITORING=false
            shift
            ;;
        --no-blocklist)
            INSTALL_BLOCKLIST=false
            shift
            ;;
        --unbound-dir)
            UNBOUND_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Pre-flight Checks -------------------------------------------------------

echo ""
echo "=========================================="
echo "  DNS Security Setup - Installer"
echo "=========================================="
echo ""

if [[ "${DRY_RUN}" == true ]]; then
    warn "DRY RUN MODE - No changes will be made."
    echo ""
fi

check_root
check_dependencies

# --- Step 1: Install Unbound Configuration ------------------------------------

log "Installing Unbound configuration..."

# Create unbound config directory if needed
run mkdir -p "${UNBOUND_DIR}"

# Back up existing configuration
if [[ -f "${UNBOUND_DIR}/unbound.conf" && "${DRY_RUN}" == false ]]; then
    BACKUP="${UNBOUND_DIR}/unbound.conf.bak.$(date +%Y%m%d%H%M%S)"
    warn "Existing unbound.conf found. Backing up to: ${BACKUP}"
    cp "${UNBOUND_DIR}/unbound.conf" "${BACKUP}"
fi

# Copy configuration files
run cp "${SCRIPT_DIR}/unbound/unbound.conf" "${UNBOUND_DIR}/unbound.conf"
run cp "${SCRIPT_DIR}/unbound/dns-over-tls.conf" "${UNBOUND_DIR}/dns-over-tls.conf"
run cp "${SCRIPT_DIR}/unbound/dnssec.conf" "${UNBOUND_DIR}/dnssec.conf"

# Set permissions
run chmod 644 "${UNBOUND_DIR}/unbound.conf"
run chmod 644 "${UNBOUND_DIR}/dns-over-tls.conf"
run chmod 644 "${UNBOUND_DIR}/dnssec.conf"

# Create log directory
run mkdir -p "${UNBOUND_LOG_DIR}"
run chown unbound:unbound "${UNBOUND_LOG_DIR}" 2>/dev/null || true

log "Unbound configuration installed to ${UNBOUND_DIR}/"

# --- Step 2: Bootstrap DNSSEC Trust Anchor ------------------------------------

log "Bootstrapping DNSSEC root trust anchor..."

if command -v unbound-anchor >/dev/null 2>&1; then
    # unbound-anchor returns 1 if the anchor was updated, 0 if unchanged
    run unbound-anchor -a /var/lib/unbound/root.key || true
    log "Trust anchor updated."
else
    warn "unbound-anchor not found. DNSSEC trust anchor must be set up manually."
fi

# --- Step 3: Install Blocklist Scripts ----------------------------------------

if [[ "${INSTALL_BLOCKLIST}" == true ]]; then
    log "Installing blocklist update scripts..."

    run mkdir -p "${BLOCKLIST_INSTALL_DIR}"
    run cp "${SCRIPT_DIR}/blocklists/update-blocklists.sh" "${BLOCKLIST_INSTALL_DIR}/update-blocklists.sh"
    run cp "${SCRIPT_DIR}/blocklists/sources.txt" "${BLOCKLIST_INSTALL_DIR}/sources.txt"
    run cp "${SCRIPT_DIR}/blocklists/whitelist.txt" "${BLOCKLIST_INSTALL_DIR}/whitelist.txt"
    run chmod +x "${BLOCKLIST_INSTALL_DIR}/update-blocklists.sh"

    log "Blocklist scripts installed to ${BLOCKLIST_INSTALL_DIR}/"

    # Set up cron job (weekly, Sunday at 03:00)
    log "Setting up weekly cron job..."

    CRON_CONTENT="# DNS blocklist update - installed by dns-security-setup
# Runs every Sunday at 03:00 AM
0 3 * * 0  root  ${BLOCKLIST_INSTALL_DIR}/update-blocklists.sh >> /var/log/blocklist-update.log 2>&1
"

    if [[ "${DRY_RUN}" == false ]]; then
        echo "${CRON_CONTENT}" > "${CRON_FILE}"
        chmod 644 "${CRON_FILE}"
    else
        info "DRY RUN: Would create ${CRON_FILE}"
    fi

    log "Cron job installed: ${CRON_FILE}"

    # Run initial blocklist download
    log "Running initial blocklist download..."
    if [[ "${DRY_RUN}" == false ]]; then
        "${BLOCKLIST_INSTALL_DIR}/update-blocklists.sh" --output "${UNBOUND_DIR}" || {
            warn "Initial blocklist download failed. You can run it manually later:"
            warn "  ${BLOCKLIST_INSTALL_DIR}/update-blocklists.sh"
        }
    else
        info "DRY RUN: Would run initial blocklist download."
    fi
else
    info "Skipping blocklist installation (--no-blocklist)."
fi

# --- Step 4: Install Monitoring Configuration ---------------------------------

if [[ "${INSTALL_MONITORING}" == true ]]; then
    log "Installing monitoring configuration..."

    if [[ -d "${TELEGRAF_DIR}" || "${DRY_RUN}" == true ]]; then
        run mkdir -p "${TELEGRAF_DIR}"
        run cp "${SCRIPT_DIR}/monitoring/telegraf-dns.conf" "${TELEGRAF_DIR}/dns.conf"
        run chmod 644 "${TELEGRAF_DIR}/dns.conf"
        log "Telegraf config installed to ${TELEGRAF_DIR}/dns.conf"
    else
        warn "Telegraf config directory not found (${TELEGRAF_DIR})."
        warn "Install Telegraf first, then copy monitoring/telegraf-dns.conf manually."
    fi

    info "Grafana dashboard JSON is at: ${SCRIPT_DIR}/monitoring/grafana-dns-dashboard.json"
    info "Import it via Grafana UI: Dashboards > Import > Upload JSON."
else
    info "Skipping monitoring installation (--no-monitoring)."
fi

# --- Step 5: Validate and Start Unbound ---------------------------------------

log "Validating Unbound configuration..."

if command -v unbound-checkconf >/dev/null 2>&1 && [[ "${DRY_RUN}" == false ]]; then
    if unbound-checkconf "${UNBOUND_DIR}/unbound.conf" 2>&1; then
        log "Configuration is valid."
    else
        warn "Configuration validation reported issues. Review the output above."
        warn "Unbound will NOT be started automatically."
        exit 1
    fi
else
    if [[ "${DRY_RUN}" == true ]]; then
        info "DRY RUN: Would validate configuration with unbound-checkconf."
    else
        warn "unbound-checkconf not found. Skipping validation."
    fi
fi

log "Enabling and starting Unbound..."

if [[ "${DRY_RUN}" == false ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable unbound 2>/dev/null || true
        systemctl restart unbound 2>/dev/null || {
            warn "Failed to start Unbound via systemctl."
            warn "Try: systemctl status unbound"
        }
    elif command -v service >/dev/null 2>&1; then
        service unbound restart 2>/dev/null || {
            warn "Failed to start Unbound via service command."
        }
    else
        warn "Could not detect init system. Start Unbound manually."
    fi
else
    info "DRY RUN: Would enable and start Unbound."
fi

# --- Done ---------------------------------------------------------------------

echo ""
echo "=========================================="
echo "  Installation Complete"
echo "=========================================="
echo ""
log "Unbound config:    ${UNBOUND_DIR}/"
if [[ "${INSTALL_BLOCKLIST}" == true ]]; then
    log "Blocklist scripts: ${BLOCKLIST_INSTALL_DIR}/"
    log "Cron job:          ${CRON_FILE}"
fi
if [[ "${INSTALL_MONITORING}" == true ]]; then
    log "Telegraf config:   ${TELEGRAF_DIR}/dns.conf"
    log "Grafana dashboard: ${SCRIPT_DIR}/monitoring/grafana-dns-dashboard.json"
fi
echo ""
info "Next steps:"
info "  1. Verify DNS resolution:  dig @127.0.0.1 example.com"
info "  2. Test DNSSEC:            dig @127.0.0.1 dnssec-failed.org (should SERVFAIL)"
info "  3. Check logs:             tail -f ${UNBOUND_LOG_DIR}/unbound.log"
if [[ "${INSTALL_BLOCKLIST}" == true ]]; then
    info "  4. Verify blocklist:       dig @127.0.0.1 ads.google.com (should NXDOMAIN)"
fi
echo ""
