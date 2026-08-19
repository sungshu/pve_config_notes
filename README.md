# PVE 台灣化設定手記

Proxmox VE / PBS 虛擬化實戰筆記本：記錄 PVE 系統摸窜、優化、儲存架構、備份與 VMware
遷移評估等各項主題，依系統/主題分類存放文章與對應程式碼。

## 介紹

本專案採用主題式分類，不是单一安裝教學，而是持續積縯的知識庫：PVE 系統本身、
Ceph 儲存、PBS 備份、VMware 遷移評估等，摸到什麼就記錄什麼。

- PVE 版本：9.2.10（Debian 13 Trixie）
- 測試環境：AMD EPYC 雙路平台、NVMe（Dell BOSS-N1）、SAS HBA 直通、PERC H755 硬體 RAID

## 目錄結構

```text
pve_config_notes/
├── pve/        PVE 系統本身：初始化、優化、監控、匆集、虛擬機
├── ceph/       Ceph 儲存架構：RAID 轉直通、OSD 建立、儲存池分層
├── pbs/        Proxmox Backup Server：安裝、ZFS 規劃、備份還原
├── vmware/     VMware 遷移評估：架構对照、POC 清單、驅動轉換
├── storage/    儲存協定：FC SAN、iSCSI、NFS、ZFS
├── src/        对應各主題的腳本與設定檔範例
└── img/        对應各主題的截圖
```

## 系列章節

### PVE 系統
- [系統初始化與優化](pve/系統初始化與優化.md)：軟體源、時區/Chrony、去訂閱彈窗、套件安裝、Tag 樣式
- [硬體監控客製化](pve/硬體監控客製化.md)：Node Summary 繁中化，CPU 溫度/頻率、NVMe/SATA/SAS/RAID 監控

### Ceph 儲存
- [H755 從 RAID 轉 Non-RAID 與 OSD 建立](ceph/H755從RAID轉Non-RAID與OSD建立.md)：拆除硬體 RAID 5、切換 eHBA、建立獨立 OSD

### PBS 備份
- [PBS 安裝與儲存規劃](pbs/PBS安裝與儲存規劃.md)：退役伺服器改裝 PBS、ZFS Special VDEV 規劃

### VMware 遷移
- [VMware 遷移至 PVE 評估](vmware/VMware遷移至PVE評估.md)：架構对照、三大深水區、POC 必測清單

## 文章說明

1. 本專案涵蓋的部分參數（如內網 IP、NTP 位址）需自行依環境調整，文件中出現的 IP
   皮為示例用途，不會寫死任何真實內部網路資訊。
2. 隨著 PVE／PBS 版本迭代，部分操作介面或程式插入點可能改変，執行前請先在測試
   環境驗證。
3. 如需引用，請註明本文出處。

## 作者

**sungshu 手札筆記本**
GitHub: [sungshu.github.io](https://sungshu.github.io/)
