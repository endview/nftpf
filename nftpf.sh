#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

NFTPF_VERSION="${NFTPF_VERSION:-0.1.2}"
UPDATE_URL="${UPDATE_URL:-https://github.com/endview/nftpf/releases/latest/download/nftpf.sh}"
CONFIG_FILE="${CONFIG_FILE:-/etc/nftables.conf}"
STATE_DIR="${STATE_DIR:-/etc/nft-port-forward}"
RULES_FILE="${RULES_FILE:-$STATE_DIR/rules.db}"
LINES_FILE="${LINES_FILE:-$STATE_DIR/lines.db}"
ACCESS_FILE="${ACCESS_FILE:-$STATE_DIR/access.conf}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
ACCESS_HISTORY_FILE="${ACCESS_HISTORY_FILE:-$STATE_DIR/access-history.log}"
SHORTCUT_PATH="${SHORTCUT_PATH:-/usr/local/bin/nftpf}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/nft-port-forward-ddns}"
DDNS_SERVICE_FILE="${DDNS_SERVICE_FILE:-/etc/systemd/system/nftpf-ddns.service}"
DDNS_TIMER_FILE="${DDNS_TIMER_FILE:-/etc/systemd/system/nftpf-ddns.timer}"
ROUTE_SERVICE_FILE="${ROUTE_SERVICE_FILE:-/etc/systemd/system/nftpf-route.service}"
SERVICE_NAME="nftables"
REAL_NFT_CMD="${REAL_NFT_CMD:-}"
APPLY_RESULT=""
CONFIG_AUTO_REBUILT=0
CONFIG_RENDER_VERSION="3"
TRACK_TIMEOUT="${TRACK_TIMEOUT:-30m}"
IPV6_ROUTE_MARK="${IPV6_ROUTE_MARK:-100}"
IPV6_ROUTE_TABLE="${IPV6_ROUTE_TABLE:-100}"
NFTPF_IPV6_ROUTEFIX="${NFTPF_IPV6_ROUTEFIX:-auto}"

if [[ "${NFT_HELPER_SKIP_ROOT:-0}" != "1" && $EUID -ne 0 ]]; then
    case "${1:-}" in
        --help|-h|--tool-help|--version) ;;
        *)
            echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
            exit 1
            ;;
    esac
fi

SYS_TYPE="Linux (systemd)"

# -----------------------------------------------------------------------------
# Runtime helpers
# -----------------------------------------------------------------------------

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

pause_and_access_control() {
    echo ""
    echo -e "${YELLOW}按下任意键返回访问控制...${PLAIN}"
    read -n 1 -s -r
    access_control_menu
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$RULES_FILE"
    touch "$LINES_FILE"
    touch "$ACCESS_HISTORY_FILE"
    chmod 600 "$ACCESS_HISTORY_FILE" 2>/dev/null || true
    if [ ! -f "$ACCESS_FILE" ]; then
        echo "mode=off" > "$ACCESS_FILE"
    fi
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

create_state_backup() {
    local reason=${1:-manual}
    local quiet=${2:-0}
    local timestamp
    local safe_reason
    local tmp_dir
    local backup_path

    command -v tar >/dev/null 2>&1 || {
        [ "$quiet" = "1" ] || echo -e "${YELLOW}警告：未找到 tar，已跳过备份。${PLAIN}"
        return 0
    }

    ensure_state_dir
    timestamp=$(date +%Y%m%d%H%M%S)
    safe_reason=$(printf '%s' "$reason" | tr -c 'A-Za-z0-9_-' '_')
    tmp_dir=$(mktemp -d) || return 1
    backup_path="$BACKUP_DIR/nftpf-backup-${timestamp}-${safe_reason}.tar.gz"

    [ -f "$RULES_FILE" ] && cp "$RULES_FILE" "$tmp_dir/rules.db"
    [ -f "$LINES_FILE" ] && cp "$LINES_FILE" "$tmp_dir/lines.db"
    [ -f "$ACCESS_FILE" ] && cp "$ACCESS_FILE" "$tmp_dir/access.conf"
    [ -f "$ACCESS_HISTORY_FILE" ] && cp "$ACCESS_HISTORY_FILE" "$tmp_dir/access-history.log"
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$tmp_dir/nftables.conf"
    {
        echo "created_at=$timestamp"
        echo "reason=$reason"
        echo "config_file=$CONFIG_FILE"
        echo "rules_file=$RULES_FILE"
        echo "lines_file=$LINES_FILE"
        echo "access_file=$ACCESS_FILE"
        echo "access_history_file=$ACCESS_HISTORY_FILE"
    } > "$tmp_dir/meta.txt"

    tar -C "$tmp_dir" -czf "$backup_path" . || {
        rm -rf "$tmp_dir"
        return 1
    }
    cp "$backup_path" "$BACKUP_DIR/latest.tar.gz"
    case "$reason" in
        manual) cp "$backup_path" "$BACKUP_DIR/latest-manual.tar.gz" ;;
        *) cp "$backup_path" "$BACKUP_DIR/latest-auto.tar.gz" ;;
    esac
    rm -rf "$tmp_dir"

    LAST_BACKUP_PATH="$backup_path"
    [ "$quiet" = "1" ] || echo -e "${GREEN}备份已创建: $backup_path${PLAIN}"
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

# -----------------------------------------------------------------------------
# System setup and route handling
# -----------------------------------------------------------------------------

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

validate_update_candidate() {
    local candidate=$1

    if [ ! -s "$candidate" ]; then
        echo -e "${RED}错误：下载的更新文件为空。${PLAIN}"
        return 1
    fi

    if ! head -n 1 "$candidate" | grep -qx '#!/bin/bash'; then
        echo -e "${RED}错误：更新文件不是有效的 bash 脚本。${PLAIN}"
        return 1
    fi

    if ! grep -q 'NFT Port Forwarding Tool' "$candidate"; then
        echo -e "${RED}错误：更新文件缺少 nftpf 标识。${PLAIN}"
        return 1
    fi

    if ! grep -q 'main_menu()' "$candidate" || ! grep -q 'run_cli()' "$candidate"; then
        echo -e "${RED}错误：更新文件缺少必要函数。${PLAIN}"
        return 1
    fi

    if ! bash -n "$candidate"; then
        echo -e "${RED}错误：更新文件语法校验失败。${PLAIN}"
        return 1
    fi
}

download_update_candidate() {
    local destination=$1

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$destination" "$UPDATE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$UPDATE_URL"
    else
        echo -e "${RED}错误：未找到 curl 或 wget，无法下载更新。${PLAIN}"
        return 1
    fi
}

pause_after_update() {
    if [[ "${NFTPF_CLI_MODE:-0}" == "1" ]]; then
        return 0
    fi

    pause_and_return
}

update_script() {
    local current
    local target
    local tmp
    local backup
    local shortcut_backup=""
    local timestamp
    local confirm

    current=$(realpath "$0" 2>/dev/null || echo "$0")
    target="${NFTPF_UPDATE_TARGET:-$current}"
    timestamp=$(date +%Y%m%d%H%M%S)
    tmp=$(mktemp) || { echo -e "${RED}错误：无法创建临时文件。${PLAIN}"; pause_after_update; return 1; }

    echo -e "${YELLOW}=== 更新脚本 ===${PLAIN}"
    echo "当前版本: $NFTPF_VERSION"
    echo "更新来源: $UPDATE_URL"
    echo "目标脚本: $target"
    echo -e "${YELLOW}说明：更新只替换脚本文件，不修改转发规则，不重启 nftables。${PLAIN}"
    read -p "确认从 GitHub Releases latest 下载并更新？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        rm -f "$tmp"
        echo -e "${YELLOW}已取消更新。${PLAIN}"
        pause_after_update
        return 0
    fi

    if ! download_update_candidate "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}更新失败：无法下载更新文件。${PLAIN}"
        pause_after_update
        return 1
    fi

    if ! validate_update_candidate "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}更新失败：校验未通过，当前脚本未改变。${PLAIN}"
        pause_after_update
        return 1
    fi

    backup="${target}.bak.$timestamp"
    if [ -f "$target" ]; then
        cp "$target" "$backup" || {
            rm -f "$tmp"
            echo -e "${RED}更新失败：无法备份当前脚本。${PLAIN}"
            pause_after_update
            return 1
        }
    fi

    if [ -f "$SHORTCUT_PATH" ] && [ "$(realpath "$SHORTCUT_PATH" 2>/dev/null || echo "$SHORTCUT_PATH")" != "$target" ]; then
        shortcut_backup="${SHORTCUT_PATH}.bak.$timestamp"
        cp "$SHORTCUT_PATH" "$shortcut_backup" 2>/dev/null || shortcut_backup=""
    fi

    if ! install -m 755 "$tmp" "$target"; then
        [ -f "$backup" ] && cp "$backup" "$target" 2>/dev/null || true
        rm -f "$tmp"
        echo -e "${RED}更新失败：写入目标脚本失败，已尝试保留旧版本。${PLAIN}"
        pause_after_update
        return 1
    fi

    if [ "$target" != "$SHORTCUT_PATH" ]; then
        if ! cp "$target" "$SHORTCUT_PATH" 2>/dev/null; then
            [ -n "$shortcut_backup" ] && cp "$shortcut_backup" "$SHORTCUT_PATH" 2>/dev/null || true
            echo -e "${YELLOW}警告：主脚本已更新，但快捷命令 $SHORTCUT_PATH 更新失败。${PLAIN}"
        else
            chmod +x "$SHORTCUT_PATH" 2>/dev/null || true
        fi
    fi

    rm -f "$tmp"
    echo -e "${GREEN}脚本更新完成。${PLAIN}"
    [ -f "$backup" ] && echo -e "${YELLOW}旧版本备份: $backup${PLAIN}"
    pause_after_update
    return 0
}

# -----------------------------------------------------------------------------
# Input validation and normalization
# -----------------------------------------------------------------------------

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

