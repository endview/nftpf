# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

`nftpf` is an interactive Linux port-forwarding tool built on top of nftables. It is designed to make IPv4, IPv6, and DDNS-based forwarding rules easier to manage from a simple terminal menu.

## Features

- Add single-port forwarding rules for TCP and UDP.
- Add port-range forwarding rules with 1:1 or offset mapping.
- Support IPv4, IPv6, and domain/DDNS targets.
- Automatically validate nftables configuration before applying changes.
- Automatically apply changes by starting or restarting the nftables service.
- Detect and repair managed nftables configuration drift on startup.
- Support DDNS refresh with optional cron automation.
- Support mutually exclusive whitelist/blacklist access control for managed forwarding ports.
- Record recent source IP hit counts for managed forwarding ports, then let the user manually add suspicious IPs to the blacklist.
- Support backup, import, and rollback for managed rules and access-control settings.
- Add IPv6 DNAT return-route handling for special provider networks that use `fd00::1` plus policy routing table `100`.

## Quick Start

```bash
curl -o nftpf.sh https://raw.githubusercontent.com/endview/nftpf/main/nftpf.sh
chmod +x nftpf.sh
sudo bash nftpf.sh
```

After the first run, the tool installs a shortcut:

```bash
nftpf
```

## Important Notice

The generated nftables configuration contains:

```nft
flush ruleset
```

That means this tool rewrites the current nftables ruleset when applying managed configuration. Do not use it on hosts where other firewall tools or applications also manage nftables rules unless you understand and accept that behavior.

## DDNS Refresh

Domain targets are stored with their resolved IP address. You can refresh them manually from the menu, or enable automatic refresh. The cron entry includes a fixed `PATH` and `flock` lock to avoid overlapping refresh jobs.

Example generated cron:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/nftpf.lock "/usr/local/bin/nftpf" --refresh-ddns >/dev/null 2>&1
```

## Access Control

The interactive menu includes whitelist and blacklist modes. They are mutually exclusive and only apply to forwarding ports managed by `nftpf`; they do not affect SSH or unrelated services.

Whitelist/blacklist entries must be source IP addresses or CIDR ranges, such as `203.0.113.10`, `203.0.113.0/24`, or `2409:abcd::/48`. Domain names are not supported for access-control lists.

`nftpf` also keeps a short-lived observation list for managed forwarding ports. It shows recent source IP hit counts, and you can manually select suspicious IPs to add to the blacklist. This avoids aggressive automatic bans and reduces false positives.

Before rules are reloaded, the current observation list is saved to `/etc/nft-port-forward/access-history.log`. The history file is an auxiliary snapshot log, not a real-time audit log, and only keeps the latest 1000 lines.

## Backup And Rollback

Before changing forwarding rules or access-control settings, `nftpf` automatically creates a backup under `/etc/nft-port-forward/backups`. The menu also provides manual backup, import, and rollback to the latest automatic backup.

## Files

- `nftpf.sh`: Main script.
- `NFT_Port_Forwarding_Tool_PRD.md`: Product requirements and design notes.

## Requirements

- Linux with systemd.
- Root privileges.
- `bash`.
- `nftables`.
- `iproute2`.
- Optional: `flock` from `util-linux` for DDNS cron locking.

## License

This project is released under the MIT License. See the repository `LICENSE` file.
