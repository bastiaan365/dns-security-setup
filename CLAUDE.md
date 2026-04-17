# dns-security-setup

Unbound-based DNS resolver config with DNS-over-TLS, DNSSEC, and ~280k-domain blocklists. Targets OPNsense and standalone Linux. Maintained by Bastiaan ([@bastiaan365](https://github.com/bastiaan365)).

This file scopes Claude's behaviour for this repo. The global `~/.claude/CLAUDE.md` covers personal conventions; everything below is repo-specific.

## What this repo is

- A **deployable** DNS-security stack: `install.sh` is meant to actually run on someone else's box.
- A **set of templates** for OPNsense and standalone Linux Unbound deployments.
- Plus a Grafana dashboard JSON that visualises query volume and blocked-domain stats from a Telegraf collector.

This is more "code that runs on other people's machines" than `homelab-infrastructure` (which is mostly documentation). The bar for breakage and security is correspondingly higher.

## Repo conventions

### Structure

```
unbound/             *.conf — Unbound config templates (main, OPNsense overrides, DNS-over-TLS, DNSSEC)
blocklists/          update-blocklists.sh, sources.txt (URLs), whitelist.txt (false-positive overrides)
monitoring/          telegraf-dns.conf, grafana-dns-dashboard.json
install.sh           top-level installer (root-aware, has --dry-run, --no-monitoring, --no-blocklist)
README.md            user-facing documentation
```

### Anonymisation

Lower-stakes than `homelab-infrastructure` because most of this repo is genuinely generic, but the rules still apply:

- **No real internal IPs or hostnames** anywhere — including in the dashboard's example queries, the Telegraf collector config, or commented-out blocks in Unbound configs. Same forbidden subnets as the other repos: `192.168.178.x` (IOT_TIG), `192.168.10.x` (IOT_HA), `192.168.100.x` (IoT VLAN), `192.168.1.x` (LAN_FRITZBOX), `192.168.254.x` (ADMIN).
- **DNS-over-TLS upstream addresses** (Cloudflare `1.1.1.1`, Quad9 `9.9.9.9`, etc.) **are fine** — these are universal public resolvers, not anonymisation concerns.
- **Whitelist entries** must be public well-known domains (current whitelist is Microsoft/Apple/etc.). Do not add personal-specific domains (employer, family services, niche subscriptions) — those reveal what's running on the network.
- **Grafana dashboard JSON** uses `${DS_INFLUXDB}` placeholder for the datasource UID. Never paste a real Grafana datasource UID.

### Shell script standards

`install.sh` and `blocklists/update-blocklists.sh` are the executable surface. Both should:

- `set -euo pipefail` at the top.
- Pass `shellcheck` cleanly. Run `shellcheck install.sh blocklists/update-blocklists.sh` before any commit that touches them.
- Support `--dry-run` for any operation that touches the host (`install.sh` already does; `update-blocklists.sh` should too if it doesn't yet).
- Be `set -x`-safe — no embedded credentials in command-line args.
- Use `mktemp -d` not `/tmp/foo` for any working directories.
- Accept `--help` and document all options inline.

### Unbound configs

- Comment liberally. Every non-obvious directive needs a one-line `# why` explanation.
- One concern per file: don't mix DNSSEC config with TLS upstream config. Keep `dnssec.conf`, `dns-over-tls.conf`, etc. independent so users can pick and choose.
- The `opnsense-custom.conf` file goes into OPNsense's custom-options field. Keep it small — OPNsense's UI mangles long inputs.

### Dashboard JSON

Same rules as the dedicated `grafana-dashboards` repo: kebab-case filename, sequential panel IDs, `${DS_PLACEHOLDER}` style for any datasource ref, no real hostnames in queries.

### Validation gates

Run before any commit that touches code or config:

- **shellcheck**: `shellcheck install.sh blocklists/update-blocklists.sh`
- **JSON validity**: `python3 -m json.tool monitoring/grafana-dns-dashboard.json > /dev/null`
- **Leak grep**:

  ```bash
  grep -REn '192\.168\.|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|niborserver|Nibordooh|OPNsense-Gateway\.home\.arpa' \
    unbound/ blocklists/ monitoring/ install.sh README.md \
    | grep -vE '"version"\s*:\s*"|^[^:]+:[0-9]+:\s*##|^[^:]+:[0-9]+:\s*#|10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16'
  ```

  Excludes three categories of false positive: comment lines, the three RFC1918 superset CIDRs (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` — used as Unbound `access-control` / `private-address` directives for rebinding protection), and Grafana version strings. Public DNS server IPs (`1.1.1.1`, `9.9.9.9`, `8.8.8.8`, etc.) don't trigger the regex at all.

- **Install script smoke test**: `sudo ./install.sh --dry-run` should complete without errors. Don't test `install.sh` non-dry on niborserver — niborserver doesn't run Unbound (DNS lives on OPNsense).

## Workflow expectations for Claude

When I ask you to **add or modify a config file**:

1. Read the analogous existing file first.
2. Show the change as a diff.
3. Run the leak grep.
4. If it's an Unbound config, also confirm syntax mentally: `unbound-checkconf` would be the real check, but I run that on OPNsense, not niborserver.

When I ask you to **modify `install.sh` or `update-blocklists.sh`**:

1. Show the change as a diff.
2. Run `shellcheck` and report any new warnings.
3. Test with `--dry-run` and show the output.
4. Note explicitly any new file or directory the script will touch.

When I ask you to **add a new blocklist source**:

1. Verify the URL is reachable and returns the expected format (host file, AdBlock list, etc.).
2. Estimate the new total domain count and update the README's "Blocklist stats" table.
3. Check whether the new source might block legitimate things — propose updates to `whitelist.txt` if so.

When I ask you to **modify the dashboard**:

1. Same workflow as the `grafana-dashboards` repo — show the panel-level diff, bump the dashboard's `version`, re-run JSON validation.

## Things to avoid

- Hardcoding any DoT upstream other than Cloudflare/Quad9/Google/NextDNS — these are the safe defaults. If I want a specific provider, I'll ask.
- `curl ... | bash` patterns inside scripts. Always download to a file, verify (sha256 if possible), then execute.
- `sed -i` without a backup suffix in `install.sh` — leaves no recovery path on failure.
- Adding new dependencies to the install script (jq, dig outside coreutils) without flagging that the README needs updating.
- Pushing tags or running `gh release` without me — releases happen by my hand only.

## Related repos

- [`homelab-infrastructure`](https://github.com/bastiaan365/homelab-infrastructure) — the network where this DNS layer runs
- [`grafana-dashboards`](https://github.com/bastiaan365/grafana-dashboards) — companion dashboards (the DNS dashboard in this repo is published there too)

## Drift from target structure

_Claude maintains this section. List anything in the repo that doesn't match the conventions above, with why it's still there and what would need to happen to fix it._

- **No drift on first audit (2026-04-17).** Self-test on first wiring: leak grep produced 9 hits, all of them the RFC1918 superset CIDRs in `unbound/opnsense-custom.conf` and `unbound/unbound.conf` — `access-control: 10.0.0.0/8 allow`, `private-address: 192.168.0.0/16`, etc. These are correct Unbound directives, not anonymisation leaks. The second-stage filter excludes them. Dashboard JSON valid. shellcheck not installed on niborserver — install via `sudo apt install shellcheck` to enable that gate locally; CI would be a better long-term home for it.