validate_access_entry() {
    local entry=$1
    local base
    local prefix=""
    local family

    [[ -n "$entry" && "$entry" != *"|"* ]] || return 1

    if [[ "$entry" == */* ]]; then
        base=${entry%%/*}
        prefix=${entry##*/}
        [[ -n "$base" && "$prefix" =~ ^[0-9]+$ ]] || return 1
    else
        base="$entry"
    fi

    family=$(classify_host "$base")
    case "$family" in
        ipv4)
            [[ -z "$prefix" || ( "$prefix" -ge 0 && "$prefix" -le 32 ) ]] || return 1
            ;;
        ipv6)
            [[ -z "$prefix" || ( "$prefix" -ge 0 && "$prefix" -le 128 ) ]] || return 1
            ;;
        *)
            return 1
            ;;
    esac

    ACCESS_ENTRY_FAMILY="$family"
    ACCESS_ENTRY_VALUE="$entry"
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

# -----------------------------------------------------------------------------
# Rule database helpers
# -----------------------------------------------------------------------------

join_rule() {
    local IFS='|'
    echo "$*"
}

read_rule_fields() {
    local line=$1
    IFS='|' read -r R_ID R_FAMILY R_LISTEN_IP R_LISTEN_START R_LISTEN_END R_TARGET_TYPE R_TARGET_HOST R_RESOLVED_IP R_TARGET_START R_TARGET_END R_MODE R_PROTOCOL R_LINE_ID R_ROUTE_MODE <<< "$line"
    R_LINE_ID=${R_LINE_ID:-}
    R_ROUTE_MODE=${R_ROUTE_MODE:-none}
    case "$R_ROUTE_MODE" in
        none|iifonly|managed) ;;
        *) R_ROUTE_MODE="none" ;;
    esac
}

join_line() {
    local IFS='|'
    echo "$*"
}

read_line_fields() {
    local line=$1
    IFS='|' read -r L_ID L_NAME L_IFNAME L_IPV4 L_IPV6 L_MODE L_MARK L_TABLE4 L_TABLE6 L_GW4 L_GW6 L_ENABLED <<< "$line"
    L_MODE=${L_MODE:-iifonly}
    L_ENABLED=${L_ENABLED:-1}
    case "$L_MODE" in
        iifonly|managed) ;;
        *) L_MODE="iifonly" ;;
    esac
}

validate_ifname_value() {
    local ifname=$1

    if [[ ! "$ifname" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        echo -e "${RED}错误：网卡名只能包含字母、数字、点、下划线、冒号和短横线。${PLAIN}"
        return 1
    fi
}

next_line_id() {
    local max=0
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_line_fields "$line"
        [[ "$L_ID" =~ ^[0-9]+$ ]] || continue
        [ "$L_ID" -gt "$max" ] && max=$L_ID
    done < "$LINES_FILE"

    echo $((max + 1))
}

find_line_by_id() {
    local id=$1
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_line_fields "$line"
        if [ "$L_ID" = "$id" ]; then
            FOUND_LINE="$line"
            return 0
        fi
    done < "$LINES_FILE"

    return 1
}

line_display_from_fields() {
    local label
    local mode_label

    label="${L_NAME:-$L_IFNAME}"
    case "$L_MODE" in
        managed) mode_label="托管路由" ;;
        *) mode_label="仅入口绑定" ;;
    esac

    echo "$label / $L_IFNAME / IPv4:${L_IPV4:-无} / IPv6:${L_IPV6:-无} / $mode_label"
}

line_label_by_id() {
    local id=$1

    if [[ -n "$id" ]] && find_line_by_id "$id"; then
        read_line_fields "$FOUND_LINE"
        echo "${L_NAME:-$L_IFNAME}/$L_IFNAME"
    else
        echo "默认"
    fi
}

line_match_from_current() {
    if [[ -z "$R_LINE_ID" ]]; then
        return 0
    fi

    if ! find_line_by_id "$R_LINE_ID"; then
        echo "INVALID_NFTPF_MISSING_LINE_$R_LINE_ID "
        return 0
    fi

    read_line_fields "$FOUND_LINE"
    if [[ -z "$L_IFNAME" ]]; then
        echo "INVALID_NFTPF_EMPTY_IFNAME_$R_LINE_ID "
        return 0
    fi

    echo "iifname \"$L_IFNAME\" "
}

line_scopes_conflict() {
    local left=${1:-}
    local right=${2:-}

    [[ -z "$left" || -z "$right" || "$left" == "$right" ]]
}

line_has_managed_rules_in_file() {
    local rules_file=$1
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_ROUTE_MODE" == "managed" && -n "$R_LINE_ID" ]] || continue
        find_line_by_id "$R_LINE_ID" || continue
        read_line_fields "$FOUND_LINE"
        [[ "$L_MODE" == "managed" ]] && return 0
    done < "$rules_file"

    return 1
}

value_or_none() {
    local value=$1
    echo "${value:-无}"
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
    local line_id=${7:-}
    local line

    listen_ip=$(normalize_listen_ip "$listen_ip")

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"

        [[ "$R_ID" == "$exclude_id" ]] && continue
        [[ "$R_FAMILY" == "$family" ]] || continue

        if ! line_scopes_conflict "$line_id" "$R_LINE_ID"; then
            continue
        fi

        if ! listen_ips_conflict "$listen_ip" "$R_LISTEN_IP"; then
            continue
        fi

        if ranges_overlap "$start" "$end" "$R_LISTEN_START" "$R_LISTEN_END"; then
            return 0
        fi
    done < "$file"

    return 1
}

get_access_mode() {
    local mode

    mode=$(grep -m1 '^mode=' "$ACCESS_FILE" 2>/dev/null | cut -d= -f2)
    case "$mode" in
        whitelist|blacklist|off) echo "$mode" ;;
        *) echo "off" ;;
    esac
}

access_mode_label() {
    case "$(get_access_mode)" in
        whitelist) echo "白名单" ;;
        blacklist) echo "黑名单" ;;
        *) echo "关闭" ;;
    esac
}

access_entry_count() {
    if [ -f "$ACCESS_FILE" ]; then
        grep -c '^entry=' "$ACCESS_FILE" 2>/dev/null || true
    else
        echo 0
    fi
}

access_entries_for_family() {
    local family=$1

    grep "^entry=$family|" "$ACCESS_FILE" 2>/dev/null | cut -d'|' -f2-
}

format_access_entries_for_family() {
    local family=$1
    local entry
    local output=""
    local sep=""

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        output="${output}${sep}${entry}"
        sep=", "
    done < <(access_entries_for_family "$family")

    echo "$output"
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
    local line_match
    local listen_match=""
    local port_expr
    local dnat_target
    local map_str

    line_match=$(line_match_from_current)

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
            echo "        ${line_match}${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat_target : th dport map $map_str"
            return
            ;;
        *)
            return 1
            ;;
    esac

    echo "        ${line_match}${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat_target"
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

        join_rule "$id" "$family" "$listen_ip" "$listen_start" "$listen_end" "ip" "$PARSED_TARGET_HOST" "$PARSED_TARGET_HOST" "$target_start" "$target_end" "$mode" "tcp_udp" "" "none" >> "$tmp_rules"
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

# -----------------------------------------------------------------------------
# nftables rendering
# -----------------------------------------------------------------------------

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

rules_file_has_family_in_file() {
    local rules_file=$1
    local family=$2
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_FAMILY" == "$family" ]] && return 0
    done < "$rules_file"

    return 1
}

rules_file_has_family() {
    rules_file_has_family_in_file "$RULES_FILE" "$1"
}

build_forward_match_from_current() {
    local line_match
    local listen_match=""
    local port_expr

    line_match=$(line_match_from_current)

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

    echo "${line_match}${listen_match}meta l4proto {tcp, udp} th dport $port_expr"
}

collect_port_elements_for_family() {
    local rules_file=$1
    local family=$2
    local line
    local elem
    local output=""
    local sep=""
    local seen="|"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_FAMILY" == "$family" ]] || continue

        if [ "$R_LISTEN_START" = "$R_LISTEN_END" ]; then
            elem="$R_LISTEN_START"
        else
            elem="$R_LISTEN_START-$R_LISTEN_END"
        fi

        [[ "$seen" == *"|$elem|"* ]] && continue
        seen="${seen}${elem}|"
        output="${output}${sep}${elem}"
        sep=", "
    done < "$rules_file"

    echo "$output"
}

render_tracking_table_for_family() {
    local rules_file=$1
    local family=$2
    local table_family
    local addr_keyword
    local addr_type

    rules_file_has_family_in_file "$rules_file" "$family" || return 0

    if [ "$family" = "ipv6" ]; then
        table_family="ip6"
        addr_keyword="ip6"
        addr_type="ipv6_addr"
    else
        table_family="ip"
        addr_keyword="ip"
        addr_type="ipv4_addr"
    fi

    cat <<EOF
table $table_family nftpf_track {
    set observed {
        type $addr_type
        flags dynamic,timeout
        timeout $TRACK_TIMEOUT
        counter
    }

    chain prerouting {
        type filter hook prerouting priority -102; policy accept;
        # NFTPF_TRACK_TIMEOUT=$TRACK_TIMEOUT
EOF
    render_tracking_rules_for_family "$rules_file" "$family" "$addr_keyword"
    cat <<EOF
    }
}

EOF
}

render_tracking_rules_for_family() {
    local rules_file=$1
    local family=$2
    local addr_keyword=$3
    local line
    local match

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_FAMILY" == "$family" ]] || continue
        match=$(build_forward_match_from_current)
        echo "        ct state new $match update @observed { $addr_keyword saddr timeout $TRACK_TIMEOUT }"
    done < "$rules_file"
}

render_tracking_tables() {
    local rules_file=$1

    render_tracking_table_for_family "$rules_file" "ipv4"
    render_tracking_table_for_family "$rules_file" "ipv6"
}

