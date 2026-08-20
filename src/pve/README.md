# PVE 系統初始化與硬體監控腳本

Proxmox VE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控安裝腳本。

## 檔案結構

| 檔案 | 職責 |
|------|------|
| `pve_config_notes.sh` | 入口腳本：系統初始化與優化 |
| `disk_monitor.sh` | 硬體監控腳本：PVE Summary 繁體中文介面 |
| `系統初始化與優化.md` | 詳細步驟說明 |
| `硬體監控客製化.md` | 監控介面客製化說明 |

**重要**：兩支腳本屬於同一套一鍵安裝流程。`pve_config_notes.sh` 是入口，負責從 GitHub 下載 `/root/disk_monitor.sh` 並呼叫它；`disk_monitor.sh` 是被下載並執行的 Summary 監控腳本。

## 快速開始

### 基本用法

```bash
# 套用全部優化（預設行為）
./pve_config_notes.sh

# 還原第 6 步的介面修改（不還原系統設定）
./pve_config_notes.sh restore

# 強制重新套用第 6 步
./pve_config_notes.sh remod
```

### 進階選項

```bash
# 安裝必要套件後執行 apt full-upgrade
./pve_config_notes.sh --upgrade

# 啟用 Ceph Squid no-subscription repository
./pve_config_notes.sh --ceph

# 同時啟用 Ceph 與完整升級
./pve_config_notes.sh --ceph --upgrade
```

### 內網 NTP 伺服器（選用）

若你的機房有內部 NTP 伺服器，可在執行前設定環境變數：

```bash
INTERNAL_NTP=192.168.0.100 ./pve_config_notes.sh
```

（上方 IP 僅為範例，請換成你自己機房的實際位址）

未設定時僅使用台灣公開時間伺服器（tick/tock.stdtime.gov.tw、tw.pool.ntp.org）。

## 執行步驟

`pve_config_notes.sh` 依序執行以下 6 個步驟：

1. **[1/6] 清理付費源，改用台灣 Debian 鏡像 + PVE no-subscription 源**
   - 移除 PVE / Ceph enterprise source，避免 401 Unauthorized
   - 統一 APT 來源為 TWDS Debian mirror、Debian Security、PVE no-subscription

2. **[2/6] 設定時區 Asia/Taipei 與 Chrony 校時**
   - 時區設為 `Asia/Taipei`
   - 設定 Chrony 使用台灣公開時間伺服器或內部 NTP

3. **[3/6] 安裝 APT Hook，永久移除訂閱到期彈窗**
   - 透過 `/etc/apt/apt.conf.d/no-nag-script` 永久修補 subscription nag

4. **[4/6] 安裝必要套件並更新系統**
   - 安裝監控工具：`chrony`、`lm-sensors`、`smartmontools`、`linux-cpupower`、`nvme-cli`、`hdparm`、`curl`、`wget`、`util-linux`、`jq`
   - 重新安裝 `proxmox-widget-toolkit` 以套用修補
   - 可選 `--upgrade` 執行完整系統升級

5. **[5/6] 設定 Datacenter Tag 樣式**
   - 設定 `tag-style: shape=full,ordering=alphabetical`

6. **[6/6] 下載並套用繁體中文硬體監控介面**
   - 從 GitHub 下載 `disk_monitor.sh` 到 `/root/disk_monitor.sh`
   - 執行 `disk_monitor.sh` 注入繁體中文 CPU/硬碟監控介面

## 版本追蹤與測試要點

### 為什麼有版本號

`pve_config_notes.sh` 與 `disk_monitor.sh` 都有 `SCRIPT_VERSION` 常數，執行時會顯示版本號。這是為了讓測試者能確認：

- 入口腳本是哪一版
- 被下載並執行的 `disk_monitor.sh` 是哪一版
- GitHub 上的修復是否已反映到實體機

### 強制下載邏輯

`pve_config_notes.sh` 在第 6 步會**強制**從 GitHub 下載 `disk_monitor.sh` 並覆寫 `/root/disk_monitor.sh`：

```bash
curl -fsSL "${REPOSITORY_RAW}/disk_monitor.sh" -o "$disk_script"
chmod 0755 "$disk_script"
"$disk_script"
```

這是因為舊邏輯只在檔案不存在時下載，會導致 GitHub 更新後，實體機仍跑舊檔。

### 測試時需驗證

1. `pve_config_notes.sh` 下載 `disk_monitor.sh` 的 URL 正確
2. `/root/disk_monitor.sh` 實際內容是目標版本
3. 執行時顯示的版本號與 GitHub 提交一致

## 近期提交歷史

- `35907b8` — move: 將腳本搬入 `src/pve/`
- `5d1f38a` — fix: 整合 TWDS 來源、清除 enterprise 與重複 APT source
- `201f635` — docs: 顯示優化完成項目與下一步操作指令
- `0e1a750` — fix: 修正一鍵執行時 disk_monitor 的下載路徑
- `ad4c249` — Update pve_config_notes.sh

## 完成後操作

執行完成後，請至瀏覽器按 **Ctrl + F5** 強制重新載入 PVE 節點摘要頁面，即可看到繁體中文硬體監控介面。

## 授權

作者：sungshu 手札筆記本 (https://sungshu.github.io/)
