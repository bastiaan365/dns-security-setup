#!/usr/bin/env bash
# =============================================================================
# update-blocklists.sh
# =============================================================================
# Downloads DNS blocklists from sources.txt, deduplicates entries, removes
# whitelisted domains, converts to Unbound local-zone format, and reloads
# the Unbound service.
#
# Designed to be run via cron (e.g., weekly):
#   0 3 * * 0  /opt/dns-security-setup/blocklists/update-blocklists.sh >> /var/log/blocklist-update.log 2>&1
#
# Usage:
#   ./update-blocklists.sh [OPTIONS]
#
# Options:
#   --dry-run     Download and process but do not install or reload Unbound.
#   --output DIR  Write output files to DIR (default: /etc/unbound).
#   --help        Show this help message.
# =============================================================================

set -euo pipefail

# --- Configuration ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="${SCRIPT_DIR}/sources.txt"
WHITELIST_FILE="${SCRIPT_DIR}/whitelist.txt"
OUTPUT_DIR="/etc/unbound"
OUTPUT_FILE="blocklist.conf"
TEMP_DIR=""
DRY_RUN=false

# --- Functions ----------------------------------------------------------------

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

# --- Argument Parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# --- Validation ---------------------------------------------------------------

[[ -f "${SOURCES_FILE}" ]] || die "Sources file not found: ${SOURCES_FILE}"
[[ -f "${WHITELIST_FILE}" ]] || die "Whitelist file not found: ${WHITELIST_FILE}"
command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
command -v unbound-control >/dev/null 2>&1 || log "WARNING: unbound-control not found. Reload will be skipped."

# --- Main Logic ---------------------------------------------------------------

TEMP_DIR="$(mktemp -d /tmp/blocklist-update.XXXXXX)"
RAW_FILE="${TEMP_DIR}/raw_domains.txt"
CLEAN_FILE="${TEMP_DIR}/clean_domains.txt"
UNBOUND_FILE="${TEMP_DIR}/${OUTPUT_FILE}"

log "Starting blocklist update..."
log "Sources: ${SOURCES_FILE}"
log "Whitelist: ${WHITELIST_FILE}"
log "Output: ${OUTPUT_DIR}/${OUTPUT_FILE}"
log "Dry run: ${DRY_RUN}"

# Step 1: Download all blocklists
log "Downloading blocklists..."
DOWNLOAD_COUNT=0
FAIL_COUNT=0