render_access_table_for_family() {
    local rules_file=$1
    local family=$2
    local mode
    local entries
    local table_family
    local addr_keyword
    local addr_type

    mode=$(get_access_mode)
    [[ "$mode" != "off" ]] || return 0

    rules_file_has_family_in_file "$rules_file" "$family" || return 0

    entries=$(format_access_entries_for_family "$family")
    if [ "$mode" = "blacklist" ] && [ -z "$entries" ]; then
        return 0
    fi

    if [ "$family" = "ipv6" ]; then
        table_family="ip6"
        addr_keyword="ip6"
        addr_type="ipv6_addr"
    else
        table_family="ip"
        addr_keyword="ip"
        addr_type="ipv4_addr"
    fi

    cat <<EOF
table $table_family nftpf_access {
EOF
    if [ -n "$entries" ]; then
        cat <<EOF
    set sources {
        type $addr_type
        flags interval
        elements = { $entries }
    }

EOF
    fi

    cat <<EOF
    chain prerouting {
        type filter hook prerouting priority -101; policy accept;
        # NFTPF_ACCESS_MODE=$mode
EOF

    render_access_rules_for_family "$rules_file" "$family" "$mode" "$addr_keyword" "$entries"
    cat <<EOF
    }
}

EOF
}

render_access_rules_for_family() {
    local rules_file=$1
    local family=$2
    local mode=$3
    local addr_keyword=$4
    local entries=$5
    local line
    local match

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_FAMILY" == "$family" ]] || continue
        match=$(build_forward_match_from_current)

        if [ "$mode" = "whitelist" ]; then
            if [ -n "$entries" ]; then
                echo "        $match $addr_keyword saddr != @sources drop"
            else
                echo "        $match drop"
            fi
        else
            echo "        $match $addr_keyword saddr @sources drop"
        fi
    done < "$rules_file"
}

render_access_tables() {
    local rules_file=$1

    render_access_table_for_family "$rules_file" "ipv4"
    render_access_table_for_family "$rules_file" "ipv6"
}

render_route_mark_table() {
    local rules_file=$1
    local line
    local match
    local mark
    local rendered=0

    line_has_managed_rules_in_file "$rules_file" || return 0

    cat <<EOF
table inet nftpf_route {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ct mark != 0 meta mark set ct mark
EOF

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_ROUTE_MODE" == "managed" && -n "$R_LINE_ID" ]] || continue
        find_line_by_id "$R_LINE_ID" || continue
        read_line_fields "$FOUND_LINE"
        [[ "$L_MODE" == "managed" && -n "$L_MARK" ]] || continue

        mark="$L_MARK"
        match=$(build_forward_match_from_current)
        echo "        ct state new $match ct mark set $mark meta mark set $mark"
        rendered=1
    done < "$rules_file"

    cat <<EOF
    }
}

EOF

    [ "$rendered" -eq 1 ]
}

generate_config_from_rules() {
    local rules_file=$1
    local mark_hex

    mark_hex=$(printf '0x%08x' "$IPV6_ROUTE_MARK")

cat <<EOF
#!/usr/sbin/nft -f
# NFTPF_RENDER_VERSION=$CONFIG_RENDER_VERSION

flush ruleset

EOF
    render_tracking_tables "$rules_file"
    render_access_tables "$rules_file"
    render_route_mark_table "$rules_file"
    cat <<EOF
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
        ct direction reply ct status dnat ct mark 0 meta mark set $mark_hex
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
    local access_mode

    ensure_state_dir
    import_existing_rules_from_config

    if [ ! -f "$CONFIG_FILE" ]; then
        write_config_from_rules "$RULES_FILE" || return 1
        CONFIG_AUTO_REBUILT=1
        return 0
    fi

    ipv6_routefix_should_enable && routefix_enabled=1
    access_mode=$(get_access_mode)

    ! grep -q "NFTPF_RENDER_VERSION=$CONFIG_RENDER_VERSION" "$CONFIG_FILE" && needs_rebuild=1
    ! grep -q "IPV4_MARKER_START" "$CONFIG_FILE" && needs_rebuild=1
    ! grep -q "IPV6_MARKER_START" "$CONFIG_FILE" && needs_rebuild=1
    ! grep -q "ct status dnat masquerade" "$CONFIG_FILE" && needs_rebuild=1
    rules_file_has_records && ! grep -q "NFTPF_TRACK_TIMEOUT=$TRACK_TIMEOUT" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 1 ] && ! grep -q "table ip6 nftpf_routefix" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 1 ] && ! grep -q "ct direction reply ct status dnat meta mark set" "$CONFIG_FILE" && needs_rebuild=1
    [ "$routefix_enabled" -eq 0 ] && grep -q "table ip6 nftpf_routefix" "$CONFIG_FILE" && needs_rebuild=1
    [ "$access_mode" != "off" ] && ! grep -q "NFTPF_ACCESS_MODE=$access_mode" "$CONFIG_FILE" && needs_rebuild=1
    [ "$access_mode" = "off" ] && grep -q "NFTPF_ACCESS_MODE=" "$CONFIG_FILE" && needs_rebuild=1

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

    snapshot_observed_sources "before-reload"
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

    create_state_backup "before-rules-change" 1

    if ! write_config_from_rules "$tmp_rules"; then
        rm -f "$tmp_rules"
        return 1
    fi

    mv "$tmp_rules" "$RULES_FILE"

    if apply_config_changes; then
        show_apply_result
        return 0
    else
        echo -e "${YELLOW}规则已保存，但服务未成功应用；修复问题后可使用“重启服务”。${PLAIN}"
        return 1
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

# -----------------------------------------------------------------------------
# Rule workflows
# -----------------------------------------------------------------------------

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
    local line_id=${10:-}
    local route_mode=${11:-none}

    listen_ip=$(normalize_listen_ip "$listen_ip")
    case "$route_mode" in
        none|iifonly|managed) ;;
        *) route_mode="none" ;;
    esac

    if [[ -n "$line_id" ]]; then
        if ! find_line_by_id "$line_id"; then
            echo -e "${RED}错误：入口线路不存在。${PLAIN}"
            return 1
        fi
        read_line_fields "$FOUND_LINE"
        if [ "$route_mode" = "managed" ] && [ "$L_MODE" != "managed" ]; then
            echo -e "${RED}错误：该线路未启用托管回程路由，不能选择托管模式。${PLAIN}"
            return 1
        fi
    else
        route_mode="none"
    fi

    collect_target_family "$target_host" "$listen_ip" "$family_choice" || {
        echo -e "${RED}错误：无法确定规则协议族，请检查监听地址或目标地址。${PLAIN}"
        return 1
    }

    validate_family_compatibility "$CHOSEN_FAMILY" "$listen_ip" "$target_host" || return 1

    if ! resolve_target_for_rule "$target_host" "$CHOSEN_FAMILY"; then
        echo -e "${RED}错误：目标地址解析失败或协议族不匹配。${PLAIN}"
        return 1
    fi

    if rule_conflicts_in_file "$RULES_FILE" "$CHOSEN_FAMILY" "$listen_ip" "$listen_start" "$listen_end" "$id" "$line_id"; then
        echo -e "${RED}错误：该入口线路/监听 IP/端口范围与现有规则冲突。${PLAIN}"
        return 1
    fi

    PREPARED_RECORD=$(join_rule "$id" "$CHOSEN_FAMILY" "$listen_ip" "$listen_start" "$listen_end" "$RESOLVED_TARGET_TYPE" "$target_host" "$RESOLVED_TARGET_IP" "$target_start" "$target_end" "$mode" "tcp_udp" "$line_id" "$route_mode")
}

lines_file_has_records() {
    grep -q '^[^#[:space:]]' "$LINES_FILE" 2>/dev/null
}

list_lines_compact() {
    local line
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_line_fields "$line"
        echo "[$L_ID] $(line_display_from_fields)"
        count=$((count + 1))
    done < "$LINES_FILE"

    [ "$count" -gt 0 ]
}

