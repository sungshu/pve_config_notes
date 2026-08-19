# PBS 安裝與儲存規劃

記錄將退役或轉役的企業級伺服器（如 Dell R730xd、PowerVault NX3230/NX3240）改裝
為專用 Proxmox Backup Server（PBS）備份主機的規劃與注意事項。

## 為什麼 PBS 全用 SSD 可能是「浪費」

在傳統備份系統中，備份池通常由大容量 HDD 組成；但 PBS 的底層是內容定址儲存
（CAS），將所有備份切成平均 2MB～4MB 的 Chunk 檔案，存放在數萬個目錄下的數百萬
個小檔案中。

PBS 有兩大 I/O 密集任務：

1. **垃圾回收（Garbage Collection, GC）**：需遍歷檢查數百萬個 Chunk 檔案的
   Access Time 與引用計數。純 HDD 執行 GC 會引發劇烈隨機尋道，可能讓原本 1
   小時的維護任務拖到 2～3 天；SSD 則可在數十分鐘內完成。
2. **Live-Restore（邊開機邊還原）**：VM 從 PBS 即時開機時，QEMU 會隨機讀取
   Chunk。SSD 底層開機速度與本機磁碟無異；純 HDD 可能嚴重延遲甚至逾時。

若只考慮「長期封存每 TB 成本」，全用企業級 SSD 確實單價較高；但若需要快速備份
窗口、短 RTO、頻繁 GC/Verify，SSD 帶來的維運優勢非常顯著。

## 折衷方案：ZFS Special VDEV

不需要全部用 SSD，也不需要放棄效能，可用 ZFS Special Device 折衷：

```text
PBS 本機 ZFS Pool
 ├── [SSD] ──> 專門存放 Metadata 與小於 128KB 的索引檔（Special VDEV）
 └── [HDD] ──> 存放 4MB 的大型 Chunk 資料本體
```

用少量 SSD 容量解決大部分 GC/IOPS 瓶頸，同時享受 HDD 的大容量。

**重要限制（ZFS 官方文件）**：

- special device 的容錯層級必須和主 pool 一致，因為它是整個 pool 的單點故障
  ——special device 掛了，整個 pool 都會遺失，**必須做 mirror**，不能用單顆 SSD。
- **加入 special device 後無法復原（撤銷）**，這是不可逆操作，下手前務必確認
  規劃正確。
- 加入 special device 不會自動把既有資料的 metadata 搬過去，需要透過 ZFS
  rewrite 或重新寫入資料才能讓舊資料受益。

## 硬體選型：R730xd / NX3230 / NX3240

| 機型世代 | 建議開機硬碟方案 | 原因 |
|---|---|---|
| R730xd / NX3230（13代） | 後置 2.5 吋雙槽（Rear FlexBay）裝 2 顆企業級 SATA SSD 做 RAID 1 | 13 代主機板 UEFI 對 PCIe 轉接 M.2 開機支援較挑剔；背後原生 2.5" 槽位相容性 100% |
| NX3240（14代） | 原廠 Dell BOSS-S1 卡（雙 M.2 SATA SSD 硬體 RAID 1） | 14 代平台原生完整支援，硬體晶片做 RAID 1，獨立於資料磁碟陣列卡之外 |

雙 CPU + 128G～256G RAM 的價值：

- **ZFS ARC 快取**：傳統經驗法則「1TB 儲存配 1GB RAM」，128G～256G RAM 可讓 ZFS
  將幾乎所有備份資料的 Metadata 索引、目錄樹、熱門 Chunk 雜湊表全部鎖在記憶體中，
  大幅消除 HDD 磁頭尋道瓶頸。
- **多執行緒壓縮**：雙 CPU 具備 24～48 執行緒，PBS 使用 zstd 壓縮演算法時可平行
  處理，讓網路頻寬（如 10GbE）跑滿而不卡在 CPU。

## 磁碟陣列卡設定注意事項

- 千萬不要在 RAID 卡內切 12 顆單碟 RAID 0 給 ZFS，需切換為 HBA Mode（Non-RAID），
  讓 Linux Kernel / ZFS 直接辨識每顆硬碟的原始序號與 S.M.A.R.T. 指標。
- 若原本是 RAID 5/6，需先刪除虛擬磁碟再轉為 Non-RAID（做法同 Ceph 篇的 H755
  操作流程）。

## 能否用 Isilon（Dell PowerScale）當 PBS 儲存後端？

技術上可透過 NFS/SMB 掛載，但**強烈不建議**直接將 Isilon 當作 PBS 的主要
Datastore：

| 評估維度 | PBS 本機 ZFS | Isilon（NFS 掛載） |
|---|---|---|
| 檔案元數據延遲 | 微秒級（本地 Direct I/O） | 毫秒級（需跨網路 RPC） |
| 去重效益 | PBS Client 端完成去重與壓縮 | Isilon 收到的是已壓縮的 Hash 檔案，原生去重幾乎無法發揮 |
| POSIX 鎖定與一致性 | 原生 Linux 檔案系統支援 | 依賴 NFS File Lock，網路抖動可能造成寫入中斷 |

PBS 的 GC 與 Verify 需要查詢數百萬個小檔案，NFS 網路延遲會被放大數百萬倍，容易
導致 GC 頻繁 Timeout 失敗。

若要兼顧大容量與效能，建議採用**階層式備份**：

```text
PVE 叢集 ──> PBS（本地 SSD/ZFS Special VDEV，保留 14~30 天，支援 Live-Restore）
         ──> 定時 Sync Job 轉存 ──> Isilon 或第二台冷儲存（長期保留 3~12 個月）
```

## 雙機遠端異地備援架構

```text
PBS-01（本機主要備份機，保留近 30 天還原點）
   │  PBS 原生 Sync Job：以「拉取（Pull）」方式同步 Chunk 資料
   ▼
PBS-02（異地/封存備份機，保留 3~12 個月歷史紀錄）
```

- 免任何額外授權費，PBS 內建 Sync Job。
- PBS-02 只需唯讀存取權限即可拉取資料，即使主機房遭勒索軟體攻擊，異地 PBS-02
  不會被串聯竄改（防勒索 Pull 模式）。

## 注意事項

- 主機規格與線上 PVE 節點一致時，PBS 的運算與 I/O 實力綽綽有餘，重點在儲存架構
  規劃而非運算力。
- 磁碟陣列卡轉換為 Non-RAID／HBA 模式時，務必先確認開機碟（BOSS 卡或獨立
  RAID1）不受影響。
