#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="${CONFIG_FILE:-/etc/nftables.conf}"
STATE_DIR="${STATE_DIR:-/etc/nft-port-forward}"
RULES_FILE="${RULES_FILE:-$STATE_DIR/rules.db}"
SHORTCUT_PATH="${SHORTCUT_PATH:-/usr/local/bin/nftpf}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/nft-port-forward-ddns}"
SERVICE_NAME="nftables"
REAL_NFT_CMD="${REAL_NFT_CMD:-}"
APPLY_RESULT=""
CONFIG_AUTO_REBUILT=0
IPV6_ROUTE_MARK="${IPV6_ROUTE_MARK:-100}"
IPV6_ROUTE_TABLE="${IPV6_ROUTE_TABLE:-100}"
NFTPF_IPV6_ROUTEFIX="${NFTPF_IPV6_ROUTEFIX:-auto}"

if [[ "${NFT_HELPER_SKIP_ROOT:-0}" != "1" && $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

SYS_TYPE="Linux (systemd)"

find_nft_cmd() {
    local candidate
    local resolved_candidate
    local resolved_self
    local resolved_shortcut

    if [[ -n "$REAL_NFT_CMD" && -x "$REAL_NFT_CMD" ]]; then
        return 0
    fi

    REAL_NFT_CMD=""
    resolved_self=$(realpath "$0" 2>/dev/null || echo "$0")
    resolved_shortcut=$(realpath "$SHORTCUT_PATH" 2>/dev/null || echo "$SHORTCUT_PATH")

    for candidate in /usr/sbin/nft /sbin/nft /usr/bin/nft /bin/nft "$(command -v nft 2>/dev/null)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue

        resolved_candidate=$(realpath "$candidate" 2>/dev/null || echo "$candidate")
        [[ "$resolved_candidate" != "$resolved_self" && "$resolved_candidate" != "$resolved_shortcut" ]] || continue

        # Avoid old shortcut scripts named "nft" shadowing the real nftables binary.
        if [ "$(head -c 2 "$candidate" 2>/dev/null)" = "#!" ]; then
            continue
        fi

        REAL_NFT_CMD="$candidate"
        return 0
    done

    return 1
}

nft_run() {
    if ! find_nft_cmd; then
        echo -e "${RED}错误: 未找到 nft 命令。${PLAIN}"
        return 1
    fi

    "$REAL_NFT_CMD" "$@"
}

pause_and_return() {
    echo ""
    echo -e "${YELLOW}按下任意键返回主菜单...${PLAIN}"
    read -n 1 -s -r
    main_menu
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    touch "$RULES_FILE"
}

backup_file() {
    local file=$1
    local backup

    if [ -f "$file" ]; then
        backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$file" "$backup"
        echo -e "${YELLOW}已备份: $backup${PLAIN}"
    fi
}

ensure_sysctl_setting() {
    local key=$1
    local value=$2

    if [ ! -f /etc/sysctl.conf ]; then
        touch /etc/sysctl.conf
    fi

    if ! grep -q "^$key=$value$" /etc/sysctl.conf; then
        sed -i "/^$key=/d" /etc/sysctl.conf
        echo "$key=$value" >> /etc/sysctl.conf
        return 0
    fi

    return 1
}

enable_ip_forward() {
    if [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]]; then
        return 0
    fi

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

    local changed=0
    ensure_sysctl_setting "net.ipv4.ip_forward" "1" && changed=1
    ensure_sysctl_setting "net.ipv6.conf.all.forwarding" "1" && changed=1

    if [ "$changed" -eq 1 ]; then
        sysctl -p >/dev/null 2>&1
    fi
}

persist_ipv6_dnat_policy_route_ifupdown() {
    local config_file="/etc/network/interfaces.d/50-cloud-init"

    ipv6_routefix_should_enable || return 0
    [[ "${NFT_HELPER_PERSIST_ROUTEFIX:-1}" == "1" ]] || return 0
    [ -f "$config_file" ] || return 0
    grep -q "table $IPV6_ROUTE_TABLE" "$config_file" || return 0
    grep -q "gateway fd00::1" "$config_file" || return 0
    grep -q "nftpf IPv6 DNAT route fix" "$config_file" && return 0

    backup_file "$config_file"
    cat >> "$config_file" <<EOF
    # nftpf IPv6 DNAT route fix
    post-up ip -6 rule add fwmark $IPV6_ROUTE_MARK table $IPV6_ROUTE_TABLE pref $IPV6_ROUTE_MARK 2>/dev/null || true
    pre-down ip -6 rule del fwmark $IPV6_ROUTE_MARK table $IPV6_ROUTE_TABLE pref $IPV6_ROUTE_MARK 2>/dev/null || true
EOF
    echo -e "${YELLOW}已写入 IPv6 DNAT 回程路由持久化规则。${PLAIN}"
}

ipv6_routefix_should_enable() {
    case "$NFTPF_IPV6_ROUTEFIX" in
        on|ON|1|true|TRUE|yes|YES|enable|ENABLE)
            return 0
            ;;
        off|OFF|0|false|FALSE|no|NO|disable|DISABLE)
            return 1
            ;;
        auto|AUTO|"")
            ;;
        *)
            echo -e "${YELLOW}警告：NFTPF_IPV6_ROUTEFIX=$NFTPF_IPV6_ROUTEFIX 无效，已按 auto 处理。${PLAIN}" >&2
            ;;
    esac

    command -v ip >/dev/null 2>&1 || return 1
    ip -6 route show table "$IPV6_ROUTE_TABLE" 2>/dev/null | grep -q "^default " || return 1
    ip -6 rule show 2>/dev/null | grep -Eq "lookup $IPV6_ROUTE_TABLE( |$)" || return 1
    ip -6 addr show scope global 2>/dev/null | grep -q "fd00:" || return 1
    ip -6 route show default 2>/dev/null | grep -q "via fd00:" || return 1

    return 0
}