choose_line_for_rule() {
    local bind_choice
    local line_choice
    local route_choice

    SELECTED_LINE_ID=""
    SELECTED_ROUTE_MODE="none"

    lines_file_has_records || return 0

    read -p "是否绑定入口线路/网卡？[y/N]: " bind_choice
    [[ "$bind_choice" == "y" || "$bind_choice" == "Y" ]] || return 0

    echo -e "${YELLOW}请选择入口线路:${PLAIN}"
    list_lines_compact || return 0
    echo "[0] 不绑定线路"
    read -p "请输入线路 ID: " line_choice
    [[ "$line_choice" == "0" || -z "$line_choice" ]] && return 0

    if ! find_line_by_id "$line_choice"; then
        echo -e "${RED}错误：入口线路不存在。${PLAIN}"
        return 1
    fi

    read_line_fields "$FOUND_LINE"
    SELECTED_LINE_ID="$L_ID"
    SELECTED_ROUTE_MODE="iifonly"

    if [ "$L_MODE" = "managed" ]; then
        echo "[1] 仅绑定入口网卡（推荐）"
        echo "[2] 绑定入口网卡 + 由 nftpf 托管回程路由（高级）"
        read -p "请选择线路处理方式 [1/2] (默认 1): " route_choice
        if [ "$route_choice" = "2" ]; then
            SELECTED_ROUTE_MODE="managed"
        fi
    fi
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
    choose_line_for_rule || { pause_and_return; return; }

    id=$(next_rule_id)
    prepare_rule_record "$id" "single" "$listen_ip" "$listen_port" "$listen_port" "$target_host" "$target_port" "$target_port" "auto" "$SELECTED_LINE_ID" "$SELECTED_ROUTE_MODE" || { pause_and_return; return; }

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
    choose_line_for_rule || { pause_and_return; return; }

    id=$(next_rule_id)
    prepare_rule_record "$id" "$mode" "$listen_ip" "$listen_start" "$listen_end" "$target_host" "$target_start" "$target_end" "auto" "$SELECTED_LINE_ID" "$SELECTED_ROUTE_MODE" || { pause_and_return; return; }

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
    local line_text

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

    line_text=$(line_label_by_id "$R_LINE_ID")
    if [ "$R_ROUTE_MODE" = "managed" ]; then
        line_text="${line_text}+route"
    fi

    echo "[$R_ID] [$R_FAMILY] [$mode_text] [$line_text] $listen_display -> $target_display"
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
    local line_id
    local route_mode
    local change_line

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
    line_id="$R_LINE_ID"
    route_mode="$R_ROUTE_MODE"
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

    if lines_file_has_records; then
        echo -e "当前入口线路: ${GREEN}$(line_label_by_id "$line_id")${PLAIN}"
        read -p "是否修改入口线路/网卡？[y/N]: " change_line
        if [[ "$change_line" == "y" || "$change_line" == "Y" ]]; then
            choose_line_for_rule || { pause_and_return; return; }
            line_id="$SELECTED_LINE_ID"
            route_mode="$SELECTED_ROUTE_MODE"
        fi
    fi

    prepare_rule_record "$id" "$mode" "$listen_ip" "$listen_start" "$listen_end" "$target_host" "$target_start" "$target_end" "$family_default" "$line_id" "$route_mode" || { pause_and_return; return; }

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

# -----------------------------------------------------------------------------
# Line / multi-NIC workflows
# -----------------------------------------------------------------------------

detect_iface_ipv4() {
    ip -o -4 addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1
}

detect_iface_ipv6() {
    ip -o -6 addr show dev "$1" scope global 2>/dev/null | awk '$4 !~ /^fe80:/ {print $4; exit}' | cut -d/ -f1
}

detect_iface_gw4() {
    ip -4 route show default dev "$1" 2>/dev/null | awk '/default/ {print $3; exit}'
}

detect_iface_gw6() {
    ip -6 route show default dev "$1" 2>/dev/null | awk '/default/ {print $3; exit}'
}

next_line_table() {
    echo $((100 + $1))
}

next_line_mark() {
    printf "0x%x" $((0x100 + $1))
}

line_in_use() {
    local line_id=$1
    local line

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"
        [[ "$R_LINE_ID" == "$line_id" ]] && return 0
    done < "$RULES_FILE"

    return 1
}

commit_lines_file() {
    local tmp_lines=$1

    create_state_backup "before-line-change" 1

    if LINES_FILE="$tmp_lines" write_config_from_rules "$RULES_FILE"; then
        mv "$tmp_lines" "$LINES_FILE"
        if apply_config_changes; then
            show_apply_result
            return 0
        fi
        return 1
    fi

    rm -f "$tmp_lines"
    return 1
}

show_lines() {
    echo -e "${YELLOW}当前入口线路:${PLAIN}"
    if ! list_lines_compact; then
        echo -e "${YELLOW}暂无线路。${PLAIN}"
        return 1
    fi
}

pause_and_line_menu() {
    echo ""
    echo -e "${YELLOW}按下任意键返回线路管理...${PLAIN}"
    read -n 1 -s -r
    line_management_menu
}

scan_interfaces() {
    local ifname
    local ipv4
    local ipv6
    local gw4
    local gw6
    local count=0

    echo -e "${YELLOW}=== 当前网卡和地址 ===${PLAIN}"
    while IFS= read -r ifname; do
        [[ -n "$ifname" && "$ifname" != "lo" ]] || continue
        ipv4=$(detect_iface_ipv4 "$ifname")
        ipv6=$(detect_iface_ipv6 "$ifname")
        gw4=$(detect_iface_gw4 "$ifname")
        gw6=$(detect_iface_gw6 "$ifname")
        count=$((count + 1))
        echo "[$count] $ifname"
        echo "    IPv4: $(value_or_none "$ipv4")"
        echo "    IPv6: $(value_or_none "$ipv6")"
        echo "    IPv4 网关: $(value_or_none "$gw4")"
        echo "    IPv6 网关: $(value_or_none "$gw6")"
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)

    [ "$count" -gt 0 ] || echo -e "${YELLOW}没有检测到可用网卡。${PLAIN}"
    pause_and_line_menu
}

validate_line_values() {
    local ifname=$1
    local ipv4=$2
    local ipv6=$3
    local mode=$4
    local mark=$5
    local table4=$6
    local table6=$7
    local gw4=$8
    local gw6=$9

    validate_ifname_value "$ifname" || return 1
    [[ -z "$ipv4" || "$(classify_host "$ipv4")" == "ipv4" ]] || { echo -e "${RED}错误：IPv4 地址无效。${PLAIN}"; return 1; }
    [[ -z "$ipv6" || "$(classify_host "$ipv6")" == "ipv6" ]] || { echo -e "${RED}错误：IPv6 地址无效。${PLAIN}"; return 1; }
    case "$mode" in iifonly|managed) ;; *) echo -e "${RED}错误：线路模式无效。${PLAIN}"; return 1 ;; esac

    if [ "$mode" = "managed" ]; then
        [[ "$mark" =~ ^0x[0-9A-Fa-f]+$|^[0-9]+$ ]] || { echo -e "${RED}错误：fwmark 必须是数字或 0x 十六进制。${PLAIN}"; return 1; }
        [[ -z "$table4" || "$table4" =~ ^[0-9]+$ ]] || { echo -e "${RED}错误：IPv4 路由表 ID 必须是数字。${PLAIN}"; return 1; }
        [[ -z "$table6" || "$table6" =~ ^[0-9]+$ ]] || { echo -e "${RED}错误：IPv6 路由表 ID 必须是数字。${PLAIN}"; return 1; }
        [[ -z "$gw4" || "$(classify_host "$gw4")" == "ipv4" ]] || { echo -e "${RED}错误：IPv4 网关无效。${PLAIN}"; return 1; }
        [[ -z "$gw6" || "$(classify_host "$gw6")" == "ipv6" ]] || { echo -e "${RED}错误：IPv6 网关无效。${PLAIN}"; return 1; }
    fi
}

add_line() {
    local id name ifname ipv4 ipv6 mode_choice tmp_lines confirm
    local mode="iifonly"
    local table4=""
    local table6=""
    local mark=""
    local gw4=""
    local gw6=""

    echo -e "${YELLOW}=== 添加入口线路 ===${PLAIN}"
    read -p "网卡名，例如 eth0/eth2/ens18: " ifname
    validate_ifname_value "$ifname" || { pause_and_line_menu; return; }
    ip link show dev "$ifname" >/dev/null 2>&1 || echo -e "${YELLOW}警告：当前系统没有检测到网卡 $ifname，仍可保存用于迁移或稍后修复。${PLAIN}"

    name=$(read_with_default "线路名称（仅用于显示）" "$ifname")
    ipv4=$(read_with_default "IPv4 地址（可空）" "$(detect_iface_ipv4 "$ifname")")
    ipv6=$(read_with_default "IPv6 地址（可空）" "$(detect_iface_ipv6 "$ifname")")

    echo "[1] 仅入口绑定（推荐，不修改系统路由）"
    echo "[2] 托管回程路由（高级，会写 ip rule / route table）"
    read -p "请选择线路模式 [1/2] (默认 1): " mode_choice
    [ "$mode_choice" = "2" ] && mode="managed"

    id=$(next_line_id)
    if [ "$mode" = "managed" ]; then
        mark=$(read_with_default "fwmark" "$(next_line_mark "$id")")
        table4=$(read_with_default "IPv4 路由表 ID（无 IPv4 可空）" "$(next_line_table "$id")")
        table6=$(read_with_default "IPv6 路由表 ID（无 IPv6 可空）" "$(next_line_table "$id")")
        gw4=$(read_with_default "IPv4 网关（无 IPv4 可空）" "$(detect_iface_gw4 "$ifname")")
        gw6=$(read_with_default "IPv6 网关（无 IPv6 可空）" "$(detect_iface_gw6 "$ifname")")
        echo -e "${YELLOW}警告：托管回程路由会修改系统 ip rule / route table，仅建议多网卡 DIA 机器使用。${PLAIN}"
        read -p "确认启用托管回程路由？[y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            mode="iifonly"; mark=""; table4=""; table6=""; gw4=""; gw6=""
        fi
    fi

    validate_line_values "$ifname" "$ipv4" "$ipv6" "$mode" "$mark" "$table4" "$table6" "$gw4" "$gw6" || { pause_and_line_menu; return; }
    tmp_lines=$(mktemp) || { pause_and_line_menu; return; }
    cat "$LINES_FILE" > "$tmp_lines"
    join_line "$id" "$name" "$ifname" "$ipv4" "$ipv6" "$mode" "$mark" "$table4" "$table6" "$gw4" "$gw6" "1" >> "$tmp_lines"

    commit_lines_file "$tmp_lines" && echo -e "${GREEN}线路已添加：$name / $ifname${PLAIN}"
    pause_and_line_menu
}

