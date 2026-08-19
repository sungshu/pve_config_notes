# H755 從 RAID 轉 Non-RAID 與 OSD 建置

記錄將 Dell PERC H755 硬體 RAID 控制卡從 RAID 模式改為直通（Non-RAID / eHBA），
並在 PVE 上為 Ceph 建立獨立 OSD 的實作過程。

## 背景：為什麼不能讓 Ceph 疊在硬體 RAID 上

Ceph（BlueStore）設計上直接控制底層實體磁碟。若在 PERC H755 上先切 RAID 5 再交給
Ceph 當 OSD，會產生「雙重懲罰」：

```text
VM 寫入請求 ──> Ceph 3 副本 (寫入放大 3x) ──> RAID 5 讀-改-寫懲罰 (4x) ──> 實體磁碟
❌ 寫入懲罰相乘：IOPS 嚴重衰退、延遲飆高
```

同時會造成三個具體問題：

1. **寫入懲罰疊加**：RAID 5 本身的 Write Penalty（約 4 倍）疊加 Ceph 的 3 副本
   放大，小區塊隨機寫入的實體 I/O 會被放大數倍。
2. **雙重重構風暴**：硬碟損壞時，RAID 卡在背景做 Rebuild，Ceph 同時因為 OSD 延遲
   飆高判定節點異常並觸發資料遷移，兩套機制搶佔 I/O。
3. **容量利用率折損**：RAID 5 先扣一顆做同位元，Ceph 再除以 3 副本，可用空間會被
   雙重壓縮。以 4 顆 2.5TB 硬碟為例，RAID 5 + Ceph 約可用 12.5TB；若直接給 Ceph
   20 顆獨立 OSD，可用空間可達 16.6TB。

業界共識（IBM Ceph 官方文件、Ceph 社群）：OSD 磁碟應使用 JBOD/IT 模式的 HBA，
避免使用具 RAID 能力的控制器；若一定要用 RAID 卡，也應只用在開機碟，不要用在
OSD 資料碟上。

## Dell PERC H755 的 eHBA 模式

PERC H755（Broadcom SAS3916 晶片）原生具備 Enhanced HBA（eHBA）模式，不需要更換
硬體卡。在 eHBA 模式下，控制卡的行為與純 HBA（如 HBA355i）等效：完整 SCSI
inquiry 資料、S.M.A.R.T. 直通、無 RAID metadata 或 I/O 抽象層。

## 實作步驟（iDRAC9 介面）

1. **刪除既有 RAID 虛擬磁碟**
   - 進入「存儲 (Storage)」→「虛擬磁盤 (Virtual Disks)」
   - 找到要拆除的 RAID 虛擬磁碟（如 RAID-5, 2233.5 GB），點選「刪除 (Delete)」
   - ⚠️ 千萬不要動到系統開機碟（如 Dell BOSS-N1 的 VD_0, RAID-1）
   - 點選「立即應用 (Apply Now)」提交工作

2. **將實體磁碟轉換為 Non-RAID**

   方式一：物理磁碟清單逐顆轉換
   - 進入「物理磁碟 (Physical Disks)」，找到狀態為「就緒 (Ready)」的硬碟
   - 點選「操作 (Action)」→「轉換為非 RAID (Convert to Non-RAID)」

   方式二：批次全選轉換（推薦，不用一顆一顆點）
   - 進入「配置 (Configuration)」→「存儲配置 (Storage Configuration)」
   - 展開「物理磁碟配置 (Physical Disk Configuration)」
   - 勾選所有「就緒」狀態的硬碟，選擇「轉換為非 RAID」，套用

   方式三：控制器層級「自動配置行為」（最乾淨，未來插新硬碟自動直通）
   - 展開控制器（PERC H755）設定，找到「自動配置行為 (Auto Configuration Behavior)」
   - 「一次性 (One-time)」下拉選單選擇「轉換為非 RAID」
   - 「固定 (Persistent)」可改為「非 RAID」，讓未來插入的新硬碟自動直通

   > 若控制器屬性頁面找不到「非 RAID」選項，請確認是在「自動配置行為」區塊，
   > 而非上方的「控制器屬性」（一致性、回寫模式等）區塊；部分韌體版本僅在
   > 物理磁碟層級開放轉換，無法從控制器層級全域切換。

3. **驗收轉換結果**
   - iDRAC 畫面：轉換完成的硬碟會顯示為 `NonRAID Disk 0`、`NonRAID Disk 1`...，
     寫入策略顯示「直寫 (Write-Through)」，代表已繞過控制器快取，符合 Ceph
     BlueStore 直接 I/O 需求。
   - PVE 介面：進入節點的「磁碟 (Disks)」，會看到獨立的實體硬碟（如
     `/dev/sdb` 至 `/dev/sdf`），不再是單一 RAID 虛擬磁碟。

4. **在 PVE 建立 Ceph OSD**
   - 進入「Ceph」→「OSD」→ 點擊「建立 OSD (Create OSD)」
   - 依序選取每顆獨立磁碟，建立為獨立 OSD（1 碟 1 OSD）

## 儲存池分層（CRUSH Class）

若節點混插 SSD 與 HDD（例如 3.84TB SAS SSD + 1.2TB SAS HDD），務必分開建立
儲存池，不要混在同一個 Pool：

- **SSD Pool**（`device-class=ssd`）：存放線上核心 VM（Windows Server、SQL 等）
- **HDD Pool**（`device-class=hdd`）：存放 Log 伺服器、檔案伺服器、ISO 映像檔

Ceph 預設 `Size=3, Min_Size=2`：5 節點叢集下，1 台節點維護時其餘 4 台仍滿足 3
副本政策；即使再壞第 2 台，只要符合 Min_Size=2，VM 仍可持續讀寫不中斷。

## 網路配置建議

- Ceph 叢集專用網路建議至少 25GbE（或 2x 10GbE LACP）。
- Corosync（叢集心跳）必須與 Ceph 複製流量隔離，綁定獨立網口或給予最高優先級
  VLAN，避免儲存流量塞車時節點被誤判離線觸發 Fencing 重開機。

## 注意事項

- 此操作會清除硬碟上的既有資料，執行前務必確認資料已無需保留或已備份。
- 建議先在測試節點/尚未上線的節點執行，驗證流程無誤後再套用到正式環境的其餘
  節點。
