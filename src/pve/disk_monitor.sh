#!/usr/bin/env bash
# disk_monitor.sh v1.0.6
# PVE Node Summary 繁體中文硬體監控：CPU 溫度/頻率 + NVMe/SATA/SAS/RAID 硬碟偵測
#
# 用法:
#   ./disk_monitor.sh          套用修改
#   ./disk_monitor.sh restore  還原官方原始檔案
#   ./disk_monitor.sh remod    強制重新套用（先還原再套用）
set -Eeuo pipefail

SCRIPT_VERSION="1.0.6"

sNVMEInfo=true
sODisksInfo=true
sRAIDInfo=true
dmode=false

sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap="$sdir/$sname"

np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

echo "disk_monitor.sh v${SCRIPT_VERSION}"
echo "腳本路徑：$sap"

if [[ ${EUID} -ne 0 ]]; then
    echo "請以 root 執行。" >&2
    exit 1
fi

if ! command -v sensors >/dev/null 2>&1 \
    || ! command -v smartctl >/dev/null 2>&1 \
    || ! command -v lsblk >/dev/null 2>&1; then
    echo "安裝必要套件：lm-sensors、smartmontools、linux-cpupower、nvme-cli、hdparm..."
    apt-get update || echo "警告：部分來源更新失敗，將以既有快取繼續安裝。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lm-sensors smartmontools linux-cpupower nvme-cli hdparm util-linux
fi

pvever=$(pveversion | awk -F/ 'NR==1 {print $2}')
echo "PVE 版本號：$pvever"

restore() {
    [[ -e "$np.$pvever.bak" ]] && cp -f "$np.$pvever.bak" "$np"
    [[ -e "$pvejs.$pvever.bak" ]] && cp -f "$pvejs.$pvever.bak" "$pvejs"
    [[ -e "$plibjs.$pvever.bak" ]] && cp -f "$plibjs.$pvever.bak" "$plibjs"
}

fail() {
    local rc=$?
    echo "修改失敗，正在還原備份..."
    restore
    systemctl restart pveproxy 2>/dev/null || true
    echo "還原完成"
    exit "$rc"
}

case "${1:-}" in
    restore)
        restore
        systemctl restart pveproxy
        echo "已還原原始官方檔案"
        echo -e "請重新整理瀏覽器：\033[31mCtrl + F5\033[0m"
        exit 0
        ;;
    remod)
        echo "強制重新套用修改..."
        "$sap" restore >/dev/null 2>&1 || true
        exec "$sap"
        ;;
esac

[[ -f "$np" ]] || { echo "找不到：$np" >&2; exit 1; }
[[ -f "$pvejs" ]] || { echo "找不到：$pvejs" >&2; exit 1; }
[[ -f "$plibjs" ]] || { echo "找不到：$plibjs" >&2; exit 1; }

[[ -e "$np.$pvever.bak" ]] || cp -a "$np" "$np.$pvever.bak"
[[ -e "$pvejs.$pvever.bak" ]] || cp -a "$pvejs" "$pvejs.$pvever.bak"
[[ -e "$plibjs.$pvever.bak" ]] || cp -a "$plibjs" "$plibjs.$pvever.bak"

restore

contentfornp=$(mktemp /tmp/.contentfornp.XXXXXX)
contentforpvejs=$(mktemp /tmp/.contentforpvejs.XXXXXX)

cleanup() {
    rm -f "$contentfornp" "$contentforpvejs"
}

trap cleanup EXIT
trap fail ERR

if [[ -x /usr/sbin/turbostat ]]; then
    modprobe msr 2>/dev/null || true
fi

echo msr > /etc/modules-load.d/turbostat-msr.conf 2>/dev/null || true

cat > "$contentfornp" <<'SUB_EOF_PERL'

#modbyshowtempfreq
$res->{thermalstate} = `sensors -A`;
$res->{cpuFreq} = `
    goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
    minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq

    grep -i "cpu mhz" /proc/cpuinfo
    echo -n 'gov:'
    [ -f $goverf ] && cat $goverf || echo none
    echo -n 'min:'
    [ -f $minf ] && cat $minf || echo none
    echo -n 'max:'
    [ -f $maxf ] && cat $maxf || echo none
    echo -n 'pkgwatt:'
    [ -x /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>/dev/null | tail -n1
`;
SUB_EOF_PERL

