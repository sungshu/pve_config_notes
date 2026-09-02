# PVE 台灣化設定手記

Proxmox VE / PBS 虛擬化實戰筆記本：記錄 PVE 系統摸索、優化、儲存架構、備份與 VMware 遷移評估等各項主題。

## 介紹

本專案採用主題式分類，持續累積 PVE、Ceph、PBS、VMware 遷移與實戰工具。

- PVE 版本：9.x（Debian 13 Trixie）
- 硬體監控正式版：`disk_monitor.sh v1.0.52`
- 更新日期：2026-09-01

## 目錄結構

```text
pve_config_notes/
├── img/
│   ├── pve/
│   │   ├── ceph/
│   │   ├── pbs/
│   │   └── monitor/
│   └── vmware/
└── src/
    ├── pve/
    │   ├── pve_config_notes.sh
    │   ├── 系統初始化與優化.md
    │   ├── ceph/
    │   ├── pbs/
    │   └── monitor/
    │       ├── disk_monitor.sh
    │       └── 硬體監控客製化.md
    ├── ceph/
    ├── pbs/
    └── vmware/
```

## PVE 系統

- [系統初始化與優化](src/pve/系統初始化與優化.md)
- [硬體監控客製化](src/pve/monitor/硬體監控客製化.md)
- [PVE 腳本與硬體監控說明](src/pve/README.md)

### disk_monitor.sh v1.0.52

正式版包含：

- CPU 狀態、頻率、governor、PkgWatt
- 多 CPU／雙插槽溫度分行
- 網卡溫度自動編號
- NVMe SMART、健康度、溫度、通電與讀寫資訊
- SATA / SAS SSD、HDD 分類
- MegaRAID Physical Disk 自動分流
- SMART 狀態顏色顯示
- Node Summary Auto-Height
- 背景硬體資料採集與 `/run/disk_monitor_runtime/`
- 每分鐘 `/etc/cron.d/disk_monitor`
- `install`、`collect`、`restore`、`remod`

GitHub 更新後可直接下載最新版本：

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve/monitor/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
```

套用完成後請在 PVE Web UI 執行 **Ctrl + F5**。

## Ceph 儲存

- [H755 從 RAID 轉 Non-RAID 與 OSD 建置](src/ceph/H755從RAID轉Non-RAID與OSD建置.md)

## PBS 備份

- [PBS 安裝與儲存規劃](src/pbs/PBS安裝與儲存規劃.md)

## VMware 遷移

- [VMware 遷移至 PVE 評估](src/vmware/VMware遷移至PVE評估.md)

## 注意事項

PVE／PBS 版本更新後，部分 UI 插入點與 API 結構可能改變；正式套用前請在測試節點驗證。

## 作者

**sungshu 手札筆記本**  
GitHub：sungshu.github.io