ensure_ipv6_dnat_policy_route() {
    local mark_hex

    [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]] && return 0
    command -v ip >/dev/null 2>&1 || return 0
    ipv6_routefix_should_enable || return 0

    mark_hex=$(printf '0x%x' "$IPV6_ROUTE_MARK")
    if ! ip -6 rule show | grep -Eq "fwmark $mark_hex .*lookup $IPV6_ROUTE_TABLE|fwmark $IPV6_ROUTE_MARK .*lookup $IPV6_ROUTE_TABLE"; then
        ip -6 rule add fwmark "$IPV6_ROUTE_MARK" table "$IPV6_ROUTE_TABLE" pref "$IPV6_ROUTE_MARK" 2>/dev/null || true
    fi

    persist_ipv6_dnat_policy_route_ifupdown
}

check_dependencies() {
    enable_ip_forward
    ensure_ipv6_dnat_policy_route

    if [[ "${NFT_HELPER_TEST_MODE:-0}" != "1" ]] && ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}错误：当前版本仅支持 systemd 系统。${PLAIN}"
        return 1
    fi

    if ! find_nft_cmd; then
        echo -e "${YELLOW}检测到系统未安装 nftables，正在安装...${PLAIN}"
        if [[ "${NFT_HELPER_TEST_MODE:-0}" != "1" ]]; then
            if ! command -v apt-get >/dev/null 2>&1; then
                echo -e "${RED}错误：未找到 apt-get，请手动安装 nftables 后重试。${PLAIN}"
                return 1
            fi
            apt-get update
            apt-get install -y nftables
            systemctl enable nftables
        fi
        find_nft_cmd || return 1
    fi

    ensure_state_dir

    CONFIG_AUTO_REBUILT=0
    init_config || return 1

    if [ "$CONFIG_AUTO_REBUILT" -eq 1 ]; then
        echo -e "${YELLOW}检测到托管配置已自动修复，正在立即校验并应用。${PLAIN}"
        if apply_config_changes; then
            show_apply_result
        else
            return 1
        fi
    fi
}

check_ddns_runtime() {
    enable_ip_forward
    ensure_ipv6_dnat_policy_route

    if ! find_nft_cmd; then
        echo -e "${RED}错误：未找到 nft 命令，DDNS 刷新已停止。${PLAIN}"
        return 1
    fi

    ensure_state_dir

    CONFIG_AUTO_REBUILT=0
    init_config || return 1

    if [ "$CONFIG_AUTO_REBUILT" -eq 1 ]; then
        apply_config_changes || return 1
    fi
}

check_shortcut() {
    if [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]]; then
        return 0
    fi

    if [ ! -f "$SHORTCUT_PATH" ] || [[ "$(realpath "$0" 2>/dev/null)" != "$(realpath "$SHORTCUT_PATH" 2>/dev/null)" ]]; then
        cp "$0" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
    fi
}

is_valid_ipv4() {
    local ip=$1
    local old_ifs
    local a b c d part

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    old_ifs=$IFS
    IFS='.'
    read -r a b c d <<< "$ip"
    IFS=$old_ifs

    for part in "$a" "$b" "$c" "$d"; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
    done
}

is_valid_ipv6() {
    local ip=$1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
}

is_valid_hostname() {
    local host=$1
    local label
    local old_ifs

    [[ ${#host} -ge 1 && ${#host} -le 253 ]] || return 1
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

    old_ifs=$IFS
    IFS='.'
    read -r -a labels <<< "$host"
    IFS=$old_ifs

    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

classify_host() {
    local host=$1

    if is_valid_ipv4 "$host"; then
        echo "ipv4"
    elif is_valid_ipv6 "$host"; then
        echo "ipv6"
    elif is_valid_hostname "$host"; then
        echo "domain"
    else
        echo "invalid"
    fi
}

normalize_listen_ip() {
    local ip=$1
    if [[ -z "$ip" || "$ip" == "0.0.0.0" || "$ip" == "::" ]]; then
        echo ""
    else
        echo "$ip"
    fi
}

validate_single_port() {
    local port=$1
    local name=$2

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：$name 必须是数字。${PLAIN}"
        return 1
    fi

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}错误：$name 必须在 1-65535 之间。${PLAIN}"
        return 1
    fi
}

validate_port_range() {
    local start=$1
    local end=$2
    local name=$3

    validate_single_port "$start" "$name 起始端口" || return 1
    validate_single_port "$end" "$name 结束端口" || return 1

    if [ "$start" -gt "$end" ]; then
        echo -e "${RED}错误：起始端口不能大于结束端口。${PLAIN}"
        return 1
    fi
}

display_host() {
    local host=$1
    if is_valid_ipv6 "$host"; then
        echo "[$host]"
    else
        echo "$host"
    fi
}

display_endpoint() {
    local host=$1
    local port=$2
    local shown

    shown=$(display_host "$host")
    if [[ -n "$port" ]]; then
        echo "$shown:$port"
    else
        echo "$shown"
    fi
}

default_listen_display() {
    case "$1" in
        ipv6) echo "::" ;;
        *) echo "0.0.0.0" ;;
    esac
}

format_listen_display() {
    local family=$1
    local listen_ip=$2
    local ports=$3
    local shown

    if [[ -z "$listen_ip" ]]; then
        shown=$(default_listen_display "$family")
    else
        shown="$listen_ip"
    fi

    shown=$(display_host "$shown")
    echo "$shown:$ports"
}

join_rule() {
    local IFS='|'
    echo "$*"
}

read_rule_fields() {
    local line=$1
    IFS='|' read -r R_ID R_FAMILY R_LISTEN_IP R_LISTEN_START R_LISTEN_END R_TARGET_TYPE R_TARGET_HOST R_RESOLVED_IP R_TARGET_START R_TARGET_END R_MODE R_PROTOCOL <<< "$line"
}

next_rule_id() {
    local max=0
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_ID" =~ ^[0-9]+$ ]] || continue
        [ "$R_ID" -gt "$max" ] && max=$R_ID
    done < "$RULES_FILE"

    echo $((max + 1))
}

rules_file_has_records() {
    grep -q '^[^#[:space:]]' "$RULES_FILE" 2>/dev/null
}

listen_ips_conflict() {
    local left
    local right
    left=$(normalize_listen_ip "$1")
    right=$(normalize_listen_ip "$2")

    [[ -z "$left" || -z "$right" || "$left" == "$right" ]]
}

ranges_overlap() {
    local start1=$1
    local end1=$2
    local start2=$3
    local end2=$4

    [ "$start1" -le "$end2" ] && [ "$start2" -le "$end1" ]
}

rule_conflicts_in_file() {
    local file=$1
    local family=$2
    local listen_ip=$3
    local start=$4
    local end=$5
    local exclude_id=$6
    local line

    listen_ip=$(normalize_listen_ip "$listen_ip")

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"

        [[ "$R_ID" == "$exclude_id" ]] && continue
        [[ "$R_FAMILY" == "$family" ]] || continue

        if ! listen_ips_conflict "$listen_ip" "$R_LISTEN_IP"; then
            continue
        fi

        if ranges_overlap "$start" "$end" "$R_LISTEN_START" "$R_LISTEN_END"; then
            return 0
        fi
    done < "$file"

    return 1
}

resolve_domain() {
    local domain=$1
    local family=$2
    local result=""

    if [ "$family" = "ipv4" ]; then
        result=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
        if [[ -z "$result" ]]; then
            result=$(getent hosts "$domain" 2>/dev/null | awk '$1 !~ /:/ {print $1; exit}')
        fi
        if [[ -z "$result" ]] && command -v dig >/dev/null 2>&1; then
            result=$(dig +short A "$domain" | awk '/^[0-9.]+$/ {print; exit}')
        fi
        is_valid_ipv4 "$result" && echo "$result" && return 0
    else
        result=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')
        if [[ -z "$result" ]]; then
            result=$(getent hosts "$domain" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
        fi
        if [[ -z "$result" ]] && command -v dig >/dev/null 2>&1; then
            result=$(dig +short AAAA "$domain" | awk '/:/ {print; exit}')
        fi
        is_valid_ipv6 "$result" && echo "$result" && return 0
    fi

    return 1
}

choose_rule_family() {
    local listen_ip=$1
    local target_host=$2
    local family_choice=$3
    local listen_family
    local target_kind

    listen_ip=$(normalize_listen_ip "$listen_ip")
    target_kind=$(classify_host "$target_host")

    if [[ -n "$listen_ip" ]]; then
        listen_family=$(classify_host "$listen_ip")
        if [[ "$listen_family" != "ipv4" && "$listen_family" != "ipv6" ]]; then
            echo "invalid"
            return 1
        fi
    fi

    case "$family_choice" in
        4|ipv4|IPv4) echo "ipv4"; return 0 ;;
        6|ipv6|IPv6) echo "ipv6"; return 0 ;;
    esac

    if [[ -n "$listen_family" ]]; then
        echo "$listen_family"
        return 0
    fi

    case "$target_kind" in
        ipv4) echo "ipv4" ;;
        ipv6) echo "ipv6" ;;
        domain)
            if resolve_domain "$target_host" "ipv4" >/dev/null 2>&1; then
                echo "ipv4"
            elif resolve_domain "$target_host" "ipv6" >/dev/null 2>&1; then
                echo "ipv6"
            else
                echo "invalid"
                return 1
            fi
            ;;
        *) echo "invalid"; return 1 ;;
    esac
}

