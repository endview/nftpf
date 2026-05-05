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

See the repository `LICENSE` file.
