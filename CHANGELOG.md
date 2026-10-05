# Changelog

All notable changes to this project are documented in this file.

## [0.3.0] - 2026-10-06

### Added

- Added automatic Jool Stateful NAT64 paths for IPv6-to-IPv4 and IPv4-to-IPv6 TCP/UDP rules, including single ports and ranges.
- Added per-rule namespaces/veths, static BIB publication for IPv4 entries, scoped outbound SNAT, managed policy routes, boot restoration, dependency installation, status and cleanup commands.
- Restricts private translator paths to managed DNAT sessions, retaining frontend ACL behavior; serializes state and runtime changes with `flock`.
- Added real kernel translation tests in an isolated QEMU guest and cross-family renderer/DNS schema regression tests.

### Changed

- Appended an independent target-family field to `rules.db`; older records and rule notes remain compatible.
- DDNS resolves the stored target family independently of the entry family.
- Reuses unchanged translators, prepares changed translators before the nftables commit, and restores prior translator specifications if preparation or commit fails.

### Fixed

- Reads ECMP default routes as single records so nexthop continuation lines do not cause false private-subnet collision errors.
- Allows high-port static BIB pools in isolated IPv4-to-IPv6 translator namespaces, including targets within the namespace's ephemeral-port range.
- Declares the transport protocol before conntrack port expressions so cross-family forward guards parse correctly on Debian 12 nftables 1.0.6.

### Compatibility And Validation

- Existing same-family rules and notes remain compatible; Jool installation is explicit and is required only for cross-family rules.
- Jool userspace tools and the kernel module must match, and the module must be built for the running kernel. Changing backend connection parameters recreates that rule's translator and interrupts its sessions.
- Validated real TCP/UDP translation in both directions with Debian Linux 6.12 / Jool 4.1.13 in QEMU and Debian 12 Linux 6.1 / matching Jool 4.1.15 on two servers.
- WAN comparisons against Realm showed lower relay CPU at fixed rates but variable, lower unrestricted TCP throughput on the tested path. Cross-family translation is not a guaranteed throughput improvement.

## [0.2.1] - 2026-09-20

### Added

- Added optional notes of up to 100 characters to forwarding rules; notes appear on their own line in rule lists and can be updated or cleared from the quick-edit workflow.
- Added the NFTPF version to the interactive status panel so it is distinct from the installed nftables version.

### Changed

- Extended `rules.db` records in a backward-compatible way; existing records without a note remain valid.

## [0.2.0] - 2026-07-10

### Added

- Added `nftpf --apply` for non-interactive validation, atomic loading, and boot persistence.
- Added `nftpf --self-test`, an isolated namespace integration test, and GitHub Actions CI.
- Added separate live-rule and boot-persistence status indicators.
- Added a `SHA256SUMS` release asset and a security-reporting policy.

### Changed

- Moved managed NAT rules from shared `ip nat` / `ip6 nat` tables into `nftpf_nat` tables.
- Replaced global service restarts with a validated atomic nftables transaction.
- Successful applies now enable `nftables.service` for reboot persistence.
- v0.1.x upgrades remove only nftpf's legacy lowercase NAT chains.

### Fixed

- Preserved unrelated nftables and iptables-nft rules used by Phantun, Docker, fail2ban, and other tools.
- Made stop and uninstall remove only nftpf-managed tables instead of flushing the global ruleset.
- Added rollback for failed rule, line, access-control, backup-import, and service-enable operations.
- Normalized duplicate forwarding keys in `/etc/sysctl.conf` without loose regular-expression matching.
