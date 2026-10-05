#!/usr/bin/env bash
set -euo pipefail
script=${1:?usage: jool-renderer.sh /path/to/nftpf.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export NFT_HELPER_SKIP_ROOT=1 NFT_HELPER_TEST_MODE=1
source <(sed '/^run_cli "\$@"$/,$d' "$script")
STATE_DIR="$work/state"
RULES_FILE="$STATE_DIR/rules.db"
LINES_FILE="$STATE_DIR/lines.db"
ACCESS_FILE="$STATE_DIR/access.conf"
JOOL_STATE_DIR="$STATE_DIR/jool-runtime"
NFTPF_IPV6_ROUTEFIX=off
mkdir -p "$STATE_DIR"
: > "$RULES_FILE"
: > "$LINES_FILE"
echo mode=off > "$ACCESS_FILE"

[[ "$(choose_rule_family :: 192.0.2.10 auto)" == ipv6 ]]
[[ "$(choose_rule_family 0.0.0.0 2001:db8::10 auto)" == ipv4 ]]
prepare_rule_record 1 single :: 4060 4060 192.0.2.10 2443 2443 auto '' none 'v6 to v4'
read_rule_fields "$PREPARED_RECORD"
[[ "$R_FAMILY" == ipv6 && "$R_TARGET_FAMILY" == ipv4 && -z "$R_LISTEN_IP" ]]
printf '%s\n' "$PREPARED_RECORD" > "$RULES_FILE"
prepare_rule_record 2 range_offset 0.0.0.0 21000 21002 2001:db8::10 443 445 auto '' none 'v4 to v6'
read_rule_fields "$PREPARED_RECORD"
[[ "$R_FAMILY" == ipv4 && "$R_TARGET_FAMILY" == ipv6 ]]
printf '%s\n' "$PREPARED_RECORD" >> "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$work/cross.nft"
grep -Fq '[fd64:6e66:7470:1::c000:20a]:2443' "$work/cross.nft"
grep -Fq 'dnat to 198.18.0.10 : th dport map { 21000 : 443, 21001 : 444, 21002 : 445 }' "$work/cross.nft"
grep -Fq 'iifname "npj1" ip saddr 198.18.0.6 ip daddr 192.0.2.10' "$work/cross.nft"
grep -Fq 'iifname "npj2" ip6 saddr fd64:6e66:7470:2::c612:9 ip6 daddr 2001:db8::10' "$work/cross.nft"
if grep -qE 'flush ruleset|v6 to v4|v4 to v6' "$work/cross.nft"; then exit 1; fi

# A DNS choice selects the target family, independently of the entry family.
resolve_domain() {
    case "$1/$2" in
        a-only.example/ipv4) echo 192.0.2.11 ;;
        aaaa-only.example/ipv6) echo 2001:db8::11 ;;
        *) return 1 ;;
    esac
}
prepare_rule_record 3 single 2001:db8::1 4443 4443 a-only.example 443 443 auto '' none 'DNS64 not required' ipv4
read_rule_fields "$PREPARED_RECORD"
[[ "$R_FAMILY" == ipv6 && "$R_TARGET_FAMILY" == ipv4 && "$R_TARGET_TYPE" == domain ]]
prepare_rule_record 4 single 192.0.2.1 4444 4444 aaaa-only.example 443 443 auto '' none '' auto
read_rule_fields "$PREPARED_RECORD"
[[ "$R_FAMILY" == ipv4 && "$R_TARGET_FAMILY" == ipv6 ]]

# Historical records infer target family; malformed/mismatched imported records fail.
read_rule_fields '9|ipv4||8080|8080|ip|192.0.2.9|192.0.2.9|80|80|single|tcp_udp||none|original note'
[[ "$R_TARGET_FAMILY" == ipv4 && "$R_NOTE" == 'original note' ]]
if rule_uses_jool; then exit 1; fi
printf '%s\n' '1|ipv6||4060|4060|ip|192.0.2.10|192.0.2.10|2443|2443|single|tcp_udp||none||ipv6' > "$work/bad.db"
if generate_config_from_rules "$work/bad.db" >/dev/null 2>&1; then exit 1; fi
if jool_addresses 0 >/dev/null 2>&1 || jool_addresses 32768 >/dev/null 2>&1; then exit 1; fi
jool_addresses 32767
[[ "$J_NS4" == 198.19.255.254 && "$J_VETH" == npj32767 ]]

# Unit rendering and rollback do not require a real unit manager or Jool module.
SHORTCUT_PATH="$work/installed script"
cp "$script" "$SHORTCUT_PATH"
chmod +x "$SHORTCUT_PATH"
JOOL_SERVICE_FILE="$work/nftpf-jool.service"
mkdir -p "$JOOL_STATE_DIR"
systemctl() { printf '%s\n' "$*" >> "$work/unit-calls"; return 0; }
install_jool_service
grep -Fq 'After=network-online.target nftables.service nftpf-route.service' "$JOOL_SERVICE_FILE"
grep -Fq "ExecStart=\"$SHORTCUT_PATH\" --apply-jool" "$JOOL_SERVICE_FILE"
grep -Fq ' --stop-jool' "$JOOL_SERVICE_FILE"
cp "$JOOL_SERVICE_FILE" "$work/original.service"
jool_snapshot_runtime
echo broken > "$JOOL_SERVICE_FILE"
jool_restore_runtime
cmp "$JOOL_SERVICE_FILE" "$work/original.service"
: > "$RULES_FILE"
install_jool_service
[[ ! -f "$JOOL_SERVICE_FILE" ]]

echo '[OK] cross-family renderer, wildcard, DNS family, and legacy schema tests passed.'