edit_line() {
    local id name ifname ipv4 ipv6 mode mark table4 table6 gw4 gw6 tmp_lines line

    show_lines || { pause_and_line_menu; return; }
    read -p "请输入要编辑的线路 ID (0 取消): " id
    [[ "$id" == "0" ]] && { line_management_menu; return; }
    find_line_by_id "$id" || { echo -e "${RED}错误：线路不存在。${PLAIN}"; pause_and_line_menu; return; }
    read_line_fields "$FOUND_LINE"

    name=$(read_with_default "线路名称" "$L_NAME")
    ifname=$(read_with_default "网卡名" "$L_IFNAME")
    ipv4=$(read_with_default "IPv4 地址（可空）" "$L_IPV4")
    ipv6=$(read_with_default "IPv6 地址（可空）" "$L_IPV6")
    mode=$(read_with_default "模式 iifonly/managed" "$L_MODE")
    mark="$L_MARK"; table4="$L_TABLE4"; table6="$L_TABLE6"; gw4="$L_GW4"; gw6="$L_GW6"

    if [ "$mode" = "managed" ]; then
        mark=$(read_with_default "fwmark" "${mark:-$(next_line_mark "$id")}")
        table4=$(read_with_default "IPv4 路由表 ID" "${table4:-$(next_line_table "$id")}")
        table6=$(read_with_default "IPv6 路由表 ID" "${table6:-$(next_line_table "$id")}")
        gw4=$(read_with_default "IPv4 网关（可空）" "$gw4")
        gw6=$(read_with_default "IPv6 网关（可空）" "$gw6")
    else
        mark=""; table4=""; table6=""; gw4=""; gw6=""
    fi

    validate_line_values "$ifname" "$ipv4" "$ipv6" "$mode" "$mark" "$table4" "$table6" "$gw4" "$gw6" || { pause_and_line_menu; return; }
    tmp_lines=$(mktemp) || { pause_and_line_menu; return; }
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && { echo "$line" >> "$tmp_lines"; continue; }
        read_line_fields "$line"
        if [ "$L_ID" = "$id" ]; then
            join_line "$id" "$name" "$ifname" "$ipv4" "$ipv6" "$mode" "$mark" "$table4" "$table6" "$gw4" "$gw6" "1" >> "$tmp_lines"
        else
            echo "$line" >> "$tmp_lines"
        fi
    done < "$LINES_FILE"

    commit_lines_file "$tmp_lines" && echo -e "${GREEN}线路已更新。${PLAIN}"
    pause_and_line_menu
}

delete_line() {
    local id tmp_lines line

    show_lines || { pause_and_line_menu; return; }
    read -p "请输入要删除的线路 ID (0 取消): " id
    [[ "$id" == "0" ]] && { line_management_menu; return; }
    find_line_by_id "$id" || { echo -e "${RED}错误：线路不存在。${PLAIN}"; pause_and_line_menu; return; }
    if line_in_use "$id"; then
        echo -e "${RED}错误：该线路仍被转发规则使用，请先修改或删除相关规则。${PLAIN}"
        pause_and_line_menu
        return
    fi

    tmp_lines=$(mktemp) || { pause_and_line_menu; return; }
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && { echo "$line" >> "$tmp_lines"; continue; }
        read_line_fields "$line"
        [ "$L_ID" = "$id" ] && continue
        echo "$line" >> "$tmp_lines"
    done < "$LINES_FILE"

    commit_lines_file "$tmp_lines" && echo -e "${GREEN}线路已删除。${PLAIN}"
    pause_and_line_menu
}

apply_managed_routes() {
    local line priority applied=0 failed=0

    command -v ip >/dev/null 2>&1 || { echo -e "${RED}错误：未找到 ip 命令。${PLAIN}"; return 1; }
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_line_fields "$line"
        [[ "$L_MODE" == "managed" ]] || continue
        priority=$((10100 + L_ID))
        if [[ -n "$L_MARK" && -n "$L_TABLE4" && -n "$L_GW4" ]]; then
            ip -4 rule del fwmark "$L_MARK" table "$L_TABLE4" priority "$priority" 2>/dev/null || true
            if ip -4 rule add fwmark "$L_MARK" table "$L_TABLE4" priority "$priority" &&
                ip -4 route replace default via "$L_GW4" dev "$L_IFNAME" table "$L_TABLE4"; then
                applied=$((applied + 1))
            else
                failed=$((failed + 1))
            fi
        fi
        if [[ -n "$L_MARK" && -n "$L_TABLE6" && -n "$L_GW6" ]]; then
            ip -6 rule del fwmark "$L_MARK" table "$L_TABLE6" priority "$priority" 2>/dev/null || true
            if ip -6 rule add fwmark "$L_MARK" table "$L_TABLE6" priority "$priority" &&
                ip -6 route replace default via "$L_GW6" dev "$L_IFNAME" table "$L_TABLE6"; then
                applied=$((applied + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done < "$LINES_FILE"

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}错误：$failed 条托管路由应用失败。${PLAIN}"
        return 1
    fi

    if [ "$applied" -eq 0 ]; then
        echo -e "${YELLOW}没有需要应用的托管路由。${PLAIN}"
    else
        echo -e "${GREEN}托管路由已应用/修复。${PLAIN}"
    fi
}

install_route_service() {
    local command_path="$SHORTCUT_PATH"
    local command_arg

    if [ ! -x "$command_path" ]; then
        command_path=$(realpath "$0" 2>/dev/null || echo "$0")
    else
        command_path=$(realpath "$command_path" 2>/dev/null || echo "$command_path")
    fi
    command_arg=$(systemd_quote_arg "$command_path")

cat > "$ROUTE_SERVICE_FILE" <<EOF
[Unit]
Description=nftpf managed policy routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$command_arg --apply-routes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nftpf-route.service >/dev/null 2>&1 || true
}

apply_managed_routes_menu() {
    if apply_managed_routes && command -v systemctl >/dev/null 2>&1; then
        install_route_service
    fi
    pause_and_line_menu
}

line_management_menu() {
    clear
    echo -e "${YELLOW}=== 线路管理（多网卡/多 DIA） ===${PLAIN}"
    echo "说明：普通 VPS 不需要配置线路；多网卡机器可用线路绑定入口网卡。"
    echo "--------------------------------"
    show_lines || true
    echo "--------------------------------"
    echo "1. 扫描网卡和地址"
    echo "2. 添加线路"
    echo "3. 编辑线路"
    echo "4. 删除线路"
    echo "5. 应用/修复托管路由"
    echo "0. 返回主菜单"
    read -p "请输入数字: " choice

    case "$choice" in
        1) scan_interfaces ;;
        2) add_line ;;
        3) edit_line ;;
        4) delete_line ;;
        5) apply_managed_routes_menu ;;
        0) main_menu ;;
        *) echo -e "${RED}请输入正确的数字。${PLAIN}"; sleep 1; line_management_menu ;;
    esac
}

refresh_ddns() {
    local tmp_rules
    local line
    local new_ip
    local changed=0
    local changed_count=0
    local failed=0
    local domain_count=0
    local resolved_count=0
    local old_ip

    tmp_rules=$(mktemp) || return 1

    echo -e "${YELLOW}正在检查 DDNS/域名目标规则...${PLAIN}"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read_rule_fields "$line"

        if [ "$R_TARGET_TYPE" = "domain" ]; then
            domain_count=$((domain_count + 1))
            old_ip="$R_RESOLVED_IP"
            if new_ip=$(resolve_domain "$R_TARGET_HOST" "$R_FAMILY"); then
                resolved_count=$((resolved_count + 1))
                if [[ "$new_ip" != "$old_ip" ]]; then
                    echo -e "[$R_ID] $R_TARGET_HOST: ${YELLOW}$old_ip -> $new_ip${PLAIN}"
                    R_RESOLVED_IP="$new_ip"
                    changed=1
                    changed_count=$((changed_count + 1))
                fi
            else
                echo -e "${YELLOW}警告：$R_TARGET_HOST 解析失败，保留旧地址 $R_RESOLVED_IP。${PLAIN}"
                failed=$((failed + 1))
            fi
        fi

        join_rule "$R_ID" "$R_FAMILY" "$R_LISTEN_IP" "$R_LISTEN_START" "$R_LISTEN_END" "$R_TARGET_TYPE" "$R_TARGET_HOST" "$R_RESOLVED_IP" "$R_TARGET_START" "$R_TARGET_END" "$R_MODE" "$R_PROTOCOL" "$R_LINE_ID" "$R_ROUTE_MODE" >> "$tmp_rules"
    done < "$RULES_FILE"

    if [ "$changed" -eq 0 ]; then
        rm -f "$tmp_rules"
        if [ "$domain_count" -eq 0 ]; then
            echo -e "${YELLOW}没有发现 DDNS/域名目标规则，无需刷新 nftables。${PLAIN}"
        elif [ "$resolved_count" -eq 0 ]; then
            echo -e "${RED}错误：所有 DDNS/域名目标均解析失败；已跳过 nftables 刷新。${PLAIN}"
            return 1
        else
            echo -e "${GREEN}DDNS 检查完成，没有发现解析变化；已跳过 nftables 刷新。${PLAIN}"
        fi
        return 0
    fi

    echo -e "${YELLOW}发现 $changed_count 条 DDNS 变化，正在重新生成并应用 nftables 配置...${PLAIN}"
    if commit_rules_file "$tmp_rules"; then
        echo -e "${GREEN}DDNS 已更新并重新应用配置。${PLAIN}"
        return 0
    fi

    echo -e "${RED}错误：DDNS 已检测到变化，但 nftables 配置应用失败。${PLAIN}"
    return 1
}

refresh_ddns_menu() {
    refresh_ddns
    pause_and_return
}

