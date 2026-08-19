# PVE 台灣化設定手記

Proxmox VE 折騰手記：PVE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控客製化。

## 介紹

本專案記錄將 PVE 9 調整為適合台灣環境使用的完整流程，涵蓋軟體源修正、時區校時、
訂閱彈窗移除、CPU 調速與 Node Summary 摘要頁面的繁體中文硬體監控（NVMe、SATA、
SAS、PERC/MegaRAID）。

- PVE 版本：9.2.10（Debian 13 Trixie）
- 測試環境：AMD EPYC 雙路平台、NVMe（Dell BOSS-N1）、SAS HBA 直通、PERC H755 硬體 RAID
- 兩支腳本設計：`pve_config_notes.sh` 負責系統層優化，執行完畢後自動呼叫
  `disk_monitor.sh` 完成 Web 介面硬體監控注入；兩支亲可各自獨立執行。

## 開發背景

最初依照社群文章的六步驟教學（軟體源替換、去彈窗、時區校時、CPU 調速等）進行優化，
其中「Web 介面顯示 CPU/硬碟溫度」這一步原本是直接呼叫對岸開源專案
`a904055262/PVE-manager-status` 的 `showtempcpufreq.sh`。

實际使用後發現該腳本不符合需求：

- 沒有 SAS 硬碟與 PERC/MegaRAID 虛擬磁碟的分類邏輯，容易誤判。
- 介面文字為簡體中文。
- 未見明確證据顯示已針對 PVE 9 的 `Nodes.pm`／`pvemanagerlib.js` 新結構做相容性驗證。

因此改為完全自行開發 `disk_monitor.sh`，依照本機實际偵測到的硬碟數量動態產生
對應區塊，並補上 SAS、RAID 虛擬磁碟判斷。開發過程也發現 PVE 9／Debian 13 已將
APT 來源改為 deb822 `.sources` 格式，舊版教學文章中以 `sed` 註釋 `.list` 檔的作法
在新版環境下不再適用，因此腳本改為直接清除舊來源檔案並重新寫入正確格式。

## 系列章節

1. 軟體源修正：清除企業付費源，改用台灣 Debian 鏡像與 PVE 官方 no-subscription 源
2. 時區與時間同步：設定 `Asia/Taipei`，改用 `chrony`（PVE 9 / Debian 13 預設不含
   `systemd-timesyncd`）
3. 移除訂閱到期彈窗：透過 APT `DPkg::Post-Invoke` Hook，套件更新後自動重新修補，
   永久生效
4. 套件安裝與系統更新：`lm-sensors`、`smartmontools`、`linux-cpupower`、`nvme-cli`、
   `hdparm`、`chrony`
5. Datacenter Tag 樣式：設定 `tag-style: shape=full,ordering=alphabetical`
6. Node Summary 硬體監控：繁體中文化 CPU 溫度／頻率／功耗，以及 NVMe、SATA、SAS、
   PERC/MegaRAID 硬碟型號、溫度、通電時數與 SMART 狀態

## 磁碟分類規則

判斷順序固定如下，全部在 `disk_monitor.sh` 執行時即時偵測完成：

| 順序 | 判斷條件 | 分類 | 顯示標籤 |
|---|---|---|---|
| 1 | `smartctl --scan-open` 找到 `megaraid,N` | RAID 硬碟（實體碰） | `RAID 硬碟 N (控制器型號)` |
| 2 | 型號含 PERC/MegaRAID/RAID | 跳過一般判斷 | 由規則 1 涵蓋，避免誤判為傳統硬碟 |
| 3 | `TRAN=sata`，`rotational=0` | SATA SSD | `SATA 固態硬碟N` |
| 4 | `TRAN=sata`，`rotational=1` | SATA HDD | `SATA 傳統硬碟N`（可做 standby 判斷） |
| 5 | `TRAN=sas`，`rotational=0` | SAS SSD | `SAS 固態硬碟N` |
| 6 | `TRAN=sas`，`rotational=1` | SAS HDD | `SAS 傳統硬碟N`（不做 standby 判斷） |

SMART 讀取失敗或狀態異常時，介面會直接顯示紅字 `SMART: FAIL`，不會靜點略過。

## 使用方式

```bash
chmod +x pve_config_notes.sh disk_monitor.sh

# 套用全部優化（系統設定 + 硬碟監控介面）
./pve_config_notes.sh

# 若機房有內部 NTP 伺服器，可指定（IP 僅為範例，請換成實际位址）：
INTERNAL_NTP=192.168.0.100 ./pve_config_notes.sh

# 只還原第 6 步（Node.pm / pvemanagerlib.js / proxmoxlib.js）的介面修改
./pve_config_notes.sh restore

# 強制重新套用介面修改（先還原再套用）
./pve_config_notes.sh remod
```

也可以只執行硬碟監控部分，不動系統設定：

```bash
chmod +x disk_monitor.sh
./disk_monitor.sh
```

執行完成後，請在瀏覽器按 `Ctrl + F5` 強制重新載入 PVE 節點摘要頁面。

## 修改的檔案

- `/usr/share/perl5/PVE/API2/Nodes.pm`
- `/usr/share/pve-manager/js/pvemanagerlib.js`
- `/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`
- `/etc/apt/sources.list`、`/etc/apt/sources.list.d/pve-no-subscription.list`
- `/etc/apt/apt.conf.d/no-nag-script`
- `/etc/chrony/chrony.conf`
- `/etc/pve/datacenter.cfg`

前三項執行前會自動備份為 `<檔名>.<PVE版本>.bak`，執行 `restore` 時會自動還原。
其餘系統設定（軟體源、時區、Chrony、Hook、Tag 樣式）為直接覆寫，不提供自動還原，
如需還原請手動處理对應設定檔。

## 文章說明

1. 本專案涵蓋的部分參數（如內網 NTP 位址）需自行依環境調整，預設僅使用台灣公開
   時間伺服器，不會在程式碼中寫死任何內部網路資訊；文件中出現的 IP 目城为示例用途。
2. 隨著 PVE 版本迭代，`Nodes.pm`／`pvemanagerlib.js` 的插入點字串（如
   `PVE::pvecfg::version_text()`）可能改変，執行前請先在測試節點驗證。
3. PERC/MegaRAID 環境的判斷同時依賴 `smartctl --scan-open` 的裝置對應與型號關鍵字，
   不同控制器與驅動程式差異較大，請以實機輸出核對結果。
4. `turbostat` 的 `PkgWatt` 僅為 CPU 封裝功耗參考值，非整機功耗，整機用電請以
   iDRAC / iLO / Redfish 等 BMC 介面為準。
5. 如需引用，請註明本文出處。

## 作者

**sungshu 手札筆記本**
GitHub: [sungshu.github.io](https://sungshu.github.io/)
