# 🌐 DNS Security Setup

Privacy-first DNS configuration using Unbound with DNS-over-TLS, DNSSEC validation and curated blocklists. Designed for OPNsense but works standalone on any Linux system.

## 🔒 What This Does

```text
[Client] → [Unbound (local)] → [DNS-over-TLS] → [Upstream resolver]
                ↓
         DNSSEC validation
         Blocklist filtering
         Query logging
```

- **Encrypts** all DNS queries via DNS-over-TLS (no plain-text DNS leaves your network)
- **Validates** responses with DNSSEC (prevents DNS spoofing)
- **Blocks** ads, trackers, malware and telemetry domains before they resolve
- **Logs** queries for monitoring and anomaly detection via Grafana

## 📊 Blocklist Stats

| Category | Domains blocked |
|---|---|
| Advertising | ~120,000 |
| Tracking & telemetry | ~85,000 |
| Malware & phishing | ~95,000 |
| IoT telemetry | ~15,000 |
| **Total unique** | **~280,000** |

## 🚀 Quick Start

### OPNsense

1. Copy `unbound/opnsense-custom.conf` to `/var/unbound/etc/`
2. Import blocklists via OPNsense Unbound DNS plugin
3. Enable DNS-over-TLS in Services → Unbound DNS → General

### Standalone Linux

```bash
git clone https://github.com/bastiaan365/dns-security-setup.git
cd dns-security-setup
sudo ./install.sh
```

## 📁 Structure

```
├── unbound/
│   ├── unbound.conf              # Main config
│   ├── opnsense-custom.conf      # OPNsense-specific overrides
│   ├── dns-over-tls.conf         # TLS upstream configuration
│   └── dnssec.conf               # DNSSEC settings
├── blocklists/
│   ├── update-blocklists.sh      # Auto-update script
│   ├── sources.txt               # Blocklist URLs
│   └── whitelist.txt             # False-positive overrides
├── monitoring/
│   ├── telegraf-dns.conf         # Telegraf DNS query collector
│   └── grafana-dns-dashboard.json
└── install.sh
```

## 🔧 Upstream Resolvers

Configured for privacy-respecting resolvers with TLS:

| Resolver | IP | TLS hostname |
|---|---|---|
| Quad9 | 9.9.9.9 | dns.quad9.net |
| Cloudflare | 1.1.1.1 | cloudflare-dns.com |

Both support DNSSEC and have no-logging policies.

## 💡 Why DNS Security Matters

Most home networks send DNS queries in plain text — visible to your ISP and anyone on the network. Smart home devices often resolve tracking domains silently. This setup ensures:

- Your ISP cannot see which domains you visit
- Malware domains are blocked before reaching any device
- IoT devices cannot phone home to unauthorized servers
- DNS responses are cryptographically validated

## 🔗 Related

- [Homelab Infrastructure](https://github.com/bastiaan365/homelab-infrastructure) — Full network architecture
- [Grafana Dashboards](https://github.com/bastiaan365/grafana-dashboards) — DNS monitoring dashboard
- [bastiaan365.com](https://bastiaan365.com) — Full write-up

---

*Blocklist sources are updated weekly via cron. Configuration uses placeholder IPs — adjust for your network.*
