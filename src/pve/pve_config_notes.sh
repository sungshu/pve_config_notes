#!/usr/bin/env bash
# pve_config_notes.sh
# PVE 9（Debian 13 Trixie）台灣環境主機優化與硬體監控安裝腳本
#
# 預設行為：
# - 備份並統一 APT 來源為 TWDS Debian mirror、Debian Security、PVE no-subscription。
# - 移除 PVE / Ceph enterprise source，避免 401 Unauthorized。
# - 移除傳統 sources.list 與 debian.sources 重複來源。
# - 安裝必要監控工具，不執行完整系統升級。
# - 自動下載並執行同倉庫的 disk_monitor.sh。
#
# 用法：
#   ./pve_config_notes.sh
#   ./pve_config_notes.sh --upgrade
#   ./pve_config_notes.sh --ceph
#   ./pve_config_notes.sh --ceph --upgrade
#   ./pve_config_notes.sh restore
#   ./pve_config_notes.sh remod
#
# 選用內部 NTP：
#   INTERNAL_NTP=192.168.0.100 ./pve_config_notes.sh
set -Eeuo pipefail

readonly DEBIAN_MIRROR="https://mirror.twds.com.tw/debian"
readonly DEBIAN_SECURITY="https://security.debian.org/debian-security"
readonly PVE_REPOSITORY="http://download.proxmox.com/debian/pve"
readonly CEPH_REPOSITORY="http://download.proxmox.com/debian/ceph-squid"
readonly REPOSITORY_RAW="https://raw.githubusercontent.com/sungshu/pve_config_notes/main/src/pve"
readonly SUITE="trixie"

INTERNAL_NTP="${INTERNAL_NTP:-}"
DO_UPGRADE=0
ENABLE_CEPH=0
ACTION="install"

usage() {
    cat <<'EOF'
用法：
  ./pve_config_notes.sh [--upgrade] [--ceph]
  ./pve_config_notes.sh restore
  ./pve_config_notes.sh remod

選項：
  --upgrade  安裝必要套件後執行 apt full-upgrade
  --ceph     啟用 Ceph Squid no-subscription repository
  restore    還原硬體監控介面修改
  remod      強制重新套用硬體監控介面
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade) DO_UPGRADE=1 ;;
        --ceph) ENABLE_CEPH=1 ;;
        restore|remod) ACTION="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知參數：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -ne 0 ]]; then
    echo "請以 root 執行。" >&2
    exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
disk_script="${script_dir}/disk_monitor.sh"
backup_dir="/root/apt-sources-backup-$(date +%F-%H%M%S)"

if [[ "$ACTION" != "install" ]]; then
    if [[ ! -x "$disk_script" ]]; then
        echo "找不到可執行的 ${disk_script}。" >&2
        exit 1
    fi
    exec "$disk_script" "$ACTION"
fi

echo "腳本路徑：${script_dir}/$(basename "${BASH_SOURCE[0]}")"
echo "=== [1/6] 備份並重建 APT 來源 ==="