resolve_target_for_rule() {
    local target_host=$1
    local family=$2
    local target_kind

    target_kind=$(classify_host "$target_host")
    RESOLVED_TARGET_TYPE=""
    RESOLVED_TARGET_IP=""

    case "$target_kind" in
        ipv4)
            [[ "$family" == "ipv4" ]] || return 1
            RESOLVED_TARGET_TYPE="ip"
            RESOLVED_TARGET_IP="$target_host"
            ;;
        ipv6)
            [[ "$family" == "ipv6" ]] || return 1
            RESOLVED_TARGET_TYPE="ip"
            RESOLVED_TARGET_IP="$target_host"
            ;;
        domain)
            RESOLVED_TARGET_TYPE="domain"
            RESOLVED_TARGET_IP=$(resolve_domain "$target_host" "$family") || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

validate_family_compatibility() {
    local family=$1
    local listen_ip=$2
    local target_host=$3
    local listen_family
    local target_kind

    listen_ip=$(normalize_listen_ip "$listen_ip")
    if [[ -n "$listen_ip" ]]; then
        listen_family=$(classify_host "$listen_ip")
        if [[ "$listen_family" != "$family" ]]; then
            echo -e "${RED}错误：监听 IP 与规则协议族不一致。${PLAIN}"
            return 1
        fi
    fi

    target_kind=$(classify_host "$target_host")
    if [[ "$target_kind" == "ipv4" && "$family" != "ipv4" ]]; then
        echo -e "${RED}错误：IPv4 目标不能写入 IPv6 规则。${PLAIN}"
        return 1
    fi

    if [[ "$target_kind" == "ipv6" && "$family" != "ipv6" ]]; then
        echo -e "${RED}错误：IPv6 目标不能写入 IPv4 规则。${PLAIN}"
        return 1
    fi
}

build_port_map() {
    local listen_start=$1
    local listen_end=$2
    local target_start=$3
    local l_port=$listen_start
    local r_port=$target_start
    local first=1
    local output="{ "

    while [ "$l_port" -le "$listen_end" ]; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            output="$output, "
        fi
        output="${output}${l_port} : ${r_port}"
        l_port=$((l_port + 1))
        r_port=$((r_port + 1))
    done

    echo "$output }"
}

build_dnat_target() {
    local family=$1
    local ip=$2
    local port=$3

    if [[ "$family" == "ipv6" && -n "$port" ]]; then
        echo "[$ip]:$port"
    elif [[ -n "$port" ]]; then
        echo "$ip:$port"
    else
        echo "$ip"
    fi
}

build_nft_rule_from_fields() {
    local listen_match=""
    local port_expr
    local dnat_target
    local map_str

    if [[ -n "$R_LISTEN_IP" ]]; then
        if [ "$R_FAMILY" = "ipv6" ]; then
            listen_match="ip6 daddr $R_LISTEN_IP "
        else
            listen_match="ip daddr $R_LISTEN_IP "
        fi
    fi

    if [ "$R_LISTEN_START" = "$R_LISTEN_END" ]; then
        port_expr="$R_LISTEN_START"
    else
        port_expr="{ $R_LISTEN_START-$R_LISTEN_END }"
    fi

    case "$R_MODE" in
        single)
            dnat_target=$(build_dnat_target "$R_FAMILY" "$R_RESOLVED_IP" "$R_TARGET_START")
            ;;
        range_1_to_1)
            dnat_target=$(build_dnat_target "$R_FAMILY" "$R_RESOLVED_IP" "")
            ;;
        range_offset)
            dnat_target=$(build_dnat_target "$R_FAMILY" "$R_RESOLVED_IP" "")
            map_str=$(build_port_map "$R_LISTEN_START" "$R_LISTEN_END" "$R_TARGET_START")
            echo "        ${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat_target : th dport map $map_str"
            return
            ;;
        *)
            return 1
            ;;
    esac

    echo "        ${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat_target"
}