while IFS= read -r url; do
    # Skip comments and blank lines
    [[ -z "${url}" || "${url}" =~ ^[[:space:]]*# ]] && continue

    url="$(echo "${url}" | xargs)"  # trim whitespace
    log "  Fetching: ${url}"

    if curl -fsSL --max-time 60 --retry 2 "${url}" >> "${RAW_FILE}" 2>/dev/null; then
        DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
    else
        log "  WARNING: Failed to download: ${url}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done < "${SOURCES_FILE}"

log "Downloaded ${DOWNLOAD_COUNT} lists (${FAIL_COUNT} failures)."

[[ -s "${RAW_FILE}" ]] || die "No domains downloaded. Check your sources."

# Step 2: Extract and normalize domains
log "Extracting domains..."

# Handle multiple formats:
#   - hosts format:     0.0.0.0 domain.com  or  127.0.0.1 domain.com
#   - domain-only:      domain.com
#   - wildcard:         *.domain.com
#   - adblock-style:    ||domain.com^
{
    # Hosts-format lines (0.0.0.0 or 127.0.0.1 prefix)
    grep -Eh '^(0\.0\.0\.0|127\.0\.0\.1)\s+' "${RAW_FILE}" 2>/dev/null \
        | awk '{print $2}' || true

    # Domain-only lines (no spaces, looks like a domain)
    grep -Eh '^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$' "${RAW_FILE}" 2>/dev/null || true

    # Wildcard lines (*.domain.com)
    grep -Eh '^\*\.' "${RAW_FILE}" 2>/dev/null \
        | sed 's/^\*\.//' || true

    # Adblock-style lines (||domain.com^)
    grep -Eh '^\|\|' "${RAW_FILE}" 2>/dev/null \
        | sed 's/^||//; s/\^.*$//' || true
} | \
    # Normalize: lowercase, remove trailing dots, remove CR
    tr '[:upper:]' '[:lower:]' | \
    tr -d '\r' | \
    sed 's/\.$//' | \
    # Remove localhost entries and invalid lines
    grep -Ev '^(localhost|local|broadcasthost|ip6-|fe80|ff0[02]|::1|0\.0\.0\.0|127\.0\.0\.1|255\.255\.255\.255)' | \
    grep -E '^[a-z0-9][-a-z0-9.]*\.[a-z]{2,}$' | \
    # Sort and deduplicate
    sort -u > "${CLEAN_FILE}"

TOTAL_RAW="$(wc -l < "${CLEAN_FILE}")"
log "Extracted ${TOTAL_RAW} unique domains."

# Step 3: Remove whitelisted domains
log "Applying whitelist..."
WHITELIST_DOMAINS="${TEMP_DIR}/whitelist_clean.txt"

grep -Ev '^\s*(#|$)' "${WHITELIST_FILE}" | \
    tr '[:upper:]' '[:lower:]' | \
    tr -d '\r' | \
    sed 's/\.$//' | \
    sort -u > "${WHITELIST_DOMAINS}"

WHITELIST_COUNT="$(wc -l < "${WHITELIST_DOMAINS}")"
log "Whitelist contains ${WHITELIST_COUNT} domains."

# Remove whitelisted domains from the blocklist
comm -23 "${CLEAN_FILE}" "${WHITELIST_DOMAINS}" > "${TEMP_DIR}/filtered.txt"
mv "${TEMP_DIR}/filtered.txt" "${CLEAN_FILE}"

TOTAL_FILTERED="$(wc -l < "${CLEAN_FILE}")"
REMOVED=$((TOTAL_RAW - TOTAL_FILTERED))
log "Removed ${REMOVED} whitelisted domains. Final count: ${TOTAL_FILTERED}."

# Step 4: Convert to Unbound local-zone format
log "Generating Unbound configuration..."

{
    echo "# ============================================================================="
    echo "# Auto-generated blocklist for Unbound"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Domains:   ${TOTAL_FILTERED}"
    echo "# Sources:   ${DOWNLOAD_COUNT} lists"
    echo "# ============================================================================="
    echo ""
    echo "server:"

    # Use 'static' type to return NXDOMAIN for blocked domains.
    # Alternative: 'redirect' with local-data to return 0.0.0.0.
    while IFS= read -r domain; do
        echo "    local-zone: \"${domain}.\" static"
    done < "${CLEAN_FILE}"
} > "${UNBOUND_FILE}"

FILESIZE="$(du -h "${UNBOUND_FILE}" | awk '{print $1}')"
log "Generated ${UNBOUND_FILE} (${FILESIZE})."

# Step 5: Validate configuration (if unbound-checkconf is available)
if command -v unbound-checkconf >/dev/null 2>&1 && [[ "${DRY_RUN}" == false ]]; then
    log "Validating Unbound configuration..."
    if ! unbound-checkconf "${UNBOUND_FILE}" >/dev/null 2>&1; then
        log "WARNING: Config validation failed. Proceeding anyway (check manually)."
    else
        log "Configuration validated successfully."
    fi
fi

# Step 6: Install and reload
if [[ "${DRY_RUN}" == true ]]; then
    log "DRY RUN: Would install to ${OUTPUT_DIR}/${OUTPUT_FILE}"
    log "DRY RUN: Would reload Unbound"
    log "DRY RUN: Output file is at ${UNBOUND_FILE}"
    log "Done (dry run)."
    # Keep temp dir for inspection during dry run
    trap - EXIT
    exit 0
fi

# Back up existing blocklist
if [[ -f "${OUTPUT_DIR}/${OUTPUT_FILE}" ]]; then
    cp "${OUTPUT_DIR}/${OUTPUT_FILE}" "${OUTPUT_DIR}/${OUTPUT_FILE}.bak"
    log "Backed up existing blocklist."
fi

# Install new blocklist
cp "${UNBOUND_FILE}" "${OUTPUT_DIR}/${OUTPUT_FILE}"
chmod 644 "${OUTPUT_DIR}/${OUTPUT_FILE}"
log "Installed blocklist to ${OUTPUT_DIR}/${OUTPUT_FILE}."

# Reload Unbound
if command -v unbound-control >/dev/null 2>&1; then
    log "Reloading Unbound..."
    if unbound-control reload 2>/dev/null; then
        log "Unbound reloaded successfully."
    else
        log "WARNING: unbound-control reload failed. Try: systemctl restart unbound"
    fi
else
    log "WARNING: unbound-control not found. Restart Unbound manually:"
    log "  systemctl restart unbound"
fi

log "Blocklist update complete. ${TOTAL_FILTERED} domains blocked."
