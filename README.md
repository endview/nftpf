# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

Current release: [v0.3.0](https://github.com/endview/nftpf/releases/tag/v0.3.0).

`nftpf` is an interactive Linux port-forwarding tool built on top of nftables. It is designed to make IPv4, IPv6, and DDNS-based forwarding rules easier to manage from a simple terminal menu.

## Features

- Add single-port forwarding rules for TCP and UDP.
- Add port-range forwarding rules with 1:1 or offset mapping.
- Add, edit, clear, and display an optional note for each forwarding rule.
- Support IPv4, IPv6, and domain/DDNS targets.
- Automatically use Jool Stateful NAT64 for IPv6-to-IPv4 and IPv4-to-IPv6 forwarding.
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

In the interactive panel, `Nftables status: installed (v1.0.6)` refers to the system `nft` command (the nftables userspace tool), not the nftpf release. The nftpf version is displayed separately and is also available through `nftpf --version`.

## Safe Rule Ownership And Persistence

Starting with v0.2.0, generated configuration does not contain `flush ruleset`. `nftpf` owns only tables whose names begin with `nftpf_`, validates a delete-and-recreate transaction first, and then commits that transaction atomically. Unrelated nftables and iptables-nft tables remain loaded.

When upgrading a v0.1.x configuration, the one-time migration removes only the legacy lowercase `prerouting` and `postrouting` chains created by `nftpf` inside `table ip nat` / `table ip6 nat`. Uppercase iptables-nft chains such as `PREROUTING` and `POSTROUTING` are preserved.

Every successful apply also enables `nftables.service` for boot persistence. Use `nftpf --apply` to validate, atomically load, and persist the managed rules. Avoid manually restarting the global nftables service on a host shared with other firewall managers, because some distribution service units flush the complete live ruleset during restart.

## Cross-Family Forwarding With Jool

Same-family rules continue to use nftables directly. When entry and target families differ, nftpf creates a private Jool namespace and veth for that rule. IPv6-to-IPv4 uses dynamic NAT64 sessions; IPv4-to-IPv6 publishes the backend through static TCP/UDP BIB entries. Single ports, 1:1 ranges, and offset ranges work in either direction.

Install matching kernel headers, DKMS, the Jool 4.x kernel module, and its userspace tools first. Debian/Ubuntu users can use menu item `19` or:

```bash
sudo nftpf --install-jool
```

Keep the Jool kernel module and userspace tools at the same version. If your distribution no longer provides headers for the running kernel, use a supported kernel with matching headers before installing Jool. Same-family rules do not require Jool.

Add rules normally: enter an IPv6 listen address and IPv4 target for v6-to-v4, or the reverse for v4-to-v6. Use `::` or `0.0.0.0` to choose an IPv6 or IPv4 wildcard entry; leaving the entry blank retains automatic family selection. Domain target resolution (`auto/4/6`) is independent of the entry family and is retained for DDNS refresh. Fixed targets do not require DNS64.

The tool reserves per-rule private veth subnets within `198.18.0.0/15`, IPv6 link prefixes within `fd64:6e66:7471::/48`, and translation prefixes within `fd64:6e66:7470::/48`. Overlapping routes or foreign namespace/interface names cause an apply failure. Jool rule IDs must be in `1-32767`. Physical interfaces stay in the host namespace; an existing host forwarding firewall must permit the new veth paths.

`nftpf-jool.service` restores translators at boot after networking, nftables, and the managed route service. `--apply-jool` restores only translators/routes; `--jool-status` reports their state; `--stop-jool` removes owned translators while leaving nftables rules in place. Delete, clear, stop, and uninstall remove owned namespaces and links without unloading shared Jool modules. Reapply reuses unchanged translators; changing backend connection parameters recreates that rule's translator and interrupts its existing sessions. nftables commits remain atomic; Jool resources are prepared before the commit and restored on failure, but expired or interrupted sessions cannot be restored.

Access lists and source tracking match the original entry family. A scoped forward guard rejects direct access to private translator addresses/prefixes, so those paths cannot bypass the public entry ACL. Managed return-route tables receive routes toward the translator, and physical-line marks are cleared inside its namespace. Jool supports native UDP; carrier packet loss or filtering before the entry still needs separate diagnosis. Large IPv4-to-IPv6 ranges require one static BIB entry per port and protocol and can take longer to apply.

Cross-family translation does not guarantee higher throughput than a TCP relay. Real WAN comparisons with Realm found lower Jool relay CPU at equal rates, but lower and variable unrestricted TCP throughput on the tested path. Benchmark your intended path before choosing a forwarding method.

### Optional Per-Flow Pacing

This development feature is not included in the published v0.3.0 release. Menu `19` or these commands save an optional rate cap for each TCP/UDP flow in every managed Jool translator:

```bash
sudo nftpf --jool-pacing 300   # 300 Mbps per flow; applies to live translators
sudo nftpf --jool-status
sudo nftpf --jool-pacing off   # restore the default, unpaced behavior
```

The setting survives rule reapply, reboot, and backup/restore. Changing it preserves translators and existing TCP connections. Only the private namespace's `nftpf0` egress queue is configured; physical NICs, host queues, congestion control, MTU, and offloads stay as configured. Foreign queues are rejected, and a failed update restores the previous setting and managed queues. Old backups without the setting restore pacing to off.

Keep pacing off for internal networks and paths that already perform well. On the two-leg Akari HK/TW WAN path, a 300 Mbps flow cap increased four-stream TCP from a median 430 Mbps to about 1.11 Gbps; one stream remained about 276 Mbps. Isolated tests inside Hytron and Akari HK reached multiple Gbps unpaced, and the same cap reduced their throughput. Treat 300 as a candidate for that WAN condition and validate single-stream and UDP requirements. See the [configuration recommendations and four-test evidence (Chinese)](docs/jool-configuration-recommendations.zh-CN.md), the [complete internal dataset](docs/benchmarks/jool-internal-2026-10-06.csv), and the [WAN benchmark and reproduction guide](docs/jool-performance-2026-10-06.md).

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
bash tests/jool-renderer.sh ./nftpf.sh
```

The integration test requires root plus `iproute2`, `iptables`, and `nftables`. It creates an isolated network namespace, migrates a simulated v0.1.x ruleset, and verifies that foreign iptables-nft rules survive migration, reapply, failed transactions, and cleanup. It does not modify the host network namespace.

```bash
sudo bash tests/namespace-integration.sh ./nftpf.sh
```

The same checks run automatically through GitHub Actions.

Real Jool tests require a compatible loaded kernel module, root, Python 3, and network/mount namespace support:

```bash
sudo bash tests/jool-integration.sh ./nftpf.sh
```

They verify TCP/UDP in both directions, offset ranges, unchanged translator reuse, failed-commit rollback, restart recovery, and coexistence with foreign Jool/firewall resources. CI also runs this test in a QEMU guest using a Debian kernel and its matching DKMS module. To reproduce that guest test after installing a distro kernel image/headers, Jool DKMS/tools, `qemu-system-x86`, `busybox-static`, `cpio`, `xz-utils`, and Python 3:

```bash
sudo bash tests/qemu-jool-integration.sh ./nftpf.sh
```

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
- `flock` from `util-linux` to serialize state, rules, and Jool lifecycle changes.
- Cross-family rules: Jool 4.x userspace and a compatible kernel module built for the running kernel. Installing Jool is an explicit operation; same-family rules do not require it.

## License

This project is released under the MIT License. See the repository `LICENSE` file.
