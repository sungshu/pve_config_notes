# PVE 系統初始化與硬體監控腳本

Proxmox VE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控安裝腳本。

## 倉庫結構

```
src/pve/
├── pve_config_notes.sh    # 入口腳本：系統初始化與優化
├── disk_monitor.sh        # 硬體監控腳本：PVE Summary 繁體中文介面
├── 系統初始化與優化.md     # 詳細步驟說明
└── 硬體監控客製化.md       # 監控介面客製化說明
```

## 兩支腳本的分工

| 腳本 | 職責 |
|------|------|
| `pve_config_notes.sh` | PVE 一鍵初始化：APT source、時區、Chrony、工具安裝、PVE UI 設定，並下載與呼叫 `disk_monitor.sh` |
| `disk_monitor.sh` | PVE Summary 頁面的 CPU/溫度與 NVMe、SATA、SAS、RAID SMART 繁體中文顯示 |

**重要**：兩支腳本屬於同一套流程。`pve_config_notes.sh` 是入口，負責從 GitHub 下載 `/root/disk_monitor.sh` 並呼叫它；`disk_monitor.sh` 是被下載並執行的監控腳本。

## pve_config_notes.sh 用法

### 基本用法

```bash
# 套用全部優化
./pve_config_notes.sh

# 還原第 6 步（僅介面，不還原系統設定）
./pve_config_notes.sh restore

# 強制重套第 6 步
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

### 內網 NTP（選用）

```bash
INTERNAL_NTP=192.168.0.100 ./pve_config_notes.sh
```

（上方 IP 僅為範例，請換成你自己機房的實際位址）

未設定時僅使用台灣公開時間伺服器（tick/tock.stdtime.gov.tw、tw.pool.ntp.org）。

### 執行步驟

`pve_config_notes.sh` 依序執行以下 6 個步驟：

1. **[1/6] 清理付費源，改用台灣 Debian 鏡像 + PVE no-subscription 源**
2. **[2/6] 設定時區 Asia/Taipei 與 Chrony 校時**
3. **[3/6] 安裝 APT Hook，永久移除訂閱到期彈窗**
4. **[4/6] 安裝必要套件並更新系統**
5. **[5/6] 設定 Datacenter Tag 樣式**
6. **[6/6] 下載並套用繁體中文硬體監控介面**

詳細說明請見 `系統初始化與優化.md`。

## disk_monitor.sh 用法

### 單獨執行

```bash
chmod +x disk_monitor.sh
./disk_monitor.sh          # 套用修改
./disk_monitor.sh restore  # 還原官方原始檔案
./disk_monitor.sh remod    # 強制重新套用（先還原再套用）
```

### 更新

從 GitHub 下載並覆蓋本地檔案：

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve/disk_monitor.sh -o disk_monitor.sh
chmod +x disk_monitor.sh
```

或覆蓋到 `/root/disk_monitor.sh`：

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
```

### 版本追蹤

`disk_monitor.sh` 有 `SCRIPT_VERSION` 常數，執行時會顯示版本號。測試時需確認：

1. 下載的 URL 正確
2. 檔案實際內容是目標版本
3. 執行時顯示的版本號與 GitHub 提交一致

詳細說明請見 `硬體監控客製化.md`。

## 近期大事件

- 腳本搬入 `src/pve/`
- 整合 TWDS 來源、清除 enterprise 與重複 APT source
- 修正 `disk_monitor.sh` 下載路徑

## 完成後操作

執行完成後，按 **Ctrl + F5** 重新載入 PVE 節點摘要頁面。

## 授權

作者：sungshu 手札筆記本 (https://sungshu.github.io/)
