# Changelog

All notable changes to this project are documented in this file.

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
