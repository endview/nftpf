# NFT Port Forwarding Tool PRD

## 1. Document Info

Product name: NFT Port Forwarding Tool

Document type: Product Requirements Document

Target platform: Linux servers using nftables

Primary script: `nft_helper.sh`

Baseline version: Initial IPv4-only script from `C:/Users/endin/Downloads/nft_helper.sh`

Goal: Build a simple, reliable port forwarding management tool with a user experience close to `realm`, while keeping nftables as the underlying implementation.

## 2. Background

The initial script already provides a working IPv4 port forwarding workflow:

- It installs and manages nftables.
- It generates `/etc/nftables.conf`.
- It adds single-port forwarding rules.
- It adds port-range forwarding rules.
- It provides view, edit, delete, clear, and service management menus.

The later expanded versions attempted to add IPv6, DDNS, automatic application, shortcut changes, and configuration migration at the same time. This made the logic harder to reason about and caused regressions where rules were not reliably written or applied.

This PRD defines a cleaner product direction: keep the stable IPv4 model, then add IPv6 and DDNS in controlled stages.

## 3. Product Vision

NFT Port Forwarding Tool should let a user define forwarding rules in plain terms:

```text
Listen address + listen port -> target address + target port
```

The user should not need to understand nftables syntax, NAT chains, `dnat`, `masquerade`, `ip daddr`, `ip6 daddr`, or service reload behavior.

The tool should feel like a small practical server utility:

- Simple menu.
- Clear prompts.
- Rules apply automatically after successful validation.
- Failures show actionable messages.
- Existing working rules should not be destroyed by failed updates.

## 4. Goals

- Preserve the initial script's reliable IPv4 forwarding behavior.
- Support IPv4 single-port forwarding.
- Support IPv4 port-range forwarding.
- Automatically validate nftables config before applying.
- Automatically apply changes after add, edit, delete, or clear.
- Support per-listen-IP conflict detection.
- Support IPv6 forwarding in a later implementation stage.
- Support DDNS/domain targets in a later implementation stage.
- Keep the user-facing workflow close to `realm`: add, list, edit, delete, start, stop, restart.

## 5. Non-Goals

- This tool is not a general nftables firewall editor.
- This tool should not manage arbitrary filter rules.
- This tool should not parse and preserve every possible custom nftables configuration.
- This tool should not become a full daemon in the first version.
- This tool should not depend on Docker, Python, Node.js, or a database for the core flow.
- This tool should not add IPv6 and DDNS in the same implementation step as menu cleanup or basic validation fixes.

## 6. Target Users

Primary users:

- VPS users who need simple TCP/UDP forwarding.
- Users forwarding game, proxy, panel, SSH, or service ports.
- Users who prefer an interactive shell menu over raw nftables commands.

Secondary users:

- Users who maintain several forwarding rules across different local IPs.
- Users using DDNS domains as upstream targets.
- Users using IPv6-only or dual-stack servers.

## 7. Core User Stories

1. As a user, I can add a single-port forwarding rule by entering listen port, target IP, and target port.

2. As a user, I can add a port-range forwarding rule and choose either 1:1 mapping or offset mapping.

3. As a user, I can bind a rule to a specific local listen IP or leave it blank to match all local IPv4 addresses.

4. As a user, I can view existing forwarding rules in a readable format.

5. As a user, I can quickly edit an existing rule without opening nftables syntax manually.

6. As a user, I can delete an existing rule by selecting it from a numbered list.

7. As a user, I can safely apply changes only after nftables config validation succeeds.

8. As a user, I can use IPv6 addresses as listen or target addresses in a future version.

9. As a user, I can enter a DDNS domain as the target address in a future version and have the tool keep it updated.

## 8. Current Baseline Behavior

The initial script uses this default nftables structure:

```nft
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # MARKER_START
        # MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}
```

Rules are inserted before `# MARKER_END`.

Example single-port rule:

```nft
meta l4proto {tcp, udp} th dport 20000 dnat to 10.0.0.2:20000
```

Example specific listen-IP rule:

```nft
ip daddr 1.2.3.4 meta l4proto {tcp, udp} th dport 20000 dnat to 10.0.0.2:20000
```

Example range 1:1 rule:

```nft
meta l4proto {tcp, udp} th dport { 20000-20020 } dnat to 10.0.0.2
```

Example range offset rule:

```nft
meta l4proto {tcp, udp} th dport { 20000-20020 } dnat to 10.0.0.2 : th dport map { 20000 : 30000, 20001 : 30001 }
```