parse_dnat_target() {
    local line=$1
    local payload
    local host
    local port=""

    payload=${line#*dnat to }
    payload=${payload%% : th dport map*}

    if [[ "$payload" == \[*\]:* ]]; then
        host=${payload#\[}
        host=${host%%]*}
        port=${payload#*]:}
    elif is_valid_ipv6 "$payload"; then
        host="$payload"
    elif [[ "$payload" == *:* ]]; then
        host=${payload%:*}
        port=${payload##*:}
    else
        host="$payload"
    fi

    PARSED_TARGET_HOST="$host"
    PARSED_TARGET_PORT="$port"
}

import_existing_rules_from_config() {
    local line
    local family=""
    local id
    local listen_ip
    local listen_start
    local listen_end
    local target_start
    local target_end
    local mode
    local map_part
    local first_map
    local last_map
    local tmp_rules
    local imported=0

    [ -f "$CONFIG_FILE" ] || return 0
    rules_file_has_records && return 0

    tmp_rules=$(mktemp) || return 1
    id=1

    while IFS= read -r line; do
        if echo "$line" | grep -q '^table ip nat {'; then
            family="ipv4"
            continue
        fi
        if echo "$line" | grep -q '^table ip6 nat {'; then
            family="ipv6"
            continue
        fi
        if [[ "$line" == "}" ]]; then
            family=""
            continue
        fi
        [[ -n "$family" && "$line" == *"dnat to"* ]] || continue

        listen_ip=""
        if [ "$family" = "ipv6" ]; then
            listen_ip=$(echo "$line" | grep -oP 'ip6 daddr \K[^ ]+' | head -1)
        else
            listen_ip=$(echo "$line" | grep -oP 'ip daddr \K[^ ]+' | head -1)
        fi

        if echo "$line" | grep -q 'th dport { '; then
            local listen_range
            listen_range=$(echo "$line" | grep -oP 'th dport \{ \K[0-9]+-[0-9]+' | head -1)
            listen_start=${listen_range%-*}
            listen_end=${listen_range#*-}
            if echo "$line" | grep -q 'th dport map'; then
                mode="range_offset"
                map_part=$(echo "$line" | grep -oP '\{ [0-9]+ : [0-9]+(, [0-9]+ : [0-9]+)* \}' | tail -1)
                first_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | head -1)
                last_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | tail -1)
                target_start=$(echo "$first_map" | cut -d: -f2 | tr -d ' ')
                target_end=$(echo "$last_map" | cut -d: -f2 | tr -d ' ')
            else
                mode="range_1_to_1"
                target_start="$listen_start"
                target_end="$listen_end"
            fi
        else
            mode="single"
            listen_start=$(echo "$line" | grep -oP 'th dport \K[0-9]+' | head -1)
            listen_end="$listen_start"
        fi

        [[ -n "$listen_start" && -n "$listen_end" ]] || continue
        parse_dnat_target "$line"
        [[ -n "$PARSED_TARGET_HOST" ]] || continue

        if [ "$mode" = "single" ]; then
            target_start="$PARSED_TARGET_PORT"
            target_end="$PARSED_TARGET_PORT"
            [[ -n "$target_start" ]] || continue
        fi

        join_rule "$id" "$family" "$listen_ip" "$listen_start" "$listen_end" "ip" "$PARSED_TARGET_HOST" "$PARSED_TARGET_HOST" "$target_start" "$target_end" "$mode" "tcp_udp" >> "$tmp_rules"
        id=$((id + 1))
        imported=$((imported + 1))
    done < "$CONFIG_FILE"

    if [ "$imported" -gt 0 ]; then
        mv "$tmp_rules" "$RULES_FILE"
        echo -e "${YELLOW}已从现有 nftables 配置导入 $imported 条托管规则。${PLAIN}"
    else
        rm -f "$tmp_rules"
    fi
}

render_rules_for_family() {
    local rules_file=$1
    local family=$2
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_FAMILY" == "$family" ]] || continue
        build_nft_rule_from_fields
    done < "$rules_file"
}

generate_config_from_rules() {
    local rules_file=$1
    local mark_hex

    mark_hex=$(printf '0x%08x' "$IPV6_ROUTE_MARK")

    cat <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # IPV4_MARKER_START
EOF
    render_rules_for_family "$rules_file" "ipv4"
    cat <<EOF
        # IPV4_MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct status dnat masquerade
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # IPV6_MARKER_START
EOF
    render_rules_for_family "$rules_file" "ipv6"
    cat <<EOF
        # IPV6_MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct status dnat masquerade
    }
}
EOF
    if ipv6_routefix_should_enable; then
        cat <<EOF
table ip6 nftpf_routefix {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ct direction reply ct status dnat meta mark set $mark_hex
    }
}
EOF
    fi
}

write_config_from_rules() {
    local rules_file=$1
    local tmp_config

    tmp_config=$(mktemp) || return 1
    generate_config_from_rules "$rules_file" > "$tmp_config"

    if ! nft_run -c -f "$tmp_config"; then
        rm -f "$tmp_config"
        echo -e "${RED}错误：生成的 nftables 配置校验失败，未覆盖当前配置。${PLAIN}"
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.last"
    fi

    mv "$tmp_config" "$CONFIG_FILE"
    chmod +x "$CONFIG_FILE"
}

