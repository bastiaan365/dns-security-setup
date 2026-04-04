# DNS Security Setup

Unbound-based DNS config with DNS-over-TLS, DNSSEC and blocklists. I use this on OPNsense but it works on any Linux box.

## How it works

```text
[Client] → [Unbound (local)] → [DNS-over-TLS] → [Upstream resolver]
                                       ↓
                                DNSSEC validation
                                Blocklist filtering
                                Query logging
```

- All DNS queries are encrypted via TLS — nothing leaves the network in plain text
- DNSSEC validates responses to prevent spoofing
- Ads, trackers, malware and telemetry domains get blocked before they resolve
- Queries are logged for Grafana monitoring

## Blocklist stats

| Category | Domains blocked |
|---|---|
| Advertising | ~120,000 |
| Tracking & telemetry | ~85,000 |
| Malware & phishing | ~95,000 |
| IoT telemetry | ~15,000 |
| **Total unique** | **~280,000** |

## Getting started

### OPNsense

1. Copy `unbound/opnsense-custom.conf` to `/var/unbound/etc/`
2. Import blocklists via the Unbound DNS plugin
3. Turn on DNS-over-TLS under Services → Unbound DNS → General

### Standalone Linux

```bash
git clone https://github.com/bastiaan365/dns-security-setup.git
cd dns-security-setup
sudo ./install.sh
```

## File structure

```
├── unbound/
│   ├── unbound.conf              # Main config
│   ├── opnsense-custom.conf      # OPNsense overrides
│   ├── dns-over-tls.conf         # TLS upstream setup
│   └── dnssec.conf               # DNSSEC settings
├── blocklists/
│   ├── update-blocklists.sh      # Auto-update script
│   ├── sources.txt               # Blocklist URLs
│   └── whitelist.txt             # False-positive overrides
├── monitoring/
│   ├── telegraf-dns.conf         # Telegraf DNS collector
│   └── grafana-dns-dashboard.json
└── install.sh
```

## Upstream resolvers

| Resolver | IP | TLS hostname |
|---|---|---|
| Quad9 | 9.9.9.9 | dns.quad9.net |
| Cloudflare | 1.1.1.1 | cloudflare-dns.com |

Both support DNSSEC and don't log queries.

## Why bother with DNS security

Most home networks send DNS in plain text — your ISP can see every domain you visit. Smart home devices quietly resolve tracking domains in the background. This setup fixes that:

- ISP can't see your DNS traffic
- Malware domains get blocked network-wide
- IoT devices can't phone home to random servers
- DNS responses are cryptographically validated

## See also

- [Homelab Infrastructure](https://github.com/bastiaan365/homelab-infrastructure) — the network this runs on
- [Grafana Dashboards](https://github.com/bastiaan365/grafana-dashboards) — DNS monitoring dashboard
- [bastiaan365.com](https://bastiaan365.com) — full write-up

---

*Blocklists update weekly via cron. Config uses placeholder IPs — change them for your network.*