## 9. Proposed Product Architecture

### 9.1 Menu Layer

Responsible for:

- Rendering tool title and system status.
- Accepting user choices.
- Routing to feature functions.

Target menu:

```text
NFT Port Forwarding Tool

1. Add Port Forwarding Rule
2. Add Port Range Forwarding Rule
3. View Existing Rules
4. Quick Edit Rule
5. Edit Config File
6. Delete Rule
7. Enable Autostart
8. Disable Autostart
9. Start Service
10. Stop Service
11. Restart Service
12. Clear All Rules
0. Exit
```

Chinese UI can keep current wording, but the product name should remain:

```text
NFT Port Forwarding Tool
```

### 9.2 Environment Layer

Responsible for:

- Root check.
- System detection: Debian/Ubuntu systemd or Alpine OpenRC.
- Dependency installation.
- nftables installation.
- IP forwarding setup.
- Shortcut installation.

Requirements:

- First run should automatically install nftables if missing.
- First run should initialize config if missing.
- IPv4 forwarding must be enabled:

```text
net.ipv4.ip_forward=1
```

- IPv6 forwarding must be added only when IPv6 support is implemented:

```text
net.ipv6.conf.all.forwarding=1
```

### 9.3 Config Layer

Responsible for:

- Creating default nftables config.
- Checking marker compatibility.
- Writing rules safely.
- Backing up config before destructive reset or clear.

Requirements:

- The script must not say "rule added successfully" if marker insertion failed.
- The script must validate that marker comments exist before writing.
- The script should preserve only its own managed region unless the user explicitly resets config.

### 9.4 Rule Model Layer

Internal rule fields:

```text
id
family: ipv4 | ipv6
listen_ip
listen_port_start
listen_port_end
target_type: ip | domain
target_host
resolved_target_ip
target_port_start
target_port_end
protocol: tcp_udp
mapping_mode: single | range_1_to_1 | range_offset
comment
```

The current shell script can store this implicitly in nftables rules. A future version may store a sidecar metadata file for DDNS:

```text
/etc/nft-port-forward/rules.conf
```

or:

```text
/etc/nft-port-forward/rules.tsv
```

The sidecar file is strongly recommended for DDNS because nftables rules alone do not preserve the original domain after it is resolved to an IP.

### 9.5 Rule Writer Layer

Responsible for:

- Building nftables rule strings.
- Choosing IPv4 or IPv6 table.
- Inserting rules into the correct marker block.

IPv4 writer target:

```nft
table ip nat
```

IPv6 writer target:

```nft
table ip6 nat
```

This dual-table model is preferred over a single `table inet nat` for this tool because it is easier to reason about, easier to parse, and closer to the stable initial IPv4 design.

### 9.6 Rule Parser Layer

Responsible for:

- Listing managed rules.
- Extracting listen IP.
- Extracting listen port or range.
- Extracting target IP/domain.
- Extracting target port or range.
- Displaying rules in a user-friendly way.

Parser requirements:

- Must support blank listen IP as wildcard.
- Must support exact listen IP.
- Must support single port.
- Must support port range.
- Must support offset map.
- Must not mistake unrelated nftables rules for script-managed rules.

### 9.7 Apply Layer

Responsible for:

- Running config validation.
- Starting or restarting nftables service.
- Reporting success only when command returns success.

Required flow:

```text
write config
-> nft -c -f /etc/nftables.conf
-> if service running: restart
-> if service stopped: start
-> report result
```

Failure behavior:

- If validation fails, do not restart service.
- If service restart fails, report failure.
- Existing working service state should not be hidden behind a false success message.

## 10. IPv6 Design

### 10.1 User Experience

The user should be able to enter:

```text
Listen IP: 2409:8c54:1020:39:0:3156:2:e4
Listen port: 20000
Target IP: 2400:c620:22:133::a
Target port: 20000
```

The tool should automatically identify this as IPv6 and write it to the IPv6 NAT table.

### 10.2 Config Template

When IPv6 support is enabled, default config should become:

```nft
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # IPV4_MARKER_START
        # IPV4_MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # IPV6_MARKER_START
        # IPV6_MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}
```

### 10.3 IPv6 Rule Examples

Single port:

```nft
ip6 daddr 2409:8c54:1020:39:0:3156:2:e4 meta l4proto {tcp, udp} th dport 20000 dnat to [2400:c620:22:133::a]:20000
```

Range 1:1:

```nft
ip6 daddr 2409:8c54:1020:39:0:3156:2:e4 meta l4proto {tcp, udp} th dport { 20000-20020 } dnat to 2400:c620:22:133::a
```

Range offset:

```nft
ip6 daddr 2409:8c54:1020:39:0:3156:2:e4 meta l4proto {tcp, udp} th dport { 20000-20020 } dnat to 2400:c620:22:133::a : th dport map { 20000 : 30000, 20001 : 30001 }
```

### 10.4 IPv6 System Requirements

The tool must enable:

```text
net.ipv6.conf.all.forwarding=1
```

It must also preserve:

```text
net.ipv4.ip_forward=1
```

Status display should show:

```text
IPv4 forwarding: enabled/disabled
IPv6 forwarding: enabled/disabled
```

### 10.5 Family Compatibility Rules

Rules:

- IPv4 listen IP can forward only to IPv4 target IP.
- IPv6 listen IP can forward only to IPv6 target IP.
- Blank listen IP should follow target family.
- Domain target should resolve to A or AAAA based on selected family.

If the user enters mismatched IP families, show:

```text
错误：监听 IP 与目标地址协议族不一致。
```

## 11. DDNS Design

### 11.1 Problem

nftables can accept hostnames in rules, but hostname resolution happens when rules are loaded. If a DDNS domain later changes IP, existing kernel rules do not automatically update.

Therefore, DDNS support must be implemented as:

```text
domain input
-> resolve A/AAAA
-> write resolved IP to nftables
-> periodically re-resolve
-> update nftables only when changed
```

### 11.2 User Experience

Add rule prompt:

```text
Target address: example.ddns.net
Target family: auto / IPv4 / IPv6
```

Recommended default:

```text
auto
```

Auto behavior:

- If listen IP is IPv4, resolve A record.
- If listen IP is IPv6, resolve AAAA record.
- If listen IP is blank, ask user to choose IPv4 or IPv6 when both records exist.

### 11.3 Resolver Requirements

Supported resolver commands:

Preferred:

```text
getent ahostsv4 domain
getent ahostsv6 domain
```

Fallback:

```text
dig +short A domain
dig +short AAAA domain
```

Minimal dependency approach:

- Use `getent` first because it is commonly available.
- Install `dnsutils` only if advanced fallback is needed.

### 11.4 Metadata Storage

DDNS requires storing the original domain. nftables config alone is not enough once the domain is resolved to an IP.

Recommended metadata file:

```text
/etc/nft-port-forward/rules.tsv
```

Example:

```text
id	family	listen_ip	listen_start	listen_end	target_type	target_host	resolved_ip	target_start	target_end	mode
1	ipv4		20000	20000	domain	example.ddns.net	1.2.3.4	20000	20000	single
2	ipv6	2409:xxxx::1	20000	20020	domain	v6.example.net	2400:xxxx::a	20000	20020	range_1_to_1
```

### 11.5 DDNS Refresh

Refresh command:

```text
nft-helper --refresh-ddns
```

Menu option:

```text
Refresh DDNS Rules
```

Optional cron job:

```text
*/5 * * * * /usr/bin/nft-helper --refresh-ddns >/dev/null 2>&1
```

Refresh flow:

```text
read metadata
resolve domain
compare with resolved_ip
if unchanged: do nothing
if changed: rewrite managed rules
run nft -c -f
apply config
update metadata
```

Failure behavior:

- If DNS resolution fails, keep old IP and do not rewrite rule.
- If nft validation fails, keep old metadata and report error.
- Never clear a working rule because DDNS resolution temporarily failed.

## 12. Conflict Detection

Conflict key:

```text
family + listen_ip + listen_port_or_range
```

Wildcard listen IP behavior:

- Blank listen IP means wildcard.
- Wildcard conflicts with any specific listen IP on the same port or overlapping range.
- Specific listen IP conflicts only with the same specific listen IP or wildcard.

Examples:

Allowed:

```text
10.0.0.6:20000 -> 1.1.1.1:20000
10.0.0.7:20000 -> 2.2.2.2:20000
```

Rejected:

```text
0.0.0.0:20000 -> 1.1.1.1:20000
10.0.0.6:20000 -> 2.2.2.2:20000
```

Range overlap examples:

Rejected:

```text
20000-20020
20010-20030
```

Allowed:

```text
20000-20020
20021-20040
```

## 13. Validation Requirements

Before applying:

```bash
nft -c -f /etc/nftables.conf
```

If validation passes:

- Start service if stopped.
- Restart service if running.