cat > "$contentforpvejs" <<'SUB_EOF_JS'
//modbyshowtempfreq
    {
        itemId: 'thermal',
        colspan: 2,
        printBar: false,
        title: gettext('溫度 (\u00B0C)'),
        textField: 'thermalstate',
        renderer: function(value){
            if (!value) return '\u7121\u611f\u6e2c\u5668\u6578\u64da';

            let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
            let c = b.map(function(v){
                let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig);
                if (fandata) return '\u98A8\u6247: ' + fandata.join('; ');

                let nameMatch = v.match(/^[^-]+/);
                if (!nameMatch) return 'null';

                let name = nameMatch[0].toUpperCase();
                let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?\u00B0C)/g);
                if (!temp) return 'null';

                temp = temp.map(x => Number(x).toFixed(0));

                if (/coretemp|k10temp/i.test(name)) {
                    name = 'CPU';
                    temp = temp[0] + (temp.length > 1
                        ? ' ( ' + temp.slice(1).join(' | ') + ' )'
                        : '');
                } else {
                    temp = temp[0];
                }

                let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
                return name + ': ' + temp + '\u00B0C'
                    + (crit ? ' (\u81E8\u754C\u503C: ' + crit[0] + '\u00B0C)' : '');
            });

            c = c.filter(v => v !== 'null');

            let cpuIdx = c.findIndex(v => /CPU/i.test(v));
            if (cpuIdx > 0) c.unshift(c.splice(cpuIdx, 1)[0]);

            return c.join(' | ') || '\u6B63\u5E38';
        }
    },
    {
        itemId: 'cpumhz',
        colspan: 2,
        printBar: false,
        title: gettext('CPU \u904B\u4F5C\u72C0\u614B'),
        textField: 'cpuFreq',
        renderer: function(v){
            if (!v) return '\u7121\u6CD5\u53D6\u5F97\u983B\u7387';

            let m = v.match(/(?<=^cpu[^\d]+)\d+/img);
            let m2 = '';

            if (m) {
                if (m.length > 16) {
                    let freqs = m.map(e => Number((e / 1000).toFixed(2)));
                    let avg = (freqs.reduce((a, b) => a + b, 0) / freqs.length).toFixed(2);
                    let minCur = Math.min(...freqs);
                    let maxCur = Math.max(...freqs);
                    m2 = '\u5E73\u5747: ' + avg + ' GHz (' + minCur + ' ~ ' + maxCur + ' GHz)';
                } else {
                    m2 = m.map(e => (e / 1000).toFixed(1)).join(' | ') + ' GHz';
                }
            }

            let govMatch = v.match(/(?<=^gov:).+/im);
            let gov = govMatch ? govMatch[0].toUpperCase() : 'NONE';

            let wattMatch = v.match(/(?<=^pkgwatt:)[\d.]+$/im);
            let watt = wattMatch
                ? ' | \u529F\u8017: ' + Number(wattMatch[0]).toFixed(1) + ' W'
                : '';

            return m2 + watt + ' | \u8ABF\u901F\u5668\u6A21\u5F0F: ' + gov;
        }
    },
SUB_EOF_JS

#  \u5171\u7528 SMART \u72C0\u614B\u6E32\u67D3\u898F\u5247\u6703\u5BEB\u5165\u5404\u786C\u789F\u5340\u584A\uFF1A
# true  = \u6B63\u5E38\uFF1Bfalse = FAIL\uFF1B\u672A\u63D0\u4F9B\u72C0\u614B = \u7121 SMART \u8CC7\u6599\u3002

echo "\u6B63\u5728\u5075\u6E2C\u7CFB\u7D71 NVMe \u786C\u789F..."
nvi=0