init_config() {
    local routefix_enabled=0
    local needs_rebuild=0

    ensure_state_dir
    import_existing_rules_from_config

    if [ ! -f "$CONFIG_FILE" ]; then
        write_config_from_rules "$RULES_FILE" || return 1
        CONFIG_AUTO_REBUILT=1
        return 0
    fi

    ipv6_routefix_should_enable && routefix_enabled=1

    ! grep -q "IPV4_MARKER_START" "$CONFIG_FILE" && needs_rebuild=1
    ! grep -q "IPV6_MARKER_START" "$CONFIG_FILE" && needs_rebuild=1
    ! grep -q "ct status dnat masquerade" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 1 ] && ! grep -q "table ip6 nftpf_routefix" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 1 ] && ! grep -q "ct direction reply ct status dnat meta mark set" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 0 ] && grep -q "table ip6 nftpf_routefix" "$CONFIG_FILE" && needs_rebuild=1

    if [ "$needs_rebuild" -eq 1 ]; then
        echo -e "${YELLOW}检测到 nftables 配置需要重建或升级，正在备份并重建托管配置。${PLAIN}"
        backup_file "$CONFIG_FILE"
        write_config_from_rules "$RULES_FILE" || return 1
        CONFIG_AUTO_REBUILT=1
    fi
}

validate_nft_config() {
    nft_run -c -f "$CONFIG_FILE"
}

service_is_running() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

apply_config_changes() {
    APPLY_RESULT=""

    if ! validate_nft_config; then
        echo -e "${RED}错误：当前 nftables 配置校验失败，未应用。${PLAIN}"
        return 1
    fi

    ensure_ipv6_dnat_policy_route

    if [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]]; then
        APPLY_RESULT="tested"
        return 0
    fi

    if service_is_running; then
        if systemctl restart "$SERVICE_NAME"; then
            APPLY_RESULT="restarted"
            return 0
        fi
    else
        if systemctl start "$SERVICE_NAME"; then
            APPLY_RESULT="started"
            return 0
        fi
    fi

    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
    echo -e "${RED}错误：服务启动或重启失败，请查看上方错误信息。${PLAIN}"
    return 1
}

show_apply_result() {
    case "$APPLY_RESULT" in
        tested) echo -e "${GREEN}配置已通过校验（测试模式未操作服务）。${PLAIN}" ;;
        started) echo -e "${GREEN}配置已校验通过并自动应用，服务已启动。${PLAIN}" ;;
        restarted) echo -e "${GREEN}配置已校验通过并自动应用，服务已重启。${PLAIN}" ;;
        *) echo -e "${GREEN}配置已应用。${PLAIN}" ;;
    esac
}

commit_rules_file() {
    local tmp_rules=$1

    if ! write_config_from_rules "$tmp_rules"; then
        rm -f "$tmp_rules"
        return 1
    fi

    mv "$tmp_rules" "$RULES_FILE"

    if apply_config_changes; then
        show_apply_result
    else
        echo -e "${YELLOW}规则已保存，但服务未成功应用；修复问题后可使用“重启服务”。${PLAIN}"
    fi
}

append_rule_record() {
    local record=$1
    local tmp_rules

    tmp_rules=$(mktemp) || return 1
    cat "$RULES_FILE" > "$tmp_rules"
    echo "$record" >> "$tmp_rules"
    commit_rules_file "$tmp_rules"
}

update_rule_record() {
    local target_id=$1
    local record=$2
    local tmp_rules
    local line
    local replaced=0

    tmp_rules=$(mktemp) || return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read_rule_fields "$line"
        if [[ "$R_ID" == "$target_id" ]]; then
            echo "$record" >> "$tmp_rules"
            replaced=1
        else
            echo "$line" >> "$tmp_rules"
        fi
    done < "$RULES_FILE"

    if [ "$replaced" -ne 1 ]; then
        rm -f "$tmp_rules"
        echo -e "${RED}错误：未找到规则 ID $target_id。${PLAIN}"
        return 1
    fi

    commit_rules_file "$tmp_rules"
}

delete_rule_record() {
    local target_id=$1
    local tmp_rules
    local line
    local deleted=0

    tmp_rules=$(mktemp) || return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read_rule_fields "$line"
        if [[ "$R_ID" == "$target_id" ]]; then
            deleted=1
            continue
        fi
        echo "$line" >> "$tmp_rules"
    done < "$RULES_FILE"

    if [ "$deleted" -ne 1 ]; then
        rm -f "$tmp_rules"
        echo -e "${RED}错误：未找到规则 ID $target_id。${PLAIN}"
        return 1
    fi

    commit_rules_file "$tmp_rules"
}

collect_target_family() {
    local target_host=$1
    local listen_ip=$2
    local default_family=$3
    local target_kind
    local choice

    target_kind=$(classify_host "$target_host")

    if [[ "$target_kind" == "domain" ]]; then
        read -p "目标域名解析类型 [auto/4/6] (默认 ${default_family:-auto}): " choice
        choice=${choice:-${default_family:-auto}}
    else
        choice="${default_family:-auto}"
    fi

    CHOSEN_FAMILY=$(choose_rule_family "$listen_ip" "$target_host" "$choice") || return 1
    [[ "$CHOSEN_FAMILY" == "ipv4" || "$CHOSEN_FAMILY" == "ipv6" ]]
}

prepare_rule_record() {
    local id=$1
    local mode=$2
    local listen_ip=$3
    local listen_start=$4
    local listen_end=$5
    local target_host=$6
    local target_start=$7
    local target_end=$8
    local family_choice=$9

    listen_ip=$(normalize_listen_ip "$listen_ip")

    collect_target_family "$target_host" "$listen_ip" "$family_choice" || {
        echo -e "${RED}错误：无法确定规则协议族，请检查监听地址或目标地址。${PLAIN}"
        return 1
    }

    validate_family_compatibility "$CHOSEN_FAMILY" "$listen_ip" "$target_host" || return 1

    if ! resolve_target_for_rule "$target_host" "$CHOSEN_FAMILY"; then
        echo -e "${RED}错误：目标地址解析失败或协议族不匹配。${PLAIN}"
        return 1
    fi

    if rule_conflicts_in_file "$RULES_FILE" "$CHOSEN_FAMILY" "$listen_ip" "$listen_start" "$listen_end" "$id"; then
        echo -e "${RED}错误：该监听 IP/端口范围与现有规则冲突。${PLAIN}"
        return 1
    fi

    PREPARED_RECORD=$(join_rule "$id" "$CHOSEN_FAMILY" "$listen_ip" "$listen_start" "$listen_end" "$RESOLVED_TARGET_TYPE" "$target_host" "$RESOLVED_TARGET_IP" "$target_start" "$target_end" "$mode" "tcp_udp")
}

