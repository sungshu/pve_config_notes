# PVE 系統初始化與硬體監控

Proxmox VE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控專案。

## 倉庫結構

```text
src/pve/
├── pve_config_notes.sh          # 系統初始化與優化入口
├── 系統初始化與優化.md
├── ceph/
├── pbs/
└── monitor/
    ├── disk_monitor.sh          # v1.0.52 PVE 硬體監控
    └── 硬體監控客製化.md

img/pve/
├── ceph/
├── pbs/
└── monitor/                     # PVE 硬體監控實機截圖
```

## disk_monitor.sh v1.0.52

**2026-09-01 正式版，實機測試完成。**

本版本將 CPU、CPU 溫度、網卡溫度、NVMe、SATA/SAS、MegaRAID Physical Disk 等硬體資訊整合到 PVE Node Summary，並使用背景 runtime 採集，避免在 PVE API request 中直接執行完整硬體掃描。

### 主要功能

- CPU 即時頻率、平均／最低／最高頻率與 governor
- CPU package `PkgWatt`
- 多 CPU / 多插槽溫度分行
- 網卡溫度自動整理
- NVMe SMART、溫度、健康度、通電時數、讀寫 TB
- SATA / SAS SSD 與 HDD 分類
- MegaRAID Physical Disk 與一般 `/dev/sdX` 自動分流
- SMART 正常／FAIL／未判定狀態
- Node Summary `height: "auto"`，支援大量硬碟
- `/run/disk_monitor_runtime/` 背景資料採集
- `/etc/cron.d/disk_monitor` 每分鐘採集
- PVE 官方檔案版本化備份與 restore
- `install`、`collect`、`restore`、`remod`

### 從 GitHub 取得正式版

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve/monitor/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
```

### 安裝

```bash
/root/disk_monitor.sh
```

### 背景採集

```bash
/root/disk_monitor.sh collect
```

### 重新套用 UI

```bash
/root/disk_monitor.sh remod
```

### 還原官方 UI

```bash
/root/disk_monitor.sh restore
```

套用完成後，瀏覽器執行 **Ctrl + F5**。

## 實機更新紀錄

本次 v1.0.52 已完成實機驗證，並保留更新前、更新後以及重新部署／驗證的實際畫面。

### 更新前

![Node1 更新前](../../../img/pve/monitor/更新前node1_2026-09-01%20163510.png)

![Node5 更新前](../../../img/pve/monitor/更新前node5_2026-09-01%20163530.png)

### 更新後

![Node1 更新後](../../../img/pve/monitor/更新後node1_2026-09-01%20163103.png)

![Node5 更新後](../../../img/pve/monitor/更新後node5-1%202026-09-01%20163110.png)

![Node5 更新後詳細畫面](../../../img/pve/monitor/更新後node5-2_2026-09-01%20163123.png)

### 實際重新部署／驗證

以下畫面為正式版完成後，實際重新執行 `disk_monitor.sh` 安裝流程所留下的操作紀錄，不是示意圖。

![Node1 實際部署畫面](../../../img/pve/monitor/node1-1_2026-09-02%20085638.png)

![Node1 實際部署畫面 2](../../../img/pve/monitor/node1-2_2026-09-02%20085646.png)

![Node5 實際部署畫面](../../../img/pve/monitor/node5-1_2026-09-02%20085618.png)

![Node5 實際部署畫面 2](../../../img/pve/monitor/node5-2_2026-09-02%20085626.png)

完整的安裝流程、硬體採集架構、PVE API / 前端 Hook、官方檔案備份、PVE 升級後處理與實機驗證說明，請參閱：

**[硬體監控客製化.md](./monitor/硬體監控客製化.md)**

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

執行完成後，按 **Ctrl + F5** 重新載入 PVE 節點摘要頁面，確認 CPU、溫度、NVMe、SATA/SAS 與 RAID Physical Disk 資訊。

## 作者

**sungshu 手札筆記本**
