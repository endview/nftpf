# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

`nftpf` 是一个基于 nftables 的 Linux 端口转发管理工具。它提供交互式菜单，用来更简单地管理 IPv4、IPv6 和 DDNS/domain 目标的 TCP/UDP 转发规则。

## 功能特性

- 添加单端口 TCP+UDP 转发规则。
- 添加端口段转发规则，支持 1:1 映射和偏移映射。
- 支持 IPv4、IPv6、域名/DDNS 目标。
- 写入配置前自动校验 nftables 语法。
- 规则变更后自动启动或重启 nftables 服务，使配置立即生效。
- 启动时自动检测并修复本工具托管的 nftables 配置漂移。
- 支持 DDNS 手动刷新和 cron 自动刷新。
- 支持白名单/黑名单二选一的访问控制，只限制本工具托管的转发端口。
- 记录托管转发端口的近期源 IP 命中次数，用户可手动选择可疑 IP 加入黑名单。
- 支持托管规则和访问控制设置的备份、导入和回滚。
- 针对特殊 IPv6 网络环境，支持 `fd00::1` + policy routing table `100` 的 DNAT 回程路由修复。

## 快速开始

```bash
curl -o nftpf.sh https://raw.githubusercontent.com/endview/nftpf/main/nftpf.sh
chmod +x nftpf.sh
sudo bash nftpf.sh
```

首次运行后，脚本会安装快捷命令：

```bash
nftpf
```

## 重要提示

本工具生成的 nftables 配置包含：

```nft
flush ruleset
```

这意味着应用本工具托管配置时，会重写当前 nftables 规则集。如果你的服务器上还有 Docker、fail2ban、防火墙面板或其他程序也在管理 nftables，请先确认你能接受这个行为后再使用。

## DDNS 刷新

当目标地址是域名时，工具会保存原始域名和当前解析到的 IP。你可以在菜单里手动刷新，也可以启用自动刷新。

自动刷新使用 cron，并包含固定 `PATH` 和 `flock`，避免多个刷新任务重叠执行。

示例 cron：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/nftpf.lock "/usr/local/bin/nftpf" --refresh-ddns >/dev/null 2>&1
```

启用自动刷新时，可以在交互菜单中自定义刷新间隔，默认是 5 分钟。

## 访问控制

交互菜单支持白名单和黑名单模式，两者二选一，只作用于 `nftpf` 托管的转发端口，不影响 SSH 或其它非托管服务。

名单条目只支持源 IP 或 CIDR，例如 `203.0.113.10`、`203.0.113.0/24`、`2409:abcd::/48`。访问控制名单不支持域名。

`nftpf` 还会为托管转发端口维护一个短期访问观察列表，显示近期源 IP 命中次数。你可以手动选择可疑 IP 加入黑名单，避免自动封禁造成误杀。

规则重载前，当前观察列表会保存到 `/etc/nft-port-forward/access-history.log`。历史记录是辅助快照日志，不是实时审计日志，只保留最近 1000 行。

## 备份和回滚

每次修改转发规则或访问控制设置前，`nftpf` 会自动在 `/etc/nft-port-forward/backups` 下创建备份。菜单也提供手动备份、导入备份，以及回滚到上一次自动备份。

## 文件说明

- `nftpf.sh`：主脚本。
- `NFT_Port_Forwarding_Tool_PRD.md`：产品需求和设计说明。

## 环境要求

- Linux with systemd。
- root 权限。
- `bash`。
- `nftables`。
- `iproute2`。
- 可选：`util-linux` 中的 `flock`，用于 DDNS cron 防重叠执行。

## 许可证

本项目使用 MIT License 发布，详情请查看仓库中的 `LICENSE` 文件。