add_single_rule() {
    local id
    local listen_ip
    local listen_port
    local target_host
    local target_port

    echo -e "${YELLOW}=== 添加端口转发规则 (TCP+UDP) ===${PLAIN}"
    read -p "监听 IP (留空=自动匹配对应协议族所有地址): " listen_ip
    read -p "监听端口: " listen_port
    validate_single_port "$listen_port" "监听端口" || { pause_and_return; return; }

    read -p "目标 IP/域名: " target_host
    [[ -n "$target_host" ]] || { echo -e "${RED}错误：目标地址不能为空。${PLAIN}"; pause_and_return; return; }
    [[ "$(classify_host "$target_host")" != "invalid" ]] || { echo -e "${RED}错误：目标地址格式无效。${PLAIN}"; pause_and_return; return; }

    read -p "目标端口: " target_port
    validate_single_port "$target_port" "目标端口" || { pause_and_return; return; }

    id=$(next_rule_id)
    prepare_rule_record "$id" "single" "$listen_ip" "$listen_port" "$listen_port" "$target_host" "$target_port" "$target_port" "auto" || { pause_and_return; return; }

    if append_rule_record "$PREPARED_RECORD"; then
        echo -e "${GREEN}规则添加成功：ID $id${PLAIN}"
    fi
    pause_and_return
}

add_range_rule() {
    local id
    local listen_ip
    local listen_start
    local listen_end
    local target_host
    local mode_choice
    local mode
    local target_start
    local target_end
    local count

    echo -e "${YELLOW}=== 添加端口段转发规则 (TCP+UDP) ===${PLAIN}"
    read -p "监听 IP (留空=自动匹配对应协议族所有地址): " listen_ip
    read -p "监听起始端口: " listen_start
    read -p "监听结束端口: " listen_end
    validate_port_range "$listen_start" "$listen_end" "监听" || { pause_and_return; return; }

    read -p "目标 IP/域名: " target_host
    [[ -n "$target_host" ]] || { echo -e "${RED}错误：目标地址不能为空。${PLAIN}"; pause_and_return; return; }
    [[ "$(classify_host "$target_host")" != "invalid" ]] || { echo -e "${RED}错误：目标地址格式无效。${PLAIN}"; pause_and_return; return; }

    echo "[1] 1:1 映射"
    echo "[2] 端口段偏移"
    read -p "请选择映射模式 [1/2] (默认 1): " mode_choice
    mode_choice=${mode_choice:-1}
    count=$((listen_end - listen_start + 1))

    if [[ "$mode_choice" == "2" ]]; then
        mode="range_offset"
        read -p "目标起始端口: " target_start
        validate_single_port "$target_start" "目标起始端口" || { pause_and_return; return; }
        target_end=$((target_start + count - 1))
        if [ "$target_end" -gt 65535 ]; then
            echo -e "${RED}错误：目标结束端口 $target_end 超出 65535。${PLAIN}"
            pause_and_return
            return
        fi
    else
        mode="range_1_to_1"
        target_start="$listen_start"
        target_end="$listen_end"
    fi

    id=$(next_rule_id)
    prepare_rule_record "$id" "$mode" "$listen_ip" "$listen_start" "$listen_end" "$target_host" "$target_start" "$target_end" "auto" || { pause_and_return; return; }

    if append_rule_record "$PREPARED_RECORD"; then
        echo -e "${GREEN}端口段规则添加成功：ID $id${PLAIN}"
    fi
    pause_and_return
}

rule_summary_from_current() {
    local listen_display
    local target_display
    local target_note=""
    local mode_text

    if [ "$R_LISTEN_START" = "$R_LISTEN_END" ]; then
        listen_display=$(format_listen_display "$R_FAMILY" "$R_LISTEN_IP" "$R_LISTEN_START")
    else
        listen_display=$(format_listen_display "$R_FAMILY" "$R_LISTEN_IP" "$R_LISTEN_START-$R_LISTEN_END")
    fi

    if [ "$R_TARGET_TYPE" = "domain" ]; then
        target_note=" ($R_RESOLVED_IP)"
    fi

    if [ "$R_TARGET_START" = "$R_TARGET_END" ]; then
        target_display="$(display_endpoint "$R_TARGET_HOST" "$R_TARGET_START")$target_note"
    else
        target_display="$(display_endpoint "$R_TARGET_HOST" "$R_TARGET_START-$R_TARGET_END")$target_note"
    fi

    case "$R_MODE" in
        single) mode_text="单端口" ;;
        range_1_to_1) mode_text="端口段 1:1" ;;
        range_offset) mode_text="端口段偏移" ;;
        *) mode_text="$R_MODE" ;;
    esac

    echo "[$R_ID] [$R_FAMILY] [$mode_text] $listen_display -> $target_display"
}

view_rules() {
    local count=0
    local line

    echo -e "${YELLOW}=== 现有转发规则 ===${PLAIN}"
    echo "--------------------------------"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        rule_summary_from_current
        count=$((count + 1))
    done < "$RULES_FILE"

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}暂无转发规则。${PLAIN}"
    fi

    echo "--------------------------------"
    echo -e "总计: ${GREEN}$count${PLAIN} 条规则"
    pause_and_return
}

find_rule_by_id() {
    local id=$1
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        if [[ "$R_ID" == "$id" ]]; then
            FOUND_RULE="$line"
            return 0
        fi
    done < "$RULES_FILE"

    return 1
}

list_rules_compact() {
    local line
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        rule_summary_from_current
        count=$((count + 1))
    done < "$RULES_FILE"

    [ "$count" -gt 0 ]
}