if $sNVMEInfo; then
    for nvme in /dev/nvme*n[0-9]; do
        [[ -b "$nvme" ]] || continue

        cat >> "$contentfornp" <<SUB_NVME_PL
    \$res->{nvme$nvi} = \`smartctl -a -j "$nvme" 2>/dev/null || echo '{}'\`;
SUB_NVME_PL

        cat >> "$contentforpvejs" <<SUB_NVME_JS
        {
            itemId: 'nvme${nvi}0',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe \u786C\u789F ${nvi}'),
            textField: 'nvme${nvi}',
            renderer: function(value){
                try {
                    let v = JSON.parse(value || '{}');
                    let model = v.model_name || '\u672A\u77E5\u578B\u865F';
                    let temp = v.temperature?.current !== undefined
                        ? ' | \u6EAB\u5EA6: ' + v.temperature.current + '\u00B0C'
                        : '';

                    let pot = v.power_on_time?.hours;
                    let poth = v.power_cycle_count;
                    pot = pot !== undefined
                        ? ' | \u901A\u96FB: ' + pot + ' \u5C0F\u6642'
                            + (poth ? ' (\u958B\u95DC\u6A5F: ' + poth + ' \u6B21)' : '')
                        : '';

                    let log = v.nvme_smart_health_information_log;
                    let rw = '';
                    let health = '';

                    if (log) {
                        let read = log.data_units_read
                            ? (log.data_units_read * 512000 / 1000000000000).toFixed(1) + ' TB'
                            : '';
                        let write = log.data_units_written
                            ? (log.data_units_written * 512000 / 1000000000000).toFixed(1) + ' TB'
                            : '';

                        if (read && write) rw = ' | \u8B80\u5BEB: ' + read + ' / ' + write;

                        let pu = log.percentage_used;
                        if (pu !== undefined) health = ' | \u5065\u5EB7\u5EA6: ' + Math.max(0, 100 - pu) + '%';
                    }

                    let passed = v.smart_status?.passed;
                    let smart = passed === true
                        ? ' | SMART: <span style="color:#21ba45;font-weight:bold;">\u6B63\u5E38</span>'
                        : passed === false
                            ? ' | SMART: <span style="color:#db2828;font-weight:bold;">FAIL</span>'
                            : ' | SMART: <span style="color:#f0ad4e;font-weight:bold;">\u7121 SMART \u8CC7\u6599</span>';

                    return model + temp + health + pot + rw + smart;
                } catch(e) {
                    return '<span style="color:#db2828;font-weight:bold;">SMART: FAIL</span>';
                }
            }
        },
SUB_NVME_JS

        ((++nvi))
    done
fi

echo "\u5DF2\u52A0\u5165 $nvi \u9846 NVMe \u786C\u789F"

# \u9810\u5148\u6383\u63CF RAID \u5BE6\u9AD4\u789F\u3002\u82E5\u627E\u5230 MegaRAID\uFF0C/dev/sd? \u662F\u5176\u6620\u5C04\u88DD\u7F6E\uFF0C
# \u4E0D\u61C9\u518D\u4EE5 SATA/SAS \u4E00\u822C\u6A21\u5F0F\u52A0\u5165\uFF0C\u5426\u5247\u6703\u8207 RAID \u5BE6\u9AD4\u789F\u91CD\u8907\u3002
mapfile -t raidlines < <(
    smartctl --scan-open 2>/dev/null |
    sed -n -E 's#^(/dev/[a-zA-Z0-9/]+) -d megaraid,([0-9]+).*#\1 \2#p'
)

echo "\u6B63\u5728\u5075\u6E2C SATA / SAS SSD \u8207 HDD..."
sdi=0

if $sODisksInfo; then
    if ((${#raidlines[@]} > 0)); then
        echo "\u5075\u6E2C\u5230 MegaRAID\uFF0C\u7565\u904E\u4E00\u822C SATA/SAS \u6383\u63CF\u4EE5\u907F\u514D\u91CD\u8907\u986F\u793A"
    else
        for sd in /dev/sd?; do
            [[ -b "$sd" ]] || continue

            sdsn="${sd##*/}"
            sdcr="/sys/block/$sdsn/queue/rotational"
            [[ -r "$sdcr" ]] || continue

            sdmodel="$(lsblk -dn -o MODEL "$sd" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            if grep -Eqi 'PERC|MegaRAID|RAID' <<<"$sdmodel"; then
                continue
            fi

            sdtran="$(lsblk -dn -o TRAN "$sd" 2>/dev/null | tr -d '[:space:]')"
            srota="$(cat "$sdcr")"

            case "$sdtran" in
                sas)
                    busname="SAS"
                    smartopt="-d scsi"
                    standbycheck=false
                    ;;
                sata|ata)
                    busname="SATA"
                    smartopt=""
                    standbycheck=true
                    ;;
                usb)
                    busname="USB"
                    smartopt=""
                    standbycheck=false
                    ;;
                *)
                    busname=""
                    smartopt="-d scsi"
                    standbycheck=false
                    ;;
            esac

            if [[ -n "$busname" ]]; then
                busprefix="${busname} "
            else
                busprefix=""
            fi

            if [[ "$srota" == "0" ]]; then
                sdtype="${busprefix}\u56FA\u614B\u786C\u789F${sdi}"
            else
                sdtype="${busprefix}\u50B3\u7D71\u786C\u789F${sdi}"
            fi

            cat >> "$contentfornp" <<SUB_SD_PL
    \$res->{sd$sdi} = \`
        if [ -b "$sd" ]; then
            if $standbycheck && hdparm -C "$sd" 2>/dev/null | grep -iq 'standby'; then
                echo '{"standby": true}'
            else
                smartctl $smartopt -a -j "$sd" 2>/dev/null || echo '{}'
            fi
        else
            echo '{}'
        fi
    \`;
SUB_SD_PL

            cat >> "$contentforpvejs" <<SUB_SD_JS
        {
            itemId: 'sd${sdi}0',
            colspan: 2,
            printBar: false,
            title: gettext('${sdtype}'),
            textField: 'sd${sdi}',
            renderer: function(value){
                try {
                    let v = JSON.parse(value || '{}');

                    if (v.standby === true) {
                        return '<span style="color:#888;">\u4F11\u7720\u4E2D (\u7BC0\u80FD\u6A21\u5F0F)</span>';
                    }

                    let model = v.model_name || v.model_family || '\u672A\u77E5\u578B\u865F';
                    let temp = v.temperature?.current !== undefined
                        ? ' | \u6EAB\u5EA6: ' + v.temperature.current + '\u00B0C'
                        : '';

                    let pot = v.power_on_time?.hours;
                    pot = pot !== undefined
                        ? ' | \u901A\u96FB: ' + pot + ' \u5C0F\u6642'
                        : '';

                    let passed = v.smart_status?.passed;
                    let smart = passed === true
                        ? ' | SMART: <span style="color:#21ba45;font-weight:bold;">\u6B63\u5E38</span>'
                        : passed === false
                            ? ' | SMART: <span style="color:#db2828;font-weight:bold;">FAIL</span>'
                            : ' | SMART: <span style="color:#f0ad4e;font-weight:bold;">\u7121 SMART \u8CC7\u6599</span>';

                    return model + temp + pot + smart;
                } catch(e) {
                    return '<span style="color:#db2828;font-weight:bold;">SMART: FAIL</span>';
                }
            }
        },
SUB_SD_JS

            ((++sdi))
        done
    fi
fi

echo "\u5DF2\u52A0\u5165 $sdi \u9846 SATA / SAS \u5BE6\u9AD4\u786C\u789F"

echo "\u6B63\u5728\u5075\u6E2C PERC / MegaRAID \u5BE6\u9AD4\u786C\u789F..."
raidi=0

if $sRAIDInfo; then
    if ((${#raidlines[@]} > 0)); then
        raidcontroller="$(
            lsblk -dn -o MODEL /dev/sd? 2>/dev/null |
            grep -Eim1 'PERC|MegaRAID|RAID' || true
        )"

        [[ -n "$raidcontroller" ]] || raidcontroller="PERC / MegaRAID"

        raidcontroller="$(sed -E \
            's/[[:space:]]+(Front|Rear|Adapter|Mini|Integrated|Mono)[[:space:]]*$//I' \
            <<<"$raidcontroller")"

        for raidline in "${raidlines[@]}"; do
            raidbus="${raidline%% *}"
            raidid="${raidline##* }"

            cat >> "$contentfornp" <<SUB_RAID_PL
    \$res->{raid$raidi} = \`smartctl -a -j -d megaraid,$raidid "$raidbus" 2>/dev/null || echo '{}'\`;
SUB_RAID_PL

            cat >> "$contentforpvejs" <<SUB_RAID_JS
        {
            itemId: 'raid${raidi}0',
            colspan: 2,
            printBar: false,
            title: gettext('RAID \u786C\u789F ${raidi} (${raidcontroller})'),
            textField: 'raid${raidi}',
            renderer: function(value){
                try {
                    let v = JSON.parse(value || '{}');
                    let model = v.model_name || v.model_family || '\u672A\u77E5\u578B\u865F';
                    let temp = v.temperature?.current !== undefined
                        ? ' | \u6EAB\u5EA6: ' + v.temperature.current + '\u00B0C'
                        : '';

                    let pot = v.power_on_time?.hours;
                    pot = pot !== undefined
                        ? ' | \u901A\u96FB: ' + pot + ' \u5C0F\u6642'
                        : '';

                    let passed = v.smart_status?.passed;
                    let smart = passed === true
                        ? ' | SMART: <span style="color:#21ba45;font-weight:bold;">\u6B63\u5E38</span>'
                        : passed === false
                            ? ' | SMART: <span style="color:#db2828;font-weight:bold;">FAIL</span>'
                            : ' | SMART: <span style="color:#f0ad4e;font-weight:bold;">\u7121 SMART \u8CC7\u6599</span>';

                    return model + temp + pot + smart;
                } catch(e) {
                    return '<span style="color:#db2828;font-weight:bold;">SMART: FAIL</span>';
                }
            }
        },
SUB_RAID_JS

            ((++raidi))
        done
    fi
fi

echo "\u5DF2\u52A0\u5165 $raidi \u9846 RAID \u5BE6\u9AD4\u786C\u789F"

echo "\u6B63\u5728\u5957\u7528\u5F8C\u7AEF Perl API \u4FEE\u6539..."
sed -i "/PVE::pvecfg::version_text()/{
    r $contentfornp
}" "$np"

echo "\u6B63\u5728\u5957\u7528\u524D\u7AEF JS \u4ECB\u9762\u4FEE\u6539..."
sed -i "/pveversion/,+3{
    /},/r $contentforpvejs
}" "$pvejs"

addRs=$(grep -c '\$res' "$contentfornp")
addHei=$((32 * addRs + 40))

wph=$(sed -n -E "/widget\.pveNodeStatus/,+8{/height:/{s/[^0-9]*([0-9]+).*/\1/p;q}}" "$pvejs")
if [[ -n "$wph" ]]; then
    sed -i -E \
        "/widget\.pveNodeStatus/,+8{/height:/{s#[0-9]+#$((wph + addHei))#}}" \
        "$pvejs"
fi

nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+12{/minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}}' "$pvejs")
if [[ -n "$nph" ]]; then
    sed -i -E \
        "/nodeStatus:\s*nodeStatus/,+12{/minHeight:/{s#[0-9]+#$((nph + addHei))#}}" \
        "$pvejs"
fi

sed -E -i '/\/nodes\/localhost\/subscription/,+15{
    / if \(/,/Ext\.Msg\.show/{
    H
    /Ext\.Msg\.show/!d
    x
    s/(.* if \().*(\).*)/\1false\2/
    i\//modbyshowtempfreq
    }
}' "$plibjs"

systemctl restart pveproxy

echo "========================================================="
echo "disk_monitor.sh v${SCRIPT_VERSION} \u5957\u7528\u5B8C\u6210"
echo "\u7E41\u9AD4\u4E2D\u6587\u5316\u8207 SATA / SAS / RAID \u786C\u789F\u5075\u6E2C\u5B8C\u6210\uFF01"
echo "SMART \u6B63\u5E38\u70BA\u7DA0\u8272\uFF1B\u660E\u78BA\u7570\u5E38\u70BA\u7D05\u8272 FAIL\uFF1B\u672A\u5831\u544A\u5065\u5EB7\u72C0\u614B\u70BA\u6A58\u8272\u3002"
echo "\u8ACB\u81F3\u700F\u89BD\u5668\u6309 [Ctrl + F5] \u5F37\u5236\u91CD\u65B0\u8F09\u5165 PVE \u7BC0\u9EDE\u6458\u8981\u9801\u9762\u3002"
echo "\u9084\u539F\u8ACB\u57F7\u884C\uFF1A$sap restore"
echo "========================================================="
