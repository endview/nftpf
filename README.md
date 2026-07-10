# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

`nftpf` is an interactive Linux port-forwarding tool built on top of nftables. It is designed to make IPv4, IPv6, and DDNS-based forwarding rules easier to manage from a simple terminal menu.

## Features

- Add single-port forwarding rules for TCP and UDP.
- Add port-range forwarding rules with 1:1 or offset mapping.
- Support IPv4, IPv6, and domain/DDNS targets.
- Validate the complete nftables transaction before changing live rules.
- Atomically replace only `nftpf_*` tables without restarting the global nftables service.
- Enable nftables at boot whenever rules are applied, while reporting live-rule and boot-persistence status separately.
- Coexist with rules managed by iptables-nft, Phantun, Docker, fail2ban, and other tools.
- Detect and repair managed nftables configuration drift on startup.
- Support DDNS refresh with optional systemd timer automation.
- Support mutually exclusive whitelist/blacklist access control for managed forwarding ports.
- Record recent source IP hit counts for managed forwarding ports, then let the user manually add suspicious IPs to the blacklist.
- Support backup, import, and rollback for managed rules and access-control settings.
- Add IPv6 DNAT return-route handling for special provider networks that use `fd00::1` plus policy routing table `100`.
- Support multi-NIC / multi-DIA entry lines with optional `iifname` binding and managed `fwmark` + per-line routing tables.
- Update the installed script from the latest GitHub Release through menu item `17` or `nftpf --update`.
- Uninstall from menu item `18`, with optional backup deletion.

## Quick Start

```bash
curl -fL --proto '=https' --tlsv1.2 -o nftpf.sh https://github.com/endview/nftpf/releases/latest/download/nftpf.sh
curl -fL --proto '=https' --tlsv1.2 -o SHA256SUMS https://github.com/endview/nftpf/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
bash -n nftpf.sh
chmod +x nftpf.sh
sudo bash nftpf.sh
```

After the first run, the tool installs a shortcut:

```bash
nftpf
```

## Safe Rule Ownership And Persistence

Starting with v0.2.0, generated configuration does not contain `flush ruleset`. `nftpf` owns only tables whose names begin with `nftpf_`, validates a delete-and-recreate transaction first, and then commits that transaction atomically. Unrelated nftables and iptables-nft tables remain loaded.

When upgrading a v0.1.x configuration, the one-time migration removes only the legacy lowercase `prerouting` and `postrouting` chains created by `nftpf` inside `table ip nat` / `table ip6 nat`. Uppercase iptables-nft chains such as `PREROUTING` and `POSTROUTING` are preserved.

Every successful apply also enables `nftables.service` for boot persistence. Use `nftpf --apply` to validate, atomically load, and persist the managed rules. Avoid manually restarting the global nftables service on a host shared with other firewall managers, because some distribution service units flush the complete live ruleset during restart.

## DDNS Refresh

Domain targets are stored with their resolved IP address. You can refresh them manually from the menu, or enable automatic refresh. Automatic refresh is managed by a systemd timer, so sub-minute intervals such as `30s` or `0.5m` are supported.

Example generated timer:

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=nftpf-ddns.service
```

## Access Control

The interactive menu includes whitelist and blacklist modes. They are mutually exclusive and only apply to forwarding ports managed by `nftpf`; they do not affect SSH or unrelated services.

Whitelist/blacklist entries must be source IP addresses or CIDR ranges, such as `203.0.113.10`, `203.0.113.0/24`, or `2409:abcd::/48`. Domain names are not supported for access-control lists.

`nftpf` also keeps a short-lived observation list for managed forwarding ports. It shows recent source IP hit counts, and you can manually select suspicious IPs to add to the blacklist. This avoids aggressive automatic bans and reduces false positives.

Before rules are reloaded, the current observation list is saved to `/etc/nft-port-forward/access-history.log`. The history file is an auxiliary snapshot log, not a real-time audit log, and only keeps the latest 1000 lines.

## Multi-NIC / Multi-DIA

Normal VPS users do not need to configure entry lines. On multi-NIC hosts, you can add lines such as `IX / eth0` or `BGP / eth2` from the line-management menu. When a forwarding rule is bound to a line, `nftpf` emits `iifname "eth0"` style matches so identical ports can coexist on different entry interfaces.

The default line mode only binds the entry interface and does not change system routing. Advanced users can enable managed return routing, where `nftpf` emits `ct mark` / `meta mark` nftables rules and applies matching `ip rule` / per-line route tables through `nftpf --apply-routes`. Use this only on multi-DIA machines that need policy routing.

## Backup And Rollback

Before changing forwarding rules or access-control settings, `nftpf` automatically creates a backup under `/etc/nft-port-forward/backups`. The menu also provides manual backup, import, and rollback to the latest automatic backup. Failed applies restore the previous state files, generated configuration, and service-enable state.

For non-destructive checks, run `nftpf --self-test`. This verifies Bash syntax and renderer invariants without changing system rules.

## Tests

Run the fast checks on any Linux host:

```bash
bash -n nftpf.sh
bash nftpf.sh --self-test
```

The integration test requires root plus `iproute2`, `iptables`, and `nftables`. It creates an isolated network namespace, migrates a simulated v0.1.x ruleset, and verifies that foreign iptables-nft rules survive migration, reapply, failed transactions, and cleanup. It does not modify the host network namespace.

```bash
sudo bash tests/namespace-integration.sh ./nftpf.sh
```

The same checks run automatically through GitHub Actions.

## Script Update

Use menu item `17. 更新脚本` or run `nftpf --update` to download the latest `nftpf.sh` from GitHub Releases. The updater validates the downloaded script and creates a `.bak.<timestamp>` backup before replacing the local script. Updating the script does not change forwarding rules and does not restart nftables.

## Uninstall

Use menu item `18. 卸载脚本` or run `nftpf --uninstall` to remove nftpf. The uninstall flow removes only nftpf-managed tables, resets nftpf-managed configuration to an empty file, removes DDNS timers/services, removes managed policy-route services and rules, removes state files, and deletes the installed script/shortcut. Backup deletion is optional and defaults to `N`.

The uninstall flow does not remove the `nftables` package and does not disable system IP forwarding sysctl settings, because those may be used by other services.

## Files

- `nftpf.sh`: Main script.
- `tests/namespace-integration.sh`: Isolated migration and coexistence regression test.
- `.github/workflows/ci.yml`: GitHub Actions validation workflow.
- `CHANGELOG.md`: Versioned change history.
- `SECURITY.md`: Supported versions and private vulnerability-reporting guidance.
- `NFT_Port_Forwarding_Tool_PRD.md`: Product requirements and design notes.

## Requirements

- Linux with systemd.
- Root privileges.
- `bash`.
- `nftables`.
- `iproute2`.
- Debian/Ubuntu for automatic nftables installation. On other systemd distributions, install nftables manually first.
- Optional: `flock` from `util-linux` for DDNS refresh locking.

## License

This project is released under the MIT License. See the repository `LICENSE` file.
