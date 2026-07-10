#!/usr/bin/env bash
set -euo pipefail

script=${1:?usage: namespace-integration.sh /path/to/nftpf.sh}
[ "$EUID" -eq 0 ] || { echo 'namespace integration test must run as root' >&2; exit 1; }
for command in bash grep ip iptables ip6tables nft unshare; do
    command -v "$command" >/dev/null 2>&1 || { echo "missing test dependency: $command" >&2; exit 1; }
done

bash -n "$script"
bash "$script" --self-test

unshare -n bash -s -- "$script" <<'TEST'
set -euo pipefail

script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ip link set lo up

cat > "$work/legacy.nft" <<'EOF'
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport 4060 counter dnat to 127.0.0.1:9
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct status dnat masquerade
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}

table inet foreign_guard {
    chain input {
        type filter hook input priority filter; policy accept;
        counter comment "foreign-guard"
    }
}
EOF
nft -f "$work/legacy.nft"
iptables -t nat -A PREROUTING -i lo -p tcp --dport 4567 -m comment --comment foreign-phantun \
    -j DNAT --to-destination 127.0.0.1
iptables -t nat -A POSTROUTING -o lo -m comment --comment foreign-phantun-post -j MASQUERADE
iptables -A FORWARD -i lo -m comment --comment foreign-filter -j ACCEPT
ip6tables -t nat -A PREROUTING -i lo -p tcp --dport 4567 -m comment --comment foreign-ip6 \
    -j DNAT --to-destination ::1
ip6tables -t nat -A POSTROUTING -o lo -m comment --comment foreign-ip6-post -j MASQUERADE
iptables-save 2>/dev/null | grep '^-A' > "$work/iptables-baseline.txt"
ip6tables-save 2>/dev/null | grep '^-A' > "$work/ip6tables-baseline.txt"

export NFT_HELPER_SKIP_ROOT=1
source <(sed '/^run_cli "\$@"$/,$d' "$script")

CONFIG_FILE="$work/nftables.conf"
STATE_DIR="$work/state"
RULES_FILE="$STATE_DIR/rules.db"
LINES_FILE="$STATE_DIR/lines.db"
ACCESS_FILE="$STATE_DIR/access.conf"
BACKUP_DIR="$STATE_DIR/backups"
ACCESS_HISTORY_FILE="$STATE_DIR/access-history.log"
REAL_NFT_CMD=$(command -v nft)
NFTPF_IPV6_ROUTEFIX=off
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
printf '%s\n' '1|ipv4||4060|4060|ip|127.0.0.1|127.0.0.1|9|9|single|tcp_udp||none' > "$RULES_FILE"
: > "$LINES_FILE"
: > "$ACCESS_HISTORY_FILE"
printf '%s\n' 'mode=off' > "$ACCESS_FILE"

generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
MIGRATE_LEGACY_NAT=1
build_apply_transaction "$CONFIG_FILE" "$work/apply.nft"
grep -q '^delete chain ip nat prerouting$' "$work/apply.nft"
grep -q '^delete chain ip6 nat postrouting$' "$work/apply.nft"
if grep -q '^delete chain ip nat PREROUTING$' "$work/apply.nft"; then
    echo 'uppercase foreign chain scheduled for deletion' >&2
    exit 1
fi
nft -c -f "$work/apply.nft"
nft -f "$work/apply.nft"

nft list chain ip nat PREROUTING >/dev/null
nft list chain ip nat POSTROUTING >/dev/null
nft list chain ip6 nat PREROUTING >/dev/null
nft list table inet foreign_guard | grep 'foreign-guard' >/dev/null
iptables-save 2>/dev/null | grep '^-A' > "$work/iptables-after-migration.txt"
ip6tables-save 2>/dev/null | grep '^-A' > "$work/ip6tables-after-migration.txt"
cmp -s "$work/iptables-baseline.txt" "$work/iptables-after-migration.txt"
cmp -s "$work/ip6tables-baseline.txt" "$work/ip6tables-after-migration.txt"
if nft list chain ip nat prerouting >/dev/null 2>&1; then
    echo 'legacy IPv4 chain survived migration' >&2
    exit 1
fi
if nft list chain ip6 nat postrouting >/dev/null 2>&1; then
    echo 'legacy IPv6 chain survived migration' >&2
    exit 1
fi
nft list table ip nftpf_nat | grep 'dport 4060' >/dev/null

MIGRATE_LEGACY_NAT=0
build_apply_transaction "$CONFIG_FILE" "$work/reapply.nft"
nft -c -f "$work/reapply.nft"
nft -f "$work/reapply.nft"
nft list chain ip nat PREROUTING >/dev/null
nft list table inet foreign_guard | grep 'foreign-guard' >/dev/null
iptables-save 2>/dev/null | grep '^-A' > "$work/iptables-after-reapply.txt"
cmp -s "$work/iptables-baseline.txt" "$work/iptables-after-reapply.txt"

nft list ruleset > "$work/before-failure.nft"
cp "$CONFIG_FILE" "$work/invalid.conf"
printf '%s\n' 'this is invalid nft syntax' >> "$work/invalid.conf"
build_apply_transaction "$work/invalid.conf" "$work/invalid-apply.nft"
if nft -f "$work/invalid-apply.nft" >/dev/null 2>&1; then
    echo 'invalid transaction unexpectedly succeeded' >&2
    exit 1
fi
nft list ruleset > "$work/after-failure.nft"
cmp -s "$work/before-failure.nft" "$work/after-failure.nft"

unload_managed_rules
if nft list table ip nftpf_nat >/dev/null 2>&1; then
    echo 'managed IPv4 table survived unload' >&2
    exit 1
fi
nft list chain ip nat PREROUTING >/dev/null
nft list table inet foreign_guard | grep 'foreign-guard' >/dev/null
iptables-save 2>/dev/null | grep '^-A' > "$work/iptables-after-unload.txt"
cmp -s "$work/iptables-baseline.txt" "$work/iptables-after-unload.txt"

echo '[OK] namespace migration, coexistence, atomicity, and cleanup tests passed.'
TEST
