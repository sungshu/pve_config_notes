# VMware 遷移至 PVE 評估

記錄從 VMware（vSphere / vCenter）評估遷移至 Proxmox VE（PVE）時的架構差異、
潛在落差，以及經銷商進場進行 POC（概念驗證）時的必測項目清單。

## 背景

面對 Broadcom 授權政策調整，許多長期使用 VMware（vCenter、HA、DRS、vSwitch、
vSAN）並搭配 Dell DPS 備份系統的企業，開始評估轉往開源的 PVE。常見的刻板印象是
「PVE 只是開源套件、功能簡陋、沒有集中管理工具」，但 PVE 具備去中心化叢集架構
與原生高可用性，並非單機拼裝軟體；只是底層邏輯（KVM + QEMU + Debian +
Corosync）與 VMware 專利堆疊（ESXi VMkernel + vCenter）有本質差異。

## 架構概念對照

| 功能項目 | VMware vSphere | Proxmox VE | 差異與注意事項 |
|---|---|---|---|
| 管理架構 | vCenter（Master-Agent 集中） | 去中心化叢集（Corosync + pmxcfs） | 任一 Node 登入 Web 即可管全叢集，無單點故障；跨叢集可用 Proxmox Datacenter Manager |
| 高可用性 | vSphere HA（FDM） | PVE HA Manager（Corosync Quorum + Watchdog） | 節點數強烈建議奇數（法定人數）；雙節點必須設 QDevice 仲裁節點避免腦裂 |
| 負載平衡 | VMware DRS（成熟即時調度） | CRS / Dynamic HA Load（或第三方 ProxLB） | 最大落差點：PVE 原生動態負載平衡較基礎，需 API 工具或腳本整合才能接近 DRS 效果 |
| 虛擬網路 | Standard/vDS | Linux Bridge / OVS / SDN | PVE 原生支援 SDN，可建跨節點 VLAN Zones 與 VXLAN，但設定邏輯更接近原生 Linux |
| 備份生態 | Dell DPS / VADP 整合 | Proxmox Backup Server（PBS） | 關鍵痛點：Dell DPS 綁定 VMware API，PVE 上通常退化為 Guest OS 內裝 Agent |

## 三大「深水區」

### 1. 備份系統轉移（Dell DPS 的限制）

Dell DPS（PowerProtect / Avamar / NetWorker）深度依賴 VMware VADP 介面，在 PVE
環境下無法做 Hypervisor-Level 的無代理即時快照備份。

**建議**：評估導入 Proxmox Backup Server（PBS），具備客戶端區塊級去重、增量
快照、加密與 Live-Restore（即時開機還原）。若堅持沿用單一備份平台，需確認現有
系統是否已支援 PVE Hypervisor Connector。

### 2. 網路與叢集仲裁（Corosync 敏感度）

PVE 叢集核心是 Corosync，對網路延遲與封包抖動極為敏感。POC 規劃時必須將
Corosync 流量與儲存/備份/VM 網路物理隔離（或獨立網口/專用 VLAN），否則儲存
流量塞車會導致節點被誤判離線觸發 Fencing 重開機。

### 3. 虛擬機驅動轉換（VMware Tools → VirtIO）

- **Windows VM**：移轉後必須改掛載 VirtIO Driver（SCSI 控制器、網卡、記憶體
  Ballooning）與 QEMU Guest Agent。若未預先安裝驅動直接開機，容易引發 BSOD
  （INACCESSIBLE_BOOT_DEVICE）。
- **Linux VM**：核心通常已內建 VirtIO 模組，但需注意網卡名稱變化（如
  `ens192` 變為 `eth0` 或 `enp0s18`），可能導致網路設定失效。

## 三種儲存架構比較（延用 FC SAN vs 本機 RAID vs 本機 HBA）

| 評估維度 | ① 延用既有 FC SAN | ② 本機實體 RAID 卡 | ③ 本機 HBA 多碟（ZFS/Ceph） |
|---|---|---|---|
| 即時熱移轉 | 極快（僅移轉記憶體狀態） | 慢（需網路同步整顆磁碟） | ZFS 需搬移磁碟；Ceph 極快 |
| HA 故障轉移 | 原生支援 | 無法即時 HA（磁碟鎖在故障節點內） | ZFS 依賴定時複寫（有落差）；Ceph 原生完整支援 |
| 線上 VM 快照 | ⚠️ 原生不支援（Shared LVM 無法做 QEMU 快照） | 支援（LVM-Thin） | 完整支援（ZFS/Ceph 皆為 Copy-on-Write） |

**FC SAN 的關鍵落差**：VMware VMFS 是叢集檔案系統，支援在共享磁區隨時建立 VM
快照；PVE 在共享 LUN 上預設只能用標準 Shared LVM（不支援線上快照）。LVM-Thin
雖支援快照，但不支援跨節點共享。若改用 PBS 備份，因 QEMU 內建 Dirty-Bitmap
機制，即使底層沒有快照功能，依然能做到即時增量備份。

## 經銷商 POC 必備驗證清單

1. **遷移相容性測試**：測試 PVE 內建 ESXi Import Wizard；挑選 Windows Server
   （含 AD/MS-SQL）、舊版 Linux、大型資料磁碟（>2TB）VM 實測轉換時間。
2. **HA 與極端故障演練**：實體斷電拔插頭測試；網路斷線模擬 Split-Brain，驗證
   Quorum 與 Fencing 機制。
3. **儲存架構與效能**：評估沿用 FC/iSCSI SAN 還是改採 Ceph 超融合；確認快照與
   Thin Provisioning 規劃（LVM-Thin、QCOW2 on NFS、或 Ceph RBD）。
4. **備份與 RTO 驗證**：PBS 增量備份速度與去重率；Live-Restore 測試（VM 損毀後
   能否邊開機邊還原）。
5. **企業版授權與維護支援**：正式環境建議購買 Proxmox VE Enterprise
   Subscription，取得穩定的 Enterprise Repository 與原廠技術支援 SLA。

## 評估總結

- **管理體驗**：PVE 介面反應快，但更像「直觀的 Linux 虛擬化平台」，不若
  vCenter 有大量高度包裝的精靈導引，日常維運需對 Linux 基礎指令有一定熟悉度。
- **授權效益**：PVE 以 CPU Socket 計費，沒有 VMware 依 Core 數計算的階梯費用，
  整體 TCO 通常可下降 60%～80% 以上。
- **POC 核心目標**：不要只看「單機開 VM 順不順」，重點應放在「備份鏈路（PBS）
  是否能替代 Dell DPS」與「HA/Quorum 在網路異常時的穩定度」。
