# Security Policy

## Supported Versions

Security fixes are provided for the latest minor release only.

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |
| 0.1.x | No |

## Reporting A Vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting for this repository:

<https://github.com/endview/nftpf/security/advisories/new>

Include the affected nftpf version, Linux distribution, nftables version, reproduction steps, expected impact, and any suggested mitigation. Do not include production credentials, private keys, server passwords, or an unredacted ruleset.

## Operational Safety

Before applying firewall changes remotely, keep an independent SSH session open and create an out-of-band recovery path. Review generated configuration with `nft -c -f` and back up `/etc/nftables.conf` plus `/etc/nft-port-forward`.
