# NFT Port Forwarding Tool

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

`nftpf` 是一個基於 nftables 的 Linux 連接埠轉發管理工具。它提供互動式選單，用來更簡單地管理 IPv4、IPv6 和 DDNS/domain 目標的 TCP/UDP 轉發規則。

## 功能特色

- 新增單連接埠 TCP+UDP 轉發規則。
- 新增連接埠區段轉發規則，支援 1:1 映射和偏移映射。
- 可為每條轉發規則新增、修改或清空備註，並在規則清單中顯示。
- 支援 IPv4、IPv6、網域/DDNS 目標。
- 修改即時規則前驗證完整 nftables 交易。
- 原子替換 `nftpf_*` 託管表，不重新啟動全域 nftables 服務。
- 每次成功套用規則時啟用 nftables 開機自啟，並分別顯示即時規則與開機持久化狀態。
- 可與 iptables-nft、Phantun、Docker、fail2ban 等工具管理的規則共存。
- 啟動時自動偵測並修復本工具託管的 nftables 設定漂移。
- 支援 DDNS 手動刷新和 systemd timer 自動刷新。
- 支援白名單/黑名單二選一的存取控制，只限制本工具託管的轉發連接埠。
- 記錄託管轉發連接埠的近期來源 IP 命中次數，使用者可手動選擇可疑 IP 加入黑名單。
- 支援託管規則和存取控制設定的備份、匯入和回滾。
- 針對特殊 IPv6 網路環境，支援 `fd00::1` + policy routing table `100` 的 DNAT 回程路由修復。
- 支援多網卡/多 DIA 入口線路，可按 `iifname` 綁定入口網卡，並可選託管 `fwmark` + 獨立路由表。
- 支援透過選單 `17. 更新腳本` 或 `nftpf --update` 從 GitHub Release 更新腳本。
- 支援透過選單 `18. 卸載腳本` 卸載，並可選擇是否刪除備份檔案。

## 快速開始

```bash
curl -fL --proto '=https' --tlsv1.2 -o nftpf.sh https://github.com/endview/nftpf/releases/latest/download/nftpf.sh
curl -fL --proto '=https' --tlsv1.2 -o SHA256SUMS https://github.com/endview/nftpf/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
bash -n nftpf.sh
chmod +x nftpf.sh
sudo bash nftpf.sh
```

首次執行後，腳本會安裝快捷命令：

```bash
nftpf
```

互動面板中的 `Nftables 狀態: 已安裝 (v1.0.6)` 顯示的是系統 `nft` 命令（nftables 使用者態工具）的版本，不是 NFTPF 的版本。NFTPF 自身版本會在下一行單獨顯示，也可執行 `nftpf --version` 查看。

## 規則隔離與持久化

從 v0.2.0 開始，產生的設定不再包含 `flush ruleset`。`nftpf` 只管理名稱以 `nftpf_` 開頭的表；套用前會驗證「刪除舊託管表並建立新託管表」的完整交易，驗證通過後一次原子提交，不會清除其它 nftables 或 iptables-nft 表。

從 v0.1.x 升級時，一次性遷移只刪除 `nftpf` 舊版在 `table ip nat` / `table ip6 nat` 中建立的小寫 `prerouting`、`postrouting` 鏈；iptables-nft 使用的大寫 `PREROUTING`、`POSTROUTING` 等鏈會保留。

每次成功套用都會啟用 `nftables.service` 開機自啟。可以執行 `nftpf --apply` 驗證、原子載入並持久化託管規則。如果主機同時執行其它防火牆管理程式，請避免手動重新啟動全域 nftables 服務，因為部分發行版的 service 在重新啟動時會清空整個即時 ruleset。

## DDNS 刷新

當目標地址是網域時，工具會保存原始網域和目前解析到的 IP。你可以在選單裡手動刷新，也可以啟用自動刷新。

自動刷新使用 systemd timer，可以支援 `30s`、`0.5m` 這類一分鐘以下的間隔；服務內包含固定 `PATH`，並優先使用 `flock` 避免多個刷新任務重疊執行。