parse_ddns_interval_seconds() {
    local raw=$1
    local value
    local unit
    local seconds

    raw=$(echo "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    raw=${raw:-5m}

    if [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)(s|sec|secs|second|seconds|秒)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="s"
    elif [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)(m|min|mins|minute|minutes|分钟|分)?$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="m"
    elif [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)(h|hour|hours|小时|时)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="h"
    else
        return 1
    fi

    seconds=$(awk -v value="$value" -v unit="$unit" 'BEGIN {
        if (unit == "s") {
            result = value
        } else if (unit == "h") {
            result = value * 3600
        } else {
            result = value * 60
        }
        printf "%d", result + 0.999999
    }' 2>/dev/null)

    [[ "$seconds" =~ ^[0-9]+$ ]] || return 1
    [ "$seconds" -ge 10 ] || return 1
    [ "$seconds" -le 86400 ] || return 1

    echo "$seconds"
}

format_ddns_interval() {
    local seconds=$1

    if [ $((seconds % 3600)) -eq 0 ]; then
        echo "$((seconds / 3600)) 小时"
    elif [ $((seconds % 60)) -eq 0 ]; then
        echo "$((seconds / 60)) 分钟"
    else
        echo "$seconds 秒"
    fi
}

systemd_quote_arg() {
    printf '"%s"' "$(printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

enable_ddns_auto_refresh() {
    local command_path
    local interval
    local interval_seconds
    local interval_display
    local command_arg
    local exec_command
    local flock_path
    local old_cron_exists=0

    command_path="$SHORTCUT_PATH"
    if [ ! -x "$command_path" ]; then
        command_path=$(realpath "$0" 2>/dev/null || echo "$0")
    else
        command_path=$(realpath "$command_path" 2>/dev/null || echo "$command_path")
    fi

    echo -e "${YELLOW}提示：默认单位 min，如需秒级，示例：10s；也支持 0.5m、5m、1h。${PLAIN}"
    read -p "请输入 DDNS 自动刷新间隔 (10s-24h，默认 5m): " interval
    if ! interval_seconds=$(parse_ddns_interval_seconds "$interval"); then
        echo -e "${RED}错误：刷新间隔格式无效，或超出 10 秒到 24 小时范围。${PLAIN}"
        pause_and_return
        return
    fi
    interval_display=$(format_ddns_interval "$interval_seconds")

    if [[ "${NFT_HELPER_TEST_MODE:-0}" == "1" ]]; then
        echo -e "${GREEN}测试模式：已跳过 systemd timer 写入。${PLAIN}"
        pause_and_return
        return
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}错误：未找到 systemctl，无法启用秒级 DDNS 自动刷新。${PLAIN}"
        pause_and_return
        return
    fi

    command_arg=$(systemd_quote_arg "$command_path")
    if flock_path=$(command -v flock 2>/dev/null); then
        exec_command="$flock_path -n /run/nftpf.lock $command_arg --refresh-ddns"
    else
        echo -e "${YELLOW}警告：未找到 flock，建议安装 util-linux 以避免 DDNS 刷新任务重叠。${PLAIN}"
        exec_command="$command_arg --refresh-ddns"
    fi

    [ -f "$CRON_FILE" ] && old_cron_exists=1

cat > "$DDNS_SERVICE_FILE" <<EOF
[Unit]
Description=nftpf DDNS refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$exec_command
TimeoutStartSec=30s
EOF

cat > "$DDNS_TIMER_FILE" <<EOF
[Unit]
Description=nftpf DDNS auto refresh

[Timer]
OnBootSec=${interval_seconds}s
OnUnitActiveSec=${interval_seconds}s
AccuracySec=1s
Unit=nftpf-ddns.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if systemctl enable --now nftpf-ddns.timer >/dev/null 2>&1; then
        if [ "$old_cron_exists" -eq 1 ]; then
            rm -f "$CRON_FILE"
            echo -e "${GREEN}已迁移到 systemd timer，并已删除旧 cron 自动刷新任务。${PLAIN}"
        fi
        echo -e "${GREEN}已启用 DDNS 自动刷新（每 $interval_display）。${PLAIN}"
    else
        systemctl status nftpf-ddns.timer --no-pager -l 2>/dev/null || true
        echo -e "${RED}错误：DDNS 自动刷新启用失败。${PLAIN}"
    fi
    pause_and_return
}

disable_ddns_auto_refresh() {
    local changed=0

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now nftpf-ddns.timer >/dev/null 2>&1 || true
    fi

    if [ -f "$CRON_FILE" ] || [ -f "$DDNS_SERVICE_FILE" ] || [ -f "$DDNS_TIMER_FILE" ]; then
        rm -f "$CRON_FILE" "$DDNS_SERVICE_FILE" "$DDNS_TIMER_FILE"
        changed=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl reset-failed nftpf-ddns.service nftpf-ddns.timer 2>/dev/null || true
    fi

    if [ "$changed" -eq 1 ]; then
        echo -e "${GREEN}已关闭 DDNS 自动刷新。${PLAIN}"
    else
        echo -e "${YELLOW}DDNS 自动刷新当前未启用。${PLAIN}"
    fi
    pause_and_return
}

# -----------------------------------------------------------------------------
# Service and config management workflows
# -----------------------------------------------------------------------------

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

    local tmp_rules
    tmp_rules=$(mktemp) || { pause_and_return; return; }
    : > "$tmp_rules"

    if commit_rules_file "$tmp_rules"; then
        echo -e "${GREEN}规则已清空。${PLAIN}"
    fi
    pause_and_return
}

# -----------------------------------------------------------------------------
# Access control and observation workflows
# -----------------------------------------------------------------------------

current_access_entries_plain() {
    grep '^entry=' "$ACCESS_FILE" 2>/dev/null | cut -d'|' -f2- | tr '\n' ' '
}