read_with_default() {
    local prompt=$1
    local default=$2
    local value

    read -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

quick_edit_rule() {
    local id
    local listen_ip
    local listen_start
    local listen_end
    local target_host
    local target_start
    local target_end
    local mode
    local mode_choice
    local count
    local family_default

    echo -e "${YELLOW}=== 快速修改转发规则 ===${PLAIN}"
    if ! list_rules_compact; then
        echo -e "${YELLOW}暂无可修改规则。${PLAIN}"
        pause_and_return
        return
    fi

    read -p "请输入要修改的规则 ID (0 取消): " id
    [[ "$id" == "0" ]] && { main_menu; return; }
    find_rule_by_id "$id" || { echo -e "${RED}错误：未找到规则 ID。${PLAIN}"; pause_and_return; return; }
    read_rule_fields "$FOUND_RULE"

    family_default="$R_FAMILY"
    listen_ip=$(read_with_default "监听 IP (空=通配)" "$R_LISTEN_IP")
    listen_start=$(read_with_default "监听起始端口" "$R_LISTEN_START")
    listen_end=$(read_with_default "监听结束端口" "$R_LISTEN_END")
    validate_port_range "$listen_start" "$listen_end" "监听" || { pause_and_return; return; }

    target_host=$(read_with_default "目标 IP/域名" "$R_TARGET_HOST")
    [[ "$(classify_host "$target_host")" != "invalid" ]] || { echo -e "${RED}错误：目标地址格式无效。${PLAIN}"; pause_and_return; return; }

    if [ "$listen_start" = "$listen_end" ]; then
        mode="single"
        target_start=$(read_with_default "目标端口" "$R_TARGET_START")
        validate_single_port "$target_start" "目标端口" || { pause_and_return; return; }
        target_end="$target_start"
    else
        echo "[1] 1:1 映射"
        echo "[2] 端口段偏移"
        if [ "$R_MODE" = "range_offset" ]; then
            mode_choice=2
        else
            mode_choice=1
        fi
        mode_choice=$(read_with_default "映射模式 [1/2]" "$mode_choice")
        count=$((listen_end - listen_start + 1))
        if [[ "$mode_choice" == "2" ]]; then
            mode="range_offset"
            target_start=$(read_with_default "目标起始端口" "$R_TARGET_START")
            validate_single_port "$target_start" "目标起始端口" || { pause_and_return; return; }
            target_end=$((target_start + count - 1))
            if [ "$target_end" -gt 65535 ]; then
                echo -e "${RED}错误：目标结束端口 $target_end 超出 65535。${PLAIN}"
                pause_and_return
                return
            fi
        else
            mode="range_1_to_1"
            target_start="$listen_start"
            target_end="$listen_end"
        fi
    fi

    prepare_rule_record "$id" "$mode" "$listen_ip" "$listen_start" "$listen_end" "$target_host" "$target_start" "$target_end" "$family_default" || { pause_and_return; return; }

    if update_rule_record "$id" "$PREPARED_RECORD"; then
        echo -e "${GREEN}规则修改成功。${PLAIN}"
    fi
    pause_and_return
}

delete_rule() {
    local id

    echo -e "${YELLOW}=== 删除转发规则 ===${PLAIN}"
    if ! list_rules_compact; then
        echo -e "${YELLOW}暂无可删除规则。${PLAIN}"
        pause_and_return
        return
    fi

    read -p "请输入要删除的规则 ID (0 取消): " id
    [[ "$id" == "0" ]] && { main_menu; return; }
    find_rule_by_id "$id" || { echo -e "${RED}错误：未找到规则 ID。${PLAIN}"; pause_and_return; return; }
    read_rule_fields "$FOUND_RULE"
    echo -e "${YELLOW}即将删除:${PLAIN}"
    rule_summary_from_current
    read -p "确认删除？[y/n] (默认 y): " confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        echo -e "${YELLOW}已取消删除。${PLAIN}"
        pause_and_return
        return
    fi

    if delete_rule_record "$id"; then
        echo -e "${GREEN}规则已删除。${PLAIN}"
    fi
    pause_and_return
}

refresh_ddns() {
    local tmp_rules
    local line
    local new_ip
    local changed=0
    local failed=0

    tmp_rules=$(mktemp) || return 1

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"

        if [ "$R_TARGET_TYPE" = "domain" ]; then
            if new_ip=$(resolve_domain "$R_TARGET_HOST" "$R_FAMILY"); then
                if [[ "$new_ip" != "$R_RESOLVED_IP" ]]; then
                    R_RESOLVED_IP="$new_ip"
                    changed=1
                fi
            else
                echo -e "${YELLOW}警告：$R_TARGET_HOST 解析失败，保留旧地址 $R_RESOLVED_IP。${PLAIN}"
                failed=$((failed + 1))
            fi
        fi

        join_rule "$R_ID" "$R_FAMILY" "$R_LISTEN_IP" "$R_LISTEN_START" "$R_LISTEN_END" "$R_TARGET_TYPE" "$R_TARGET_HOST" "$R_RESOLVED_IP" "$R_TARGET_START" "$R_TARGET_END" "$R_MODE" "$R_PROTOCOL" >> "$tmp_rules"
    done < "$RULES_FILE"

    if [ "$changed" -eq 0 ]; then
        rm -f "$tmp_rules"
        echo -e "${GREEN}DDNS 检查完成，没有需要更新的规则。${PLAIN}"
        [ "$failed" -gt 0 ] && return 1
        return 0
    fi

    if commit_rules_file "$tmp_rules"; then
        echo -e "${GREEN}DDNS 已更新并重新应用配置。${PLAIN}"
        return 0
    fi
}

refresh_ddns_menu() {
    refresh_ddns
    pause_and_return
}

enable_ddns_auto_refresh() {
    local command_path
    local interval
    local cron_expr

    command_path="$SHORTCUT_PATH"
    if [ ! -x "$command_path" ]; then
        command_path=$(realpath "$0" 2>/dev/null || echo "$0")
    else
        command_path=$(realpath "$command_path" 2>/dev/null || echo "$command_path")
    fi

    read -p "请输入 DDNS 自动刷新间隔分钟数 (1-59，默认 5): " interval
    interval=${interval:-5}
    if [[ ! "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 59 ]; then
        echo -e "${RED}错误：刷新间隔必须是 1-59 之间的整数分钟。${PLAIN}"
        pause_and_return
        return
    fi
    cron_expr="*/$interval * * * *"

    if [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]]; then
        echo -e "${GREEN}测试模式：已跳过 cron 写入。${PLAIN}"
        pause_and_return
        return
    fi

    if ! command -v flock >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：未找到 flock，建议安装 util-linux 以避免 DDNS 刷新任务重叠。${PLAIN}"
    fi

cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$cron_expr root flock -n /run/nftpf.lock "$command_path" --refresh-ddns >/dev/null 2>&1
EOF
    echo -e "${GREEN}已启用 DDNS 自动刷新（每 $interval 分钟）。${PLAIN}"
    pause_and_return
}

disable_ddns_auto_refresh() {
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        echo -e "${GREEN}已关闭 DDNS 自动刷新。${PLAIN}"
    else
        echo -e "${YELLOW}DDNS 自动刷新当前未启用。${PLAIN}"
    fi
    pause_and_return
}

manage_service() {
    local action=$1

    case "$action" in
        enable) systemctl enable "$SERVICE_NAME" && echo -e "${GREEN}已设置开机自启。${PLAIN}" ;;
        disable) systemctl disable "$SERVICE_NAME" && echo -e "${GREEN}已取消开机自启。${PLAIN}" ;;
        start)
            if validate_nft_config && systemctl start "$SERVICE_NAME"; then
                echo -e "${GREEN}服务已启动。${PLAIN}"
            else
                systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
                echo -e "${RED}服务启动失败。${PLAIN}"
            fi
            ;;
        stop) systemctl stop "$SERVICE_NAME" && echo -e "${GREEN}服务已停止。${PLAIN}" ;;
        restart)
            if apply_config_changes; then
                show_apply_result
            fi
            ;;
    esac
    pause_and_return
}

