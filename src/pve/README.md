# PVE 系統初始化與硬體監控腳本

Proxmox VE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控安裝腳本。

## 倉庫結構

```text
src/pve/
├── pve_config_notes.sh    # 入口腳本：系統初始化與優化
├── disk_monitor.sh        # v1.0.52：PVE Summary 繁體中文硬體監控
├── 系統初始化與優化.md
└── 硬體監控客製化.md
```

## disk_monitor.sh v1.0.52

2026-09-01 正式版，基於目前 PVE 實機已確認正常顯示的版本。

### 保留功能

- CPU 即時頻率、平均／最低／最高頻率與 governor
- CPU package `PkgWatt`
- 雙 CPU / 多 CPU 溫度分行
- 網卡溫度自動標示 `網卡1`、`網卡2`……
- NVMe SMART、溫度、健康度、通電時數、讀寫 TB
- SATA / SAS SSD 與 HDD 分類
- MegaRAID Physical Disk 與一般 `/dev/sdX` 自動分流
- SMART 正常／FAIL／未判定狀態
- Node Summary `height: "auto"`，支援大量硬碟
- `/run/disk_monitor_runtime/` 背景資料採集
- `/etc/cron.d/disk_monitor` 每分鐘採集
- PVE 官方檔案版本化備份與 restore
- `install`、`collect`、`restore`、`remod`

### 使用

```bash
chmod +x disk_monitor.sh
./disk_monitor.sh
./disk_monitor.sh collect
./disk_monitor.sh restore
./disk_monitor.sh remod
```

### 從 GitHub 更新

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
```

套用完成後，瀏覽器執行 **Ctrl + F5**。

## pve_config_notes.sh

### 基本用法

```bash
./pve_config_notes.sh
./pve_config_notes.sh restore
./pve_config_notes.sh remod
```

### 進階選項

```bash
./pve_config_notes.sh --upgrade
./pve_config_notes.sh --ceph
./pve_config_notes.sh --ceph --upgrade
```

## 完成後操作

執行完成後，按 **Ctrl + F5** 重新載入 PVE 節點摘要頁面。

## 作者

**sungshu 手札筆記本**