observed_entries_raw_for_family() {
    local family=$1
    local table_family
    local output
    local elements
    local old_ifs
    local entry
    local ip
    local packets
    local bytes
    local expires

    if [ "$family" = "ipv6" ]; then
        table_family="ip6"
    else
        table_family="ip"
    fi

    output=$(nft_run list set "$table_family" nftpf_track observed 2>/dev/null) || return 0
    elements=$(printf '%s\n' "$output" | awk '
        /elements = \{/ {
            capture=1
            sub(/^.*elements = \{[[:space:]]*/, "")
        }
        capture {
            print
        }
        capture && /\}/ {
            exit
        }
    ' | tr '\n' ' ')
    elements=${elements#*elements = \{}
    elements=${elements%\}*}
    [[ -n "$elements" ]] || return 0

    old_ifs=$IFS
    IFS=','
    for entry in $elements; do
        IFS=$old_ifs
        entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$entry" ]] || continue
        ip=$(echo "$entry" | awk '{print $1}')
        [[ -n "$ip" && "$ip" != "elements" ]] || continue
        packets=$(echo "$entry" | grep -oE 'packets [0-9]+' | awk '{print $2}')
        bytes=$(echo "$entry" | grep -oE 'bytes [0-9]+' | awk '{print $2}')
        expires=$(echo "$entry" | grep -oE 'expires [^ ]+' | awk '{print $2}')
        packets=${packets:-0}
        bytes=${bytes:-0}
        expires=${expires:-"-"}
        echo "$packets|$bytes|$family|$ip|$expires"
        IFS=','
    done
    IFS=$old_ifs
}

load_observed_sources() {
    local tmp_observed
    local packets
    local bytes
    local family
    local ip
    local expires

    OBSERVED_COUNT=0
    OBSERVED_IPS=()
    OBSERVED_FAMILIES=()
    OBSERVED_PACKETS=()
    OBSERVED_BYTES=()
    OBSERVED_EXPIRES=()

    tmp_observed=$(mktemp) || return 1
    observed_entries_raw_for_family "ipv4" >> "$tmp_observed"
    observed_entries_raw_for_family "ipv6" >> "$tmp_observed"

    while IFS='|' read -r packets bytes family ip expires; do
        [[ -n "$ip" ]] || continue
        OBSERVED_COUNT=$((OBSERVED_COUNT + 1))
        OBSERVED_IPS[$OBSERVED_COUNT]="$ip"
        OBSERVED_FAMILIES[$OBSERVED_COUNT]="$family"
        OBSERVED_PACKETS[$OBSERVED_COUNT]="$packets"
        OBSERVED_BYTES[$OBSERVED_COUNT]="$bytes"
        OBSERVED_EXPIRES[$OBSERVED_COUNT]="$expires"
    done < <(sort -t'|' -k1,1nr "$tmp_observed")

    rm -f "$tmp_observed"
}

show_observed_sources() {
    local i

    load_observed_sources || return 1
    if [ "$OBSERVED_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}暂无访问记录。访问记录会在有流量命中转发端口后出现。${PLAIN}"
        return 1
    fi

    echo -e "${YELLOW}=== 近期访问记录（运行期，约 $TRACK_TIMEOUT 窗口） ===${PLAIN}"
    echo "序号 | 协议族 | 源 IP | 命中次数 | bytes | 剩余时间"
    echo "--------------------------------"
    for ((i = 1; i <= OBSERVED_COUNT; i++)); do
        echo "$i. ${OBSERVED_FAMILIES[$i]} ${OBSERVED_IPS[$i]} hits=${OBSERVED_PACKETS[$i]} bytes=${OBSERVED_BYTES[$i]} expires=${OBSERVED_EXPIRES[$i]}"
    done
    echo "--------------------------------"
}

snapshot_observed_sources() {
    local reason=${1:-snapshot}
    local timestamp
    local tmp_history
    local packets
    local bytes
    local family
    local ip
    local expires
    local wrote=0

    ensure_state_dir
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    tmp_history=$(mktemp) || return 0

    {
        observed_entries_raw_for_family "ipv4"
        observed_entries_raw_for_family "ipv6"
    } | while IFS='|' read -r packets bytes family ip expires; do
        [[ -n "$ip" ]] || continue
        echo "$timestamp $reason $family $ip packets=${packets:-0} bytes=${bytes:-0} expires=${expires:-"-"}" >> "$tmp_history"
        wrote=1
    done

    if [ -s "$tmp_history" ]; then
        cat "$tmp_history" >> "$ACCESS_HISTORY_FILE"
        tail -n 1000 "$ACCESS_HISTORY_FILE" > "${tmp_history}.tail" && mv "${tmp_history}.tail" "$ACCESS_HISTORY_FILE"
        chmod 600 "$ACCESS_HISTORY_FILE" 2>/dev/null || true
    fi

    rm -f "$tmp_history" "${tmp_history}.tail"
}

show_access_history() {
    ensure_state_dir
    echo -e "${YELLOW}=== 历史访问记录（显示最近 100 行） ===${PLAIN}"
    echo "说明：历史记录是规则重载前保存的快照，不代表当前实时状态；文件只保留最近 1000 行。"
    echo "--------------------------------"
    if [ ! -s "$ACCESS_HISTORY_FILE" ]; then
        echo -e "${YELLOW}暂无历史访问记录。${PLAIN}"
    else
        tail -n 100 "$ACCESS_HISTORY_FILE"
    fi
    echo "--------------------------------"
    pause_and_access_control
}

clear_access_history() {
    local confirm

    ensure_state_dir
    read -p "确认清空历史访问记录？[y/n]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消。${PLAIN}"
        pause_and_access_control
        return
    fi

    : > "$ACCESS_HISTORY_FILE"
    chmod 600 "$ACCESS_HISTORY_FILE" 2>/dev/null || true
    echo -e "${GREEN}历史访问记录已清空。${PLAIN}"
    pause_and_access_control
}

add_entries_to_blacklist() {
    local entries=$1
    local mode
    local existing=""
    local confirm

    mode=$(get_access_mode)
    if [ "$mode" = "whitelist" ]; then
        echo -e "${YELLOW}当前是白名单模式。加入黑名单会切换到黑名单模式，并关闭白名单限制。${PLAIN}"
        read -p "确认切换并加入黑名单？[y/n]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}已取消。${PLAIN}"
            return 1
        fi
    elif [ "$mode" = "blacklist" ]; then
        existing=$(current_access_entries_plain)
    fi

    prepare_access_file "blacklist" "$existing $entries" && commit_access_file "$PREPARED_ACCESS_FILE"
}

ban_observed_sources_menu() {
    local choices
    local choice
    local entries=""

    if ! show_observed_sources; then
        pause_and_access_control
        return
    fi

    read -p "请输入要加入黑名单的序号（多个用空格或英文逗号分隔，0 取消）: " choices
    [[ "$choices" == "0" || -z "$choices" ]] && { access_control_menu; return; }
    choices=${choices//,/ }

    for choice in $choices; do
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$OBSERVED_COUNT" ]; then
            echo -e "${RED}错误：序号 $choice 无效。${PLAIN}"
            pause_and_access_control
            return
        fi
        entries="$entries ${OBSERVED_IPS[$choice]}"
    done

    if add_entries_to_blacklist "$entries"; then
        echo -e "${GREEN}已加入黑名单并应用。${PLAIN}"
    fi
    pause_and_access_control
}

clear_observed_sources() {
    nft_run flush set ip nftpf_track observed >/dev/null 2>&1 || true
    nft_run flush set ip6 nftpf_track observed >/dev/null 2>&1 || true
    echo -e "${GREEN}近期访问记录已清空。${PLAIN}"
    pause_and_access_control
}

show_access_control() {
    local mode
    local count
    local ipv4_entries
    local ipv6_entries

    mode=$(access_mode_label)
    count=$(access_entry_count)
    ipv4_entries=$(format_access_entries_for_family "ipv4")
    ipv6_entries=$(format_access_entries_for_family "ipv6")

    echo -e "当前模式: ${GREEN}$mode${PLAIN}"
    echo -e "名单数量: ${GREEN}$count${PLAIN}"
    if [ -n "$ipv4_entries" ]; then
        echo "IPv4: $ipv4_entries"
    fi
    if [ -n "$ipv6_entries" ]; then
        echo "IPv6: $ipv6_entries"
    fi
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}当前没有配置名单。${PLAIN}"
    fi
}

prepare_access_file() {
    local mode=$1
    local raw_entries=$2
    local tmp_access
    local entry
    local entry_count=0

    case "$mode" in
        off|whitelist|blacklist) ;;
        *)
            echo -e "${RED}错误：访问控制模式无效。${PLAIN}"
            return 1
            ;;
    esac

    tmp_access=$(mktemp) || return 1
    echo "mode=$mode" > "$tmp_access"

    raw_entries=${raw_entries//,/ }
    for entry in $raw_entries; do
        [[ -n "$entry" ]] || continue
        if ! validate_access_entry "$entry"; then
            echo -e "${RED}错误：$entry 不是有效的源 IP/CIDR。名单不支持域名。${PLAIN}"
            rm -f "$tmp_access"
            return 1
        fi

        if ! grep -qxF "entry=$ACCESS_ENTRY_FAMILY|$ACCESS_ENTRY_VALUE" "$tmp_access"; then
            echo "entry=$ACCESS_ENTRY_FAMILY|$ACCESS_ENTRY_VALUE" >> "$tmp_access"
            entry_count=$((entry_count + 1))
        fi
    done

    if [ "$mode" != "off" ] && [ "$entry_count" -eq 0 ]; then
        echo -e "${RED}错误：启用白名单或黑名单时至少需要填写一个源 IP/CIDR。${PLAIN}"
        rm -f "$tmp_access"
        return 1
    fi

    PREPARED_ACCESS_FILE="$tmp_access"
}

access_file_has_family() {
    local access_file=$1
    local family=$2

    grep -q "^entry=$family|" "$access_file" 2>/dev/null
}

confirm_whitelist_family_coverage() {
    local access_file=$1
    local missing=""
    local confirm

    rules_file_has_family "ipv4" && ! access_file_has_family "$access_file" "ipv4" && missing="${missing} IPv4"
    rules_file_has_family "ipv6" && ! access_file_has_family "$access_file" "ipv6" && missing="${missing} IPv6"

    [[ -n "$missing" ]] || return 0

    echo -e "${YELLOW}警告：当前存在${missing} 转发规则，但白名单没有对应协议族的源 IP/CIDR。${PLAIN}"
    echo -e "${YELLOW}启用后，这些协议族的转发流量会被全部阻断。${PLAIN}"
    read -p "确认继续启用白名单？[y/n]: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]]
}

commit_access_file() {
    local tmp_access=$1

    create_state_backup "before-access-change" 1

    if ACCESS_FILE="$tmp_access" write_config_from_rules "$RULES_FILE"; then
        backup_file "$ACCESS_FILE"
        mv "$tmp_access" "$ACCESS_FILE"
        if apply_config_changes; then
            show_apply_result
            return 0
        fi
        return 1
    fi

    rm -f "$tmp_access"
    return 1
}

configure_access_mode() {
    local mode=$1
    local label
    local entries

    if [ "$mode" = "whitelist" ]; then
        label="白名单"
        echo -e "${YELLOW}白名单模式：只有名单内源 IP/CIDR 可以访问本工具托管的转发端口。${PLAIN}"
    else
        label="黑名单"
        echo -e "${YELLOW}黑名单模式：名单内源 IP/CIDR 会被拒绝访问本工具托管的转发端口。${PLAIN}"
    fi

    echo "请输入源 IP/CIDR，多个用空格或英文逗号分隔。"
    echo "示例: 1.2.3.4 203.0.113.0/24 2409:abcd::/48"
    read -p "$label 名单: " entries

    if prepare_access_file "$mode" "$entries"; then
        if [ "$mode" = "whitelist" ] && ! confirm_whitelist_family_coverage "$PREPARED_ACCESS_FILE"; then
            rm -f "$PREPARED_ACCESS_FILE"
            echo -e "${YELLOW}已取消启用白名单。${PLAIN}"
            pause_and_access_control
            return
        fi

        if commit_access_file "$PREPARED_ACCESS_FILE"; then
            echo -e "${GREEN}$label 已启用。${PLAIN}"
        fi
    fi
    pause_and_access_control
}

disable_access_control() {
    if prepare_access_file "off" "" && commit_access_file "$PREPARED_ACCESS_FILE"; then
        echo -e "${GREEN}访问控制已关闭。${PLAIN}"
    fi
    pause_and_access_control
}

access_control_menu() {
    clear
    echo -e "${YELLOW}=== 访问控制（白名单/黑名单） ===${PLAIN}"
    echo "说明：白名单和黑名单二选一，只限制本工具托管的转发端口，不影响 SSH 等其它服务。"
    echo "注意：名单只支持源 IP/CIDR，不支持 DDNS 域名。"
    echo "访问记录是当前规则加载后的运行期记录，规则重载、服务重启或重新生成配置后会清空。"
    echo "--------------------------------"
    show_access_control
    echo "--------------------------------"
    echo "1. 启用白名单模式"
    echo "2. 启用黑名单模式"
    echo "3. 关闭访问控制"
    echo "4. 查看访问记录并加入黑名单"
    echo "5. 清空访问记录"
    echo "6. 查看历史访问记录"
    echo "7. 清空历史访问记录"
    echo "0. 返回主菜单"
    read -p "请输入数字: " choice

    case "$choice" in
        1) configure_access_mode whitelist ;;
        2) configure_access_mode blacklist ;;
        3) disable_access_control ;;
        4) ban_observed_sources_menu ;;
        5) clear_observed_sources ;;
        6) show_access_history ;;
        7) clear_access_history ;;
        0) main_menu ;;
        *) echo -e "${RED}请输入正确的数字。${PLAIN}"; sleep 1; access_control_menu ;;
    esac
}

# -----------------------------------------------------------------------------
# Backup and restore workflows
# -----------------------------------------------------------------------------

list_backups() {
    local count=0
    local file
    local files=()

    ensure_state_dir
    echo -e "${YELLOW}=== 可用备份 ===${PLAIN}"
    mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nftpf-backup-*.tar.gz' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    for file in "${files[@]}"; do
        count=$((count + 1))
        echo "$count. $file"
    done

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}暂无备份。${PLAIN}"
        return 1
    fi
}