clear_config() {
    echo -e "${RED}警告：此操作将清空本工具管理的所有转发规则。${PLAIN}"
    read -p "确认清空？[y/n]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消。${PLAIN}"
        pause_and_return
        return
    fi

    backup_file "$RULES_FILE"
    : > "$RULES_FILE"

    if write_config_from_rules "$RULES_FILE" && apply_config_changes; then
        show_apply_result
        echo -e "${GREEN}规则已清空。${PLAIN}"
    fi
    pause_and_return
}

get_status() {
    if find_nft_cmd; then
        local ver
        ver=$("$REAL_NFT_CMD" --version | awk '{print $2}')
        INSTALL_STATUS="${GREEN}已安装 ($ver)${PLAIN}"
    else
        INSTALL_STATUS="${RED}未安装${PLAIN}"
    fi

    RUN_STATUS="${RED}未运行${PLAIN}"
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" && RUN_STATUS="${GREEN}运行中${PLAIN}"

    local ip4
    local ip6
    ip4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    ip6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)

    if [ "$ip4" = "1" ] && [ "$ip6" = "1" ]; then
        FW_STATUS="${GREEN}IPv4/IPv6 已开启${PLAIN}"
    elif [ "$ip4" = "1" ]; then
        FW_STATUS="${YELLOW}仅 IPv4 已开启${PLAIN}"
    elif [ "$ip6" = "1" ]; then
        FW_STATUS="${YELLOW}仅 IPv6 已开启${PLAIN}"
    else
        FW_STATUS="${RED}未开启${PLAIN}"
    fi
}

main_menu() {
    clear
    get_status
    echo -e "################################################"
    echo -e "#           NFT Port Forwarding Tool           #"
    echo -e "#          系统: ${SYS_TYPE}        #"
    echo -e "################################################"
    echo -e "Nftables 状态: ${INSTALL_STATUS}"
    echo -e "服务运行 状态: ${RUN_STATUS}"
    echo -e "IP转发   状态: ${FW_STATUS}"
    echo -e "提示: 输入 nftpf 可快速启动本脚本"
    echo -e "${YELLOW}注意: 本工具生成配置时包含 flush ruleset，会清空当前 nftables 规则集。${PLAIN}"
    echo -e "################################################"
    echo -e " 1. 添加端口转发规则"
    echo -e " 2. 添加端口段转发规则"
    echo -e " 3. 查看现有转发规则"
    echo -e " 4. 快速修改转发规则"
    echo -e " 5. 删除转发规则"
    echo -e " 6. 清空所有规则"
    echo -e "------------------------------------------------"
    echo -e " 7. 设置开机自启"
    echo -e " 8. 取消开机自启"
    echo -e " 9. 启动服务"
    echo -e "10. 停止服务"
    echo -e "11. 重启服务"
    echo -e "------------------------------------------------"
    echo -e "12. 刷新 DDNS 规则"
    echo -e "13. 启用 DDNS 自动刷新"
    echo -e "14. 关闭 DDNS 自动刷新"
    echo -e " 0. 退出脚本"
    echo -e "################################################"
    read -p "请输入数字: " choice

    case "$choice" in
        1) add_single_rule ;;
        2) add_range_rule ;;
        3) view_rules ;;
        4) quick_edit_rule ;;
        5) delete_rule ;;
        6) clear_config ;;
        7) manage_service enable ;;
        8) manage_service disable ;;
        9) manage_service start ;;
        10) manage_service stop ;;
        11) manage_service restart ;;
        12) refresh_ddns_menu ;;
        13) enable_ddns_auto_refresh ;;
        14) disable_ddns_auto_refresh ;;
        0) echo -e "${GREEN}谢谢使用。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字。${PLAIN}"; sleep 1; main_menu ;;
    esac
}

run_cli() {
    local invoked_name
    invoked_name=$(basename "$0")

    case "${1:-}" in
        --refresh-ddns)
            check_ddns_runtime || exit 1
            refresh_ddns
            exit $?
            ;;
        --tool-help)
            echo "NFT Port Forwarding Tool"
            echo "Usage:"
            echo "  nftpf                  Open interactive forwarding menu"
            echo "  nftpf --refresh-ddns   Refresh DDNS/domain forwarding targets"
            echo "  nftpf --tool-help      Show this help"
            exit 0
            ;;
        --help|-h)
            echo "NFT Port Forwarding Tool"
            echo "Usage:"
            echo "  nftpf                  Open interactive forwarding menu"
            echo "  nftpf --refresh-ddns   Refresh DDNS/domain forwarding targets"
            echo "  nftpf --tool-help      Show this help"
            exit 0
            ;;
    esac
}

run_cli "$@"
check_dependencies || exit 1
check_shortcut
main_menu
