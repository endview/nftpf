# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

`nftpf` 是一個基於 nftables 的 Linux 連接埠轉發管理工具。它提供互動式選單，用來更簡單地管理 IPv4、IPv6 和 DDNS/domain 目標的 TCP/UDP 轉發規則。

## 功能特色

- 新增單連接埠 TCP+UDP 轉發規則。
- 新增連接埠區段轉發規則，支援 1:1 映射和偏移映射。
- 支援 IPv4、IPv6、網域/DDNS 目標。
- 寫入設定前自動校驗 nftables 語法。
- 規則變更後自動啟動或重新啟動 nftables 服務，使設定立即生效。
- 啟動時自動偵測並修復本工具託管的 nftables 設定漂移。
- 支援 DDNS 手動刷新和 cron 自動刷新。
- 針對特殊 IPv6 網路環境，支援 `fd00::1` + policy routing table `100` 的 DNAT 回程路由修復。

## 快速開始

```bash
curl -o nftpf.sh https://raw.githubusercontent.com/endview/nftpf/main/nftpf.sh
chmod +x nftpf.sh
sudo bash nftpf.sh
```

首次執行後，腳本會安裝快捷命令：

```bash
nftpf
```

## 重要提示

本工具產生的 nftables 設定包含：

```nft
flush ruleset
```

這表示套用本工具託管設定時，會重寫目前 nftables 規則集。如果你的伺服器上還有 Docker、fail2ban、防火牆面板或其他程式也在管理 nftables，請先確認你能接受這個行為後再使用。

## DDNS 刷新

當目標地址是網域時，工具會保存原始網域和目前解析到的 IP。你可以在選單裡手動刷新，也可以啟用自動刷新。

自動刷新使用 cron，並包含固定 `PATH` 和 `flock`，避免多個刷新任務重疊執行。

範例 cron：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/nftpf.lock "/usr/local/bin/nftpf" --refresh-ddns >/dev/null 2>&1
```

啟用自動刷新時，可以在互動式選單中自訂刷新間隔，預設是 5 分鐘。

## 檔案說明

- `nftpf.sh`：主腳本。
- `NFT_Port_Forwarding_Tool_PRD.md`：產品需求和設計說明。

## 環境需求

- Linux with systemd。
- root 權限。
- `bash`。
- `nftables`。
- `iproute2`。
- 選用：`util-linux` 中的 `flock`，用於 DDNS cron 防重疊執行。

## 授權

本專案使用 MIT License 發布，詳情請查看倉庫中的 `LICENSE` 檔案。
