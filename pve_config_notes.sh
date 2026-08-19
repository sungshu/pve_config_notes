#!/usr/bin/env bash
# pve_config_notes.sh
# PVE 9 (Debian 13 Trixie) 台灣環境主機優化腳本
#
# 完成後會呼叫同目錄下的 disk_monitor.sh，套用繁體中文硬碟監控介面。
#
# 步驟：
#   [1/6] 清理付費源，改用台灣 Debian 鏡像 + PVE no-subscription 源
#   [2/6] 設定時區 Asia/Taipei 與 Chrony 校時
#   [3/6] 安裝 APT Hook，永久移除訂閱到期彈窗
#   [4/6] 安裝必要套件並更新系統
#   [5/6] 設定 Datacenter Tag 樣式
#   [6/6] 呼叫 disk_monitor.sh 注入繁體中文 CPU/硬碟監控介面
#
# 用法:
#   ./pve_config_notes.sh          套用全部優化
#   ./pve_config_notes.sh restore  還原第 6 步的介面修改（不還原系統設定）
#   ./pve_config_notes.sh remod    強制重新套用第 6 步
#
# 內網 NTP 伺服器（選用）：
#   若你的機房有內部 NTP 伺服器，可在執行前設定環境變數，例如：
#     INTERNAL_NTP=172.21.210.50 ./pve_config_notes.sh
#   未設定時僅使用台灣公開時間伺服器（tick/tock.stdtime.gov.tw、tw.pool.ntp.org）。
#
# 作者: sungshu 手札筆記本 (https://sungshu.github.io/)
set -Eeuo pipefail

INTERNAL_NTP="${INTERNAL_NTP:-}"

sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$sdir"

diskscript="$sdir/disk_monitor.sh"

echo "腳本路徑：$sdir/$(basename "${BASH_SOURCE[0]}")"

if [[ ${EUID} -ne 0 ]]; then
    echo "請以 root 執行。" >&2
    exit 1
fi

case "${1:-}" in
    restore|remod)
        if [[ -x "$diskscript" ]]; then
            "$diskscript" "$1"
        else
            echo "找不到 $diskscript，無法還原/重套介面修改。" >&2
            exit 1
        fi
        exit 0
        ;;
esac

echo "=== [1/6] 清理付費源，設定台灣 Debian 13 (Trixie) 與 PVE 9 免費源 ==="
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/pve-enterprise.sources \
      /etc/apt/sources.list.d/pve-install-repo.list \
      /etc/apt/sources.list.d/ceph.list

cat > /etc/apt/sources.list <<'SOURCES'
deb http://ftp.tw.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://ftp.tw.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
SOURCES

echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list

echo "=== [2/6] 設定時區為 Asia/Taipei 與 Chrony 校時 ==="
timedatectl set-timezone Asia/Taipei

NTP_LINES="pool tick.stdtime.gov.tw iburst
pool tock.stdtime.gov.tw iburst
pool tw.pool.ntp.org iburst"
if [[ -n "$INTERNAL_NTP" ]]; then
    NTP_LINES="server ${INTERNAL_NTP} iburst
${NTP_LINES}"
fi

install -d -m 0755 /etc/chrony
cat > /etc/chrony/chrony.conf <<CHRONYCONF
${NTP_LINES}
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
CHRONYCONF

echo "=== [3/6] 設定永久去除訂閱彈窗 Hook ==="
cat > /etc/apt/apt.conf.d/no-nag-script <<'HOOK'
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ $? -eq 1 ]; then { echo 'Patching subscription nag...'; sed -i '/.*data\.status.*active/{s/!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
HOOK

echo "=== [4/6] 更新套件庫並安裝必要監控工具 ==="
apt update || echo "警告：部分來源更新失敗，將以既有快取繼續安裝。"
apt dist-upgrade -y
apt --reinstall install proxmox-widget-toolkit -y
apt install -y chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux

systemctl restart chrony

echo "=== [5/6] 設定 Datacenter Tag 膠囊樣式 ==="
if [[ -f /etc/pve/datacenter.cfg ]]; then
    if grep -q '^tag-style' /etc/pve/datacenter.cfg; then
        sed -i 's/^tag-style:.*/tag-style: shape=full,ordering=alphabetical/' /etc/pve/datacenter.cfg
    else
        echo 'tag-style: shape=full,ordering=alphabetical' >> /etc/pve/datacenter.cfg
    fi
fi

echo "=== [6/6] 呼叫 disk_monitor.sh 注入繁體中文硬碟監控介面 ==="
if [[ -x "$diskscript" ]]; then
    "$diskscript"
else
    echo "警告：找不到可執行的 $diskscript，跳過介面注入。"
    echo "請確認 disk_monitor.sh 與本腳本放在同一目錄，並具備執行權限。"
fi

echo "========================================================="
echo "PVE 台灣化主機優化完成！"
echo "[1/6] APT 來源：台灣 Debian 鏡像 + PVE no-subscription"
echo "[2/6] 時區：Asia/Taipei，Chrony 已設定並啟用"
echo "[3/6] 訂閱到期彈窗：已透過 APT Hook 永久移除"
echo "[4/6] 監控套件：已安裝，系統已更新"
echo "[5/6] Datacenter Tag：膠囊樣式 + 字母排序"
echo "[6/6] 繁體中文化與硬體監控：已呼叫 disk_monitor.sh 注入"
echo "請至瀏覽器按 [Ctrl + F5] 強制重新載入 PVE 節點摘要頁面。"
echo "還原第 6 步請執行：$0 restore"
echo "========================================================="
