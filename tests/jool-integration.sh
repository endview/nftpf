#!/usr/bin/env bash
set -euo pipefail
script=$(realpath "${1:?usage: jool-integration.sh /path/to/nftpf.sh}")
[[ "$EUID" -eq 0 ]] || { echo 'must run as root' >&2; exit 1; }
for dependency in jool modprobe nft ip tc python3 unshare; do command -v "$dependency" >/dev/null; done
modprobe jool

# Isolate /run/netns as well as networking: no namespace names or routes leak out.
unshare -mn bash -s -- "$script" <<'TEST'
set -euo pipefail
script=$1
mount --make-rprivate /
mount -t tmpfs tmpfs /run
ip link set lo up
work=$(mktemp -d)
export NFT_HELPER_SKIP_ROOT=1 NFTPF_JOOL_SKIP_SYSTEMD=1
source <(sed '/^run_cli "\$@"$/,$d' "$script")
STATE_DIR="$work/state"
RULES_FILE="$STATE_DIR/rules.db"
LINES_FILE="$STATE_DIR/lines.db"
ACCESS_FILE="$STATE_DIR/access.conf"
ACCESS_HISTORY_FILE="$STATE_DIR/access-history.log"
CONFIG_FILE="$work/nftables.conf"
BACKUP_DIR="$STATE_DIR/backups"
JOOL_STATE_DIR="$STATE_DIR/jool-runtime"
NFTPF_IPV6_ROUTEFIX=off
REAL_NFT_CMD=$(command -v nft)
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
: > "$LINES_FILE"
: > "$ACCESS_HISTORY_FILE"
echo mode=off > "$ACCESS_FILE"
# Unit manager stub: all packet translation remains real kernel Jool/nftables.
systemctl() { return 0; }
ensure_ipv6_dnat_policy_route() { return 0; }
cleanup() {
    stop_jool_runtime || true
    for name in client backend foreign-jool nftpf-jool-20; do ip netns del "$name" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

ip netns add client
ip netns add backend
ip link add entry0 type veth peer name eth0 netns client
ip link add exit0 type veth peer name eth0 netns backend
ip addr add 192.0.2.1/24 dev entry0
ip -6 addr add 2001:db8:1::1/64 dev entry0 nodad
ip addr add 198.51.100.1/24 dev exit0
ip -6 addr add 2001:db8:2::1/64 dev exit0 nodad
ip link set entry0 up
ip link set exit0 up
for name in client backend; do
    ip netns exec "$name" ip link set lo up
    ip netns exec "$name" ip link set eth0 up
done
ip netns exec client ip addr add 192.0.2.2/24 dev eth0
ip netns exec client ip -6 addr add 2001:db8:1::2/64 dev eth0 nodad
ip netns exec client ip -4 route add default via 192.0.2.1
ip netns exec client ip -6 route add default via 2001:db8:1::1
ip netns exec backend ip addr add 198.51.100.2/24 dev eth0
ip netns exec backend ip -6 addr add 2001:db8:2::2/64 dev eth0 nodad
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
sysctl -qw net.ipv4.conf.all.rp_filter=0

# Multipath defaults must not be mistaken for private-prefix collisions.
ip -4 route add default nexthop via 192.0.2.2 dev entry0 weight 1 nexthop via 198.51.100.2 dev exit0 weight 1
ip -6 route add default nexthop via 2001:db8:1::2 dev entry0 weight 1 nexthop via 2001:db8:2::2 dev exit0 weight 1

cat > "$work/echo.py" <<'PY'
import socket, sys, threading, time
def serve(family, sock_type, host, port):
    sock = socket.socket(family, sock_type)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6: sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind((host, port))
    if sock_type == socket.SOCK_STREAM:
        sock.listen(20)
        while True:
            client, peer = sock.accept()
            with client:
                while True:
                    data = client.recv(8192)
                    if not data: break
                    client.sendall(data)
    else:
        while True:
            data, peer = sock.recvfrom(8192)
            sock.sendto(data, peer)
for family, host in [(socket.AF_INET, '198.51.100.2'), (socket.AF_INET6, '2001:db8:2::2')]:
    for port in (2443, 2444, 2445, 53211):
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            threading.Thread(target=serve, args=(family, kind, host, port), daemon=True).start()
time.sleep(300)
PY
ip netns exec backend python3 "$work/echo.py" &
echo_pid=$!
trap 'kill "$echo_pid" 2>/dev/null || true; cleanup' EXIT
sleep 1
cat > "$work/probe.py" <<'PY'
import socket, sys
host, port, protocol = sys.argv[1], int(sys.argv[2]), sys.argv[3]
family = socket.AF_INET6 if ':' in host else socket.AF_INET
kind = socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM
with socket.socket(family, kind) as sock:
    sock.settimeout(3)
    sock.connect((host, port))
    payload = b'nftpf-jool-end-to-end-' + protocol.encode()
    sock.sendall(payload)
    assert sock.recv(4096) == payload
print('PASS', host, port, protocol)
PY
probe() { ip netns exec client python3 "$work/probe.py" "$@"; }

cat > "$RULES_FILE" <<'EOF'
1|ipv6|2001:db8:1::1|4060|4060|ip|198.51.100.2|198.51.100.2|2443|2443|single|tcp_udp||none|NAT64|ipv4
2|ipv4|192.0.2.1|4061|4061|ip|2001:db8:2::2|2001:db8:2::2|2443|2443|single|tcp_udp||none|static BIB|ipv6
3|ipv6|2001:db8:1::1|4100|4102|ip|198.51.100.2|198.51.100.2|2443|2445|range_offset|tcp_udp||none||ipv4
4|ipv4|192.0.2.1|4200|4202|ip|2001:db8:2::2|2001:db8:2::2|2443|2445|range_offset|tcp_udp||none||ipv6
5|ipv4|192.0.2.1|4300|4300|ip|198.51.100.2|198.51.100.2|2443|2443|single|tcp_udp||none|same family
6|ipv6|2001:db8:1::1|4400|4400|ip|198.51.100.2|198.51.100.2|2443|2443|single|tcp_udp|1|managed|managed NAT64|ipv4
7|ipv4|192.0.2.1|4401|4401|ip|2001:db8:2::2|2001:db8:2::2|2443|2443|single|tcp_udp|1|managed|managed BIB|ipv6
8|ipv4|192.0.2.1|4500|4500|ip|2001:db8:2::2|2001:db8:2::2|53211|53211|single|tcp_udp||none|high-port static BIB|ipv6
EOF
echo '1|test-entry|entry0|192.0.2.1|2001:db8:1::1|managed|1062|5004|5006|192.0.2.2|2001:db8:1::2|1' > "$LINES_FILE"
ip -4 route add 192.0.2.0/24 dev entry0 table 5004
ip -6 route add 2001:db8:1::/64 dev entry0 table 5006
apply_managed_routes
nft -f - <<'EOF'
table inet foreign_guard {
    chain forward {
        type filter hook forward priority filter; policy accept;
        counter comment "foreign-guard"
    }
}
EOF
ip netns add foreign-jool
ip netns exec foreign-jool jool instance add foreign --netfilter --pool6 2001:db8:ffff::/96

generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
apply_config_changes
for proto in tcp udp; do
    probe 2001:db8:1::1 4060 "$proto"
    probe 192.0.2.1 4061 "$proto"
    probe 2001:db8:1::1 4102 "$proto"
    probe 192.0.2.1 4202 "$proto"
    probe 192.0.2.1 4300 "$proto"
    probe 2001:db8:1::1 4400 "$proto"
    probe 192.0.2.1 4401 "$proto"
    probe 192.0.2.1 4500 "$proto"
done
ip -6 route show table 5006 | grep -q npj6
ip -4 route show table 5004 | grep -q npj7
inode_before=$(cat "$JOOL_STATE_DIR/1.inode")
if probe 198.18.0.10 2443 tcp >/dev/null 2>&1; then echo 'private BIB path bypassed frontend' >&2; exit 1; fi
if probe fd64:6e66:7470:1::c633:6402 2443 tcp >/dev/null 2>&1; then echo 'private NAT64 prefix bypassed frontend' >&2; exit 1; fi
apply_config_changes
[[ "$(cat "$JOOL_STATE_DIR/1.inode")" == "$inode_before" ]]
probe 2001:db8:1::1 4060 tcp

# Optional pacing owns only the namespace egress queue and preserves translators.
[[ "$(jool_read_pacing_rate)" == 0 ]]
for rate in '' -1 01 100001 '300;echo bad'; do
    if set_jool_pacing "$rate" >/dev/null 2>&1; then exit 1; fi
done
tc qdisc replace dev entry0 root handle 9fff: fq
ip netns exec nftpf-jool-1 tc qdisc replace dev nftpf0 root handle 8fff: fq
if set_jool_pacing 300 >/dev/null 2>&1; then echo 'foreign queue was overwritten' >&2; exit 1; fi
ip netns exec nftpf-jool-1 tc qdisc show dev nftpf0 | grep -q 'fq 8fff:'
[[ "$(jool_read_pacing_rate)" == 0 ]]
ip netns exec nftpf-jool-1 tc qdisc del dev nftpf0 root
ip netns exec client python3 - "$work" <<'PY' &
import pathlib,socket,sys,time
work=pathlib.Path(sys.argv[1])
with socket.create_connection(('2001:db8:1::1',4060),timeout=5) as sock:
    sock.sendall(b'before-pacing');assert sock.recv(128)==b'before-pacing'
    work.joinpath('connection-ready').touch()
    deadline=time.monotonic()+15
    while not work.joinpath('pacing-enabled').exists():
        assert time.monotonic()<deadline
        time.sleep(.05)
    sock.sendall(b'after-pacing');assert sock.recv(128)==b'after-pacing'
print('PASS persistent TCP connection survives pacing enable')
PY
connection_pid=$!
for attempt in {1..100}; do [[ ! -f "$work/connection-ready" ]] || break; sleep .05; done
[[ -f "$work/connection-ready" ]]
set_jool_pacing 300
touch "$work/pacing-enabled"
wait "$connection_pid"
[[ "$(jool_read_pacing_rate)" == 300 ]]
[[ "$(cat "$JOOL_STATE_DIR/1.inode")" == "$inode_before" ]]
assert_pacing() {
    ip netns exec "nftpf-jool-$1" tc -j qdisc show dev nftpf0 |
        python3 -c 'import json,sys; q=json.load(sys.stdin)[0]; assert q["kind"]=="fq" and q["handle"]=="7fff:" and q["options"]["maxrate"]==37500000, q'
}
assert_pacing 1
assert_pacing 2
tc qdisc show dev entry0 | grep -q 'fq 9fff:'
tc qdisc show dev npj1 | grep -q noqueue
for proto in tcp udp; do
    probe 2001:db8:1::1 4060 "$proto"
    probe 192.0.2.1 4061 "$proto"
done
apply_config_changes
assert_pacing 1
[[ "$(cat "$JOOL_STATE_DIR/1.inode")" == "$inode_before" ]]

# A partial queue update restores the persisted value and queues already changed.
touch "$work/fail-pacing-once"
ip() {
    if [[ "$*" == 'netns exec nftpf-jool-2 tc qdisc replace '* && -e "$work/fail-pacing-once" ]]; then
        rm "$work/fail-pacing-once"
        return 1
    fi
    command ip "$@"
}
if set_jool_pacing 400; then echo 'injected pacing failure succeeded' >&2; exit 1; fi
unset -f ip
[[ "$(jool_read_pacing_rate)" == 300 ]]
assert_pacing 1
assert_pacing 2
create_state_backup pacing-test 1
tar -tzf "$LAST_BACKUP_PATH" | grep -q jool-pacing.conf
cp "$LAST_BACKUP_PATH" "$work/paced.tar.gz"
mkdir "$work/legacy"
tar -xzf "$LAST_BACKUP_PATH" -C "$work/legacy"
rm "$work/legacy/jool-pacing.conf"
tar -czf "$work/legacy.tar.gz" -C "$work/legacy" .
nft_run() {
    if [[ "${1:-}" == -f ]]; then return 1; fi
    "$REAL_NFT_CMD" "$@"
}
if restore_backup_path "$work/legacy.tar.gz"; then echo 'injected import failure succeeded' >&2; exit 1; fi
[[ "$(jool_read_pacing_rate)" == 300 ]]
assert_pacing 1
unset -f nft_run
nft_run() { "$REAL_NFT_CMD" "$@"; }
restore_backup_path "$work/legacy.tar.gz"
[[ "$(jool_read_pacing_rate)" == 0 ]]
ip netns exec nftpf-jool-1 tc qdisc show dev nftpf0 | grep -q noqueue
restore_backup_path "$work/paced.tar.gz"
assert_pacing 1
[[ "$(cat "$JOOL_STATE_DIR/1.inode")" == "$inode_before" ]]

# Match source ACLs against the original entry, not the translated backend family.
printf '%s\n' mode=blacklist 'entry=ipv6|2001:db8:1::2' > "$ACCESS_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
apply_config_changes
if probe 2001:db8:1::1 4060 tcp >/dev/null 2>&1; then exit 1; fi
probe 192.0.2.1 4061 tcp
echo mode=off > "$ACCESS_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
apply_config_changes

# A successful edit rebuilds only the affected backend path.
sed -i '1s/2443|2443/2444|2444/' "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
apply_config_changes
probe 2001:db8:1::1 4060 tcp
probe 2001:db8:1::1 4060 udp

# A failed kernel transaction must restore the previously active translator spec.
cp "$RULES_FILE" "$work/previous.db"
sed -i '1s/2444|2444/2445|2445/' "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
nft_run() {
    if [[ "${1:-}" == -f ]]; then return 1; fi
    "$REAL_NFT_CMD" "$@"
}
if apply_config_changes; then echo 'injected nft failure unexpectedly succeeded' >&2; exit 1; fi
grep -Fq '|2444|2444|' "$JOOL_STATE_DIR/1.rule"
assert_pacing 1
unset -f nft_run
nft_run() { "$REAL_NFT_CMD" "$@"; }
cp "$work/previous.db" "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
probe 2001:db8:1::1 4060 tcp

# Namespace, link and address collisions must preserve foreign resources and live rules.
cp "$RULES_FILE" "$work/previous.db"
echo '20|ipv6|2001:db8:1::1|5020|5020|ip|198.51.100.2|198.51.100.2|2443|2443|single|tcp_udp||none||ipv4' >> "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
ip netns add nftpf-jool-20
if apply_config_changes; then exit 1; fi
ip netns list | grep -Eq '^nftpf-jool-20($| )'
ip netns del nftpf-jool-20
ip link add npj20 type veth peer name foreign-peer
if apply_config_changes; then exit 1; fi
ip link show npj20 >/dev/null
ip link del npj20
ip -4 route add 198.18.0.80/30 dev exit0
if apply_config_changes; then exit 1; fi
ip -4 route show | grep -q '^198.18.0.80/30'
ip -4 route del 198.18.0.80/30 dev exit0

# Inject a late resource preparation failure after the namespace is owned.
ip() {
    if [[ "$*" == 'link add npj20 '* ]]; then return 1; fi
    command ip "$@"
}
if apply_config_changes; then exit 1; fi
unset -f ip
[[ ! -f "$JOOL_STATE_DIR/20.rule" ]]
if ip netns list | grep -q '^nftpf-jool-20'; then exit 1; fi
cp "$work/previous.db" "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
probe 2001:db8:1::1 4060 tcp

# Delete just one rule, then simulate reboot by destroying and restoring all paths.
cp "$RULES_FILE" "$work/before-delete.db"
sed -i '/^3|/d' "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
nft_run() {
    if [[ "${1:-}" == -f ]]; then return 1; fi
    "$REAL_NFT_CMD" "$@"
}
if apply_config_changes; then echo 'failed delete unexpectedly succeeded' >&2; exit 1; fi
unset -f nft_run
nft_run() { "$REAL_NFT_CMD" "$@"; }
cp "$work/before-delete.db" "$RULES_FILE"
probe 2001:db8:1::1 4102 udp
sed -i '/^3|/d' "$RULES_FILE"
generate_config_from_rules "$RULES_FILE" > "$CONFIG_FILE"
apply_config_changes
if ip link show npj3 >/dev/null 2>&1; then exit 1; fi
probe 192.0.2.1 4061 udp
stop_jool_runtime
apply_jool_runtime
assert_pacing 1
assert_pacing 2
probe 2001:db8:1::1 4060 tcp
probe 192.0.2.1 4061 udp
nft list table inet foreign_guard | grep -q foreign-guard
ip netns exec foreign-jool jool -i foreign global display >/dev/null

set_jool_pacing off
[[ "$(jool_read_pacing_rate)" == 0 ]]
ip netns exec nftpf-jool-1 tc qdisc show dev nftpf0 | grep -q noqueue
[[ ! -f "$JOOL_STATE_DIR/1.pacing" ]]
probe 2001:db8:1::1 4060 tcp
tc qdisc show dev entry0 | grep -q 'fq 9fff:'

unload_managed_rules
stop_jool_runtime
[[ -z "$(ip netns list | awk '$1 ~ /^nftpf-jool-/ {print $1}')" ]]
nft list table inet foreign_guard >/dev/null
ip netns exec foreign-jool jool -i foreign global display >/dev/null
echo '[OK] real Jool TCP/UDP, both directions, pacing, persistent TCP, backups, ranges, policy routes, ACLs, reuse, edits, rollback, restore, collision safety, and coexistence tests passed.'
TEST