mkdir -p "$backup_dir"
[[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$backup_dir/"
[[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$backup_dir/"
echo "APT 設定備份：${backup_dir}"

rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/debian.sources
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/pve-install-repo.list
rm -f /etc/apt/sources.list.d/pve-install-repo.sources
rm -f /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-no-subscription.sources
rm -f /etc/apt/sources.list.d/ceph.list
rm -f /etc/apt/sources.list.d/ceph.sources
rm -f /etc/apt/sources.list.d/ceph-enterprise.list
rm -f /etc/apt/sources.list.d/ceph-enterprise.sources
rm -f /etc/apt/sources.list.d/ceph-no-subscription.list
rm -f /etc/apt/sources.list.d/ceph-no-subscription.sources

cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb deb-src
URIs: ${DEBIAN_MIRROR}
Suites: ${SUITE} ${SUITE}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY}
Suites: ${SUITE}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: ${PVE_REPOSITORY}
Suites: ${SUITE}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

if [[ "$ENABLE_CEPH" -eq 1 ]]; then
    cat > /etc/apt/sources.list.d/ceph-no-subscription.sources <<EOF
Types: deb
URIs: ${CEPH_REPOSITORY}
Suites: ${SUITE}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    echo "Ceph Squid no-subscription source：已啟用"
else
    echo "Ceph source：未啟用（需要 Ceph 時請加 --ceph）"
fi

echo "=== [2/6] 設定時區為 Asia/Taipei 與 Chrony 校時 ==="
timedatectl set-timezone Asia/Taipei

ntp_lines=$'pool tick.stdtime.gov.tw iburst\npool tock.stdtime.gov.tw iburst\npool tw.pool.ntp.org iburst'
if [[ -n "$INTERNAL_NTP" ]]; then
    ntp_lines="server ${INTERNAL_NTP} iburst
${ntp_lines}"
fi

install -d -m 0755 /etc/chrony
cat > /etc/chrony/chrony.conf <<EOF
${ntp_lines}
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF

echo "=== [3/6] 設定訂閱提示修補 Hook ==="
cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\\.js$'; if [ $? -eq 1 ]; then { echo 'Patching subscription nag...'; sed -i '/.*data\\.status.*active/{s/!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
EOF

echo "=== [4/6] 更新套件庫並安裝必要監控工具 ==="
apt update
apt install -y chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux jq
apt --reinstall install -y proxmox-widget-toolkit

if [[ "$DO_UPGRADE" -eq 1 ]]; then
    echo "執行完整系統升級（--upgrade）。"
    apt full-upgrade -y
else
    echo "略過完整系統升級；需要時請明確加上 --upgrade。"
fi

systemctl enable --now chrony

echo "=== [5/6] 設定 Datacenter Tag 膠囊樣式 ==="
if [[ -f /etc/pve/datacenter.cfg ]]; then
    if grep -q '^tag-style' /etc/pve/datacenter.cfg; then
        sed -i 's/^tag-style:.*/tag-style: shape=full,ordering=alphabetical/' /etc/pve/datacenter.cfg
    else
        echo 'tag-style: shape=full,ordering=alphabetical' >> /etc/pve/datacenter.cfg
    fi
fi

echo "=== [6/6] 下載並套用繁體中文硬體監控介面 ==="
if [[ ! -f "$disk_script" ]]; then
    curl -fsSL "${REPOSITORY_RAW}/disk_monitor.sh" -o "$disk_script"
fi
chmod 0755 "$disk_script"
"$disk_script"

echo "========================================================="
echo "PVE 台灣化主機優化完成"
echo "========================================================="
echo "已完成："
echo "  [OK] Debian APT：TWDS mirror"
echo "  [OK] Debian Security：security.debian.org"
echo "  [OK] PVE APT：pve-no-subscription"
echo "  [OK] Enterprise PVE／Ceph source：已清除"
echo "  [OK] APT 重複來源：已清除"
echo "  [OK] 時區：Asia/Taipei"
echo "  [OK] 時間同步：Chrony"
echo "  [OK] 監控工具：lm-sensors、smartmontools、nvme-cli、hdparm"
echo "  [OK] 訂閱提示 Hook：已設定"
echo "  [OK] Datacenter Tag：膠囊樣式＋字母排序"
echo "  [OK] Node Summary：已套用繁體中文 CPU／硬碟監控"
echo
echo "完整系統升級：$([[ "$DO_UPGRADE" -eq 1 ]] && echo 已執行 || echo 尚未執行（預設略過）)"
echo "Ceph Squid source：$([[ "$ENABLE_CEPH" -eq 1 ]] && echo 已啟用 || echo 尚未啟用)"
echo "APT 設定備份：${backup_dir}"
echo
echo "下一步："
echo "  1. 重新登入 PVE Web UI，按 Ctrl+F5 重新載入節點摘要頁面。"
echo "  2. 檢查硬體監控："
echo "     sensors"
echo "     smartctl --scan-open"
echo "     nvme list"
echo
echo "需要完整系統升級時："
echo "  bash <(curl -fsSL ${REPOSITORY_RAW}/pve_config_notes.sh) -- --upgrade"
echo
echo "需要啟用 Ceph Squid no-subscription source 時："
echo "  bash <(curl -fsSL ${REPOSITORY_RAW}/pve_config_notes.sh) -- --ceph"
echo
echo "重新套用硬體監控介面："
echo "  bash <(curl -fsSL ${REPOSITORY_RAW}/pve_config_notes.sh) -- remod"
echo
echo "還原硬體監控介面："
echo "  bash <(curl -fsSL ${REPOSITORY_RAW}/pve_config_notes.sh) -- restore"
echo "========================================================="