範例 timer：

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=nftpf-ddns.service
```

啟用自動刷新時，可以在互動式選單中自訂刷新間隔，預設是 5 分鐘；不帶單位的數字仍按分鐘處理。

## 存取控制

互動式選單支援白名單和黑名單模式，兩者二選一，只作用於 `nftpf` 託管的轉發連接埠，不影響 SSH 或其它非託管服務。

名單項目只支援來源 IP 或 CIDR，例如 `203.0.113.10`、`203.0.113.0/24`、`2409:abcd::/48`。存取控制名單不支援網域。

`nftpf` 還會為託管轉發連接埠維護一個短期存取觀察列表，顯示近期來源 IP 命中次數。你可以手動選擇可疑 IP 加入黑名單，避免自動封禁造成誤殺。

規則重載前，目前觀察列表會保存到 `/etc/nft-port-forward/access-history.log`。歷史記錄是輔助快照日誌，不是即時稽核日誌，只保留最近 1000 行。

## 多網卡 / 多 DIA

普通 VPS 不需要設定入口線路。多網卡機器可以在「線路管理」中新增線路，例如 `IX / eth0`、`BGP / eth2`。新增轉發規則時選擇線路後，工具會產生 `iifname "eth0"` 這類入口網卡匹配，避免不同線路的同連接埠規則互相衝突。

線路預設是「僅入口綁定」，不會修改系統路由。進階使用者可以啟用「託管回程路由」，由 `nftpf` 產生 `ct mark` / `meta mark` 規則，並透過 `nftpf --apply-routes` 套用對應的 `ip rule` 和獨立路由表。該模式只建議多網卡 DIA 機器使用。

## 備份和回滾

每次修改轉發規則或存取控制設定前，`nftpf` 會自動在 `/etc/nft-port-forward/backups` 下建立備份。選單也提供手動備份、匯入備份，以及回滾到上一次自動備份。套用失敗時會還原之前的狀態檔、產生設定和服務啟用狀態。

可以執行 `nftpf --self-test` 做無侵入檢查；該命令驗證 Bash 語法和設定渲染約束，不修改系統規則。

## 測試

一般 Linux 主機可以執行快速檢查：

```bash
bash -n nftpf.sh
bash nftpf.sh --self-test
```

整合測試需要 root，以及 `iproute2`、`iptables`、`nftables`。測試會建立隔離網路命名空間，模擬 v0.1.x 規則遷移，並驗證外部 iptables-nft 規則在遷移、重複套用、錯誤交易和清理後仍保持不變；不會修改宿主網路命名空間。

```bash
sudo bash tests/namespace-integration.sh ./nftpf.sh
```

GitHub Actions 會自動執行同一組檢查。

## 腳本更新

可以使用選單 `17. 更新腳本`，也可以執行 `nftpf --update`。更新會從 GitHub Releases 下載最新版 `nftpf.sh`，先校驗腳本標識和 bash 語法，再備份目前腳本為 `.bak.<時間戳>` 後替換。更新腳本不會修改現有轉發規則，也不會重新啟動 nftables。

## 卸載

可以使用選單 `18. 卸載腳本`，也可以執行 `nftpf --uninstall`。卸載流程只刪除 nftpf 託管表，將 nftpf 託管設定重置為空檔案，刪除 DDNS timer/service、舊 cron 任務、多網卡託管回程 service 和 nftpf 建立的 fwmark/ip rule/路由表，刪除狀態檔案，並刪除已安裝腳本和快捷命令。是否刪除備份檔案會單獨詢問，預設 `N` 保留。

卸載不會刪除 `nftables` 套件，也不會關閉系統 IP 轉發 sysctl，因為這些可能被其它服務使用。

## 檔案說明

- `nftpf.sh`：主腳本。
- `tests/namespace-integration.sh`：隔離的遷移與共存回歸測試。
- `.github/workflows/ci.yml`：GitHub Actions 自動校驗流程。
- `CHANGELOG.md`：按版本維護的變更記錄。
- `SECURITY.md`：支援版本和私密漏洞回報說明。
- `NFT_Port_Forwarding_Tool_PRD.md`：產品需求和設計說明。

## 環境需求

- Linux with systemd。
- root 權限。
- `bash`。
- `nftables`。
- `iproute2`。
- Debian/Ubuntu 可自動安裝 nftables；其它 systemd 發行版請先手動安裝。
- 選用：`util-linux` 中的 `flock`，用於 DDNS 刷新防重疊執行。

## 授權

本專案使用 MIT License 發布，詳情請查看倉庫中的 `LICENSE` 檔案。