validate_backup_archive() {
    local backup_path=$1
    local entry
    local normalized
    local listing

    if ! listing=$(tar -tzf "$backup_path" 2>/dev/null); then
        echo -e "${RED}错误：备份文件不是有效的 tar.gz 归档。${PLAIN}"
        return 1
    fi

    if tar -tvzf "$backup_path" 2>/dev/null | awk '$1 ~ /^[lh]/ { found=1 } END { exit found ? 1 : 0 }'; then
        :
    else
        echo -e "${RED}错误：备份归档包含链接文件，已拒绝导入。${PLAIN}"
        return 1
    fi

    while IFS= read -r entry; do
        normalized=${entry#./}
        normalized=${normalized%/}
        [[ -z "$normalized" ]] && continue

        if [[ "$normalized" == /* || "$normalized" == *".."* ]]; then
            echo -e "${RED}错误：备份归档包含不安全路径：$entry${PLAIN}"
            return 1
        fi

        case "$normalized" in
            rules.db|lines.db|access.conf|access-history.log|nftables.conf|meta.txt) ;;
            *)
                echo -e "${RED}错误：备份归档包含未知文件：$entry${PLAIN}"
                return 1
                ;;
        esac
    done <<< "$listing"
}

restore_backup_path() {
    local backup_path=$1
    local tmp_dir
    local tmp_access

    if [ ! -f "$backup_path" ]; then
        echo -e "${RED}错误：备份文件不存在。${PLAIN}"
        return 1
    fi

    command -v tar >/dev/null 2>&1 || {
        echo -e "${RED}错误：未找到 tar，无法导入备份。${PLAIN}"
        return 1
    }

    validate_backup_archive "$backup_path" || return 1

    tmp_dir=$(mktemp -d) || return 1
    if ! tar -xzf "$backup_path" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        echo -e "${RED}错误：备份解压失败。${PLAIN}"
        return 1
    fi

    if [ ! -f "$tmp_dir/rules.db" ]; then
        rm -rf "$tmp_dir"
        echo -e "${RED}错误：备份中缺少 rules.db。${PLAIN}"
        return 1
    fi

    if [ ! -f "$tmp_dir/access.conf" ]; then
        tmp_access="$tmp_dir/access.conf"
        echo "mode=off" > "$tmp_access"
    fi
    if [ ! -f "$tmp_dir/lines.db" ]; then
        touch "$tmp_dir/lines.db"
    fi

    create_state_backup "before-restore" 1

    if ACCESS_FILE="$tmp_dir/access.conf" LINES_FILE="$tmp_dir/lines.db" write_config_from_rules "$tmp_dir/rules.db"; then
        cp "$tmp_dir/rules.db" "$RULES_FILE"
        cp "$tmp_dir/lines.db" "$LINES_FILE"
        cp "$tmp_dir/access.conf" "$ACCESS_FILE"
        if [ -f "$tmp_dir/access-history.log" ]; then
            cp "$tmp_dir/access-history.log" "$ACCESS_HISTORY_FILE"
            chmod 600 "$ACCESS_HISTORY_FILE" 2>/dev/null || true
        fi
        if apply_config_changes; then
            show_apply_result
            echo -e "${GREEN}备份已导入并应用: $backup_path${PLAIN}"
            rm -rf "$tmp_dir"
            return 0
        fi
    fi

    rm -rf "$tmp_dir"
    return 1
}

restore_latest_backup() {
    local latest="$BACKUP_DIR/latest.tar.gz"

    if [ ! -f "$latest" ]; then
        echo -e "${RED}错误：没有找到最近一次备份。${PLAIN}"
        pause_and_return
        return
    fi

    restore_backup_path "$latest"
    pause_and_return
}

import_backup_menu() {
    local path

    read -p "请输入备份文件路径 (.tar.gz): " path
    [[ -n "$path" ]] || { echo -e "${RED}错误：路径不能为空。${PLAIN}"; pause_and_return; return; }

    restore_backup_path "$path"
    pause_and_return
}

clear_backups_menu() {
    local confirm
    local files=()

    ensure_state_dir
    echo -e "${RED}警告：此操作将删除所有 nftpf 备份文件，删除后不能通过备份菜单回滚。${PLAIN}"
    read -p "确认清空备份？[y/n]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消。${PLAIN}"
        pause_and_return
        return
    fi

    shopt -s nullglob
    files=("$BACKUP_DIR"/nftpf-backup-*.tar.gz "$BACKUP_DIR/latest.tar.gz" "$BACKUP_DIR/latest-auto.tar.gz" "$BACKUP_DIR/latest-manual.tar.gz")
    shopt -u nullglob

    if [ "${#files[@]}" -eq 0 ]; then
        echo -e "${YELLOW}暂无备份可清空。${PLAIN}"
    else
        rm -f -- "${files[@]}"
        echo -e "${GREEN}已清空 ${#files[@]} 个备份文件。${PLAIN}"
    fi

    pause_and_return
}

backup_restore_menu() {
    clear
    echo -e "${YELLOW}=== 备份 / 导入 / 回滚 ===${PLAIN}"
    echo "说明：备份包含规则库、访问控制名单和当前 nftables 配置。"
    echo "每次修改规则或访问控制前，脚本都会自动创建上一次状态备份，方便回滚。"
    echo "--------------------------------"
    echo "1. 创建当前备份"
    echo "2. 导入备份文件"
    echo "3. 回滚到最近一次备份"
    echo "4. 查看备份列表"
    echo "5. 清空备份"
    echo "0. 返回主菜单"
    read -p "请输入数字: " choice

    case "$choice" in
        1) create_state_backup "manual"; pause_and_return ;;
        2) import_backup_menu ;;
        3) restore_latest_backup ;;
        4) list_backups; pause_and_return ;;
        5) clear_backups_menu ;;
        0) main_menu ;;
        *) echo -e "${RED}请输入正确的数字。${PLAIN}"; sleep 1; backup_restore_menu ;;
    esac
}

# -----------------------------------------------------------------------------
# Status and interactive menu
# -----------------------------------------------------------------------------

get_status() {
    local access_mode
    local access_count
    local line_count

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

    access_mode=$(get_access_mode)
    access_count=$(access_entry_count)
    case "$access_mode" in
        whitelist) ACCESS_STATUS="${GREEN}白名单 ($access_count)${PLAIN}" ;;
        blacklist) ACCESS_STATUS="${YELLOW}黑名单 ($access_count)${PLAIN}" ;;
        *) ACCESS_STATUS="${GREEN}关闭${PLAIN}" ;;
    esac

    line_count=$(grep -c '^[^#[:space:]]' "$LINES_FILE" 2>/dev/null || true)
    if [ "$line_count" -gt 0 ]; then
        LINE_STATUS="${GREEN}已配置 ($line_count)${PLAIN}"
    else
        LINE_STATUS="${GREEN}未配置${PLAIN}"
    fi
}

show_rules_overview() {
    echo -e "${YELLOW}当前转发规则:${PLAIN}"
    if ! list_rules_compact; then
        echo -e "${YELLOW}暂无转发规则。${PLAIN}"
    fi
}

main_menu() {
    clear
    get_status
    echo -e "################################################"
    echo -e "#           NFT Port Forwarding Tool           #"
    echo -e "#            NFT端口转发简易化工具             #"
    echo -e "################################################"
    echo -e "Nftables 状态: ${INSTALL_STATUS}"
    echo -e "服务运行 状态: ${RUN_STATUS}"
    echo -e "IP转发   状态: ${FW_STATUS}"
    echo -e "访问控制 状态: ${ACCESS_STATUS}"
    echo -e "入口线路 状态: ${LINE_STATUS}"
    echo -e "${YELLOW}提示: 输入 nftpf 可快速启动本脚本${PLAIN}"
    echo -e "${YELLOW}注意: 本工具生成配置时包含 flush ruleset，会清空当前 nftables 规则集。${PLAIN}"
    echo -e "################################################"
    show_rules_overview
    echo -e "################################################"
    echo -e " 1. 添加端口转发规则"
    echo -e " 2. 添加端口段转发规则"
    echo -e " 3. 快速修改转发规则"
    echo -e " 4. 删除转发规则"
    echo -e " 5. 清空所有规则"
    echo -e " 6. 备份 / 导入 / 回滚"
    echo -e "------------------------------------------------"
    echo -e " 7. 设置开机自启"
    echo -e " 8. 取消开机自启"
    echo -e " 9. 启动服务"
    echo -e "10. 停止服务"
    echo -e "11. 重启服务"
    echo -e "------------------------------------------------"
    echo -e "12. 访问控制（白名单/黑名单）"
    echo -e "13. 刷新 DDNS 规则"
    echo -e "14. 启用 DDNS 自动刷新"
    echo -e "15. 关闭 DDNS 自动刷新"
    echo -e "16. 线路管理（多网卡/多 DIA）"
    echo -e "17. 更新脚本"
    echo -e " 0. 退出脚本"
    echo -e "################################################"
    read -p "请输入数字: " choice

    case "$choice" in
        1) add_single_rule ;;
        2) add_range_rule ;;
        3) quick_edit_rule ;;
        4) delete_rule ;;
        5) clear_config ;;
        6) backup_restore_menu ;;
        7) manage_service enable ;;
        8) manage_service disable ;;
        9) manage_service start ;;
        10) manage_service stop ;;
        11) manage_service restart ;;
        12) access_control_menu ;;
        13) refresh_ddns_menu ;;
        14) enable_ddns_auto_refresh ;;
        15) disable_ddns_auto_refresh ;;
        16) line_management_menu ;;
        17) update_script ;;
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
        --apply-routes)
            check_ddns_runtime || exit 1
            apply_managed_routes
            exit $?
            ;;
        --update)
            NFTPF_CLI_MODE=1
            update_script
            exit $?
            ;;
        --version)
            echo "$NFTPF_VERSION"
            exit 0
            ;;
        --tool-help)
            echo "NFT Port Forwarding Tool"
            echo "Usage:"
            echo "  nftpf                  Open interactive forwarding menu"
            echo "  nftpf --refresh-ddns   Refresh DDNS/domain forwarding targets"
            echo "  nftpf --apply-routes   Apply managed multi-NIC policy routes"
            echo "  nftpf --update         Download and install latest nftpf script"
            echo "  nftpf --version        Show current nftpf version"
            echo "  nftpf --tool-help      Show this help"
            exit 0
            ;;
        --help|-h)
            echo "NFT Port Forwarding Tool"
            echo "Usage:"
            echo "  nftpf                  Open interactive forwarding menu"
            echo "  nftpf --refresh-ddns   Refresh DDNS/domain forwarding targets"
            echo "  nftpf --apply-routes   Apply managed multi-NIC policy routes"
            echo "  nftpf --update         Download and install latest nftpf script"
            echo "  nftpf --version        Show current nftpf version"
            echo "  nftpf --tool-help      Show this help"
            exit 0
            ;;
    esac
}

run_cli "$@"
check_dependencies || exit 1
check_shortcut
main_menu