If validation fails:

- Do not restart service.
- Show validation failure.
- Leave config file visible for manual correction.

## 14. Error Handling

Required error cases:

- Not root.
- nftables missing and install fails.
- Config missing markers.
- Port is not numeric.
- Port outside `1-65535`.
- Start port greater than end port.
- Target port range overflows `65535`.
- Rule conflicts with existing rule.
- DNS resolution fails.
- nft config validation fails.
- service start/restart fails.

## 15. Security and Safety

- Do not run downloaded remote scripts.
- Remove self-update feature.
- Back up config before destructive reset.
- Validate config before service restart.
- Do not overwrite user config unless explicitly confirmed.
- Do not delete working rules when DDNS refresh fails.

## 16. Implementation Plan

### Phase 1: Stabilize IPv4 Baseline

Scope:

- Remove self-update option.
- Rename title to `NFT Port Forwarding Tool`.
- Simplify menu.
- Auto-install nftables on first run.
- Auto-validate and apply config after changes.
- Fix single-port conflict detection.
- Fix range overlap detection.
- Revalidate conflicts during quick edit.

Acceptance criteria:

- Add single-port IPv4 rule works.
- Add non-overlapping range rule works.
- Add overlapping range rule is rejected.
- Add same port on different specific listen IPs works.
- Add wildcard listen IP conflict is rejected.
- Quick edit cannot create conflicting rules.
- Invalid nft config is not applied.

### Phase 2: Add IPv6 Direct-IP Support

Scope:

- Add IPv6 input validation.
- Add dual NAT tables: `ip nat` and `ip6 nat`.
- Add IPv6 rule generation.
- Enable IPv6 forwarding.
- Update view/edit/delete parser for IPv6.

Acceptance criteria:

- IPv6 single-port rule is generated correctly.
- IPv6 range rule is generated correctly.
- IPv4 rules continue to work.
- IPv4 and IPv6 conflicts are evaluated separately.
- Mismatched listen/target family is rejected.

### Phase 3: Add Domain Input

Scope:

- Accept domain as target address.
- Resolve domain during rule creation.
- Store original domain in metadata.
- Generate nftables rule using resolved IP.

Acceptance criteria:

- Domain with A record can create IPv4 forwarding rule.
- Domain with AAAA record can create IPv6 forwarding rule.
- Resolution failure stops rule creation with a clear message.
- View rules shows original domain and current resolved IP.

### Phase 4: Add DDNS Refresh

Scope:

- Add `--refresh-ddns`.
- Add menu option for manual refresh.
- Add optional cron setup.
- Re-resolve and update rules only when IP changes.

Acceptance criteria:

- Changed A/AAAA record updates nftables rule.
- Unchanged domain does not restart service.
- Failed DNS lookup keeps old working rule.
- Failed nft validation keeps old metadata.

### Phase 5: Polish Realm-Like UX

Scope:

- Add one-screen add wizard.
- Add compact rule list.
- Add rule IDs.
- Add import/export.
- Add optional non-interactive CLI commands.

Example CLI:

```bash
nft-helper add --listen :20000 --target example.com:20000 --family auto
nft-helper list
nft-helper delete 3
nft-helper refresh-ddns
```

## 17. Recommended Final Menu

```text
NFT Port Forwarding Tool

1. Add Forwarding Rule
2. Add Range Forwarding Rule
3. View Rules
4. Edit Rule
5. Delete Rule
6. Edit Raw Config
7. Refresh DDNS
8. Enable DDNS Auto Refresh
9. Disable DDNS Auto Refresh
10. Start Service
11. Stop Service
12. Restart Service
13. Clear Managed Rules
0. Exit
```

Phase 1 menu can omit DDNS items until implemented.

## 18. Open Questions

1. Should the shortcut remain `nft-helper`, or should it become `nft`?

2. Should the script preserve arbitrary user nftables rules outside the managed NAT block?

3. Should DDNS refresh use cron, systemd timer, or a manual menu option first?

4. Should the tool support TCP-only and UDP-only rules, or keep TCP+UDP as the default and only mode?

5. Should rule metadata be stored in TSV, INI, JSON, or shell-readable config?

## 19. Recommendation

Build from the initial script, not from the unstable expanded version.

The correct path is:

```text
Stable IPv4 baseline
-> IPv6 direct IP
-> domain target
-> DDNS refresh
-> cleaner realm-like UX
```

This keeps the working behavior intact while adding each advanced capability behind a clear boundary.
