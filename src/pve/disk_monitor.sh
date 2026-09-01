#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="1.0.52"
UPDATED="2026-09-01"
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="/run/disk_monitor.$$"
RUNTIME_DIR="/run/disk_monitor_runtime"
FINAL_JSON="/run/disk_monitor.json"
CRON_FILE="/etc/cron.d/disk_monitor"
NP="/usr/share/perl5/PVE/API2/Nodes.pm"
PVEJS="/usr/share/pve-manager/js/pvemanagerlib.js"
PLIBJS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PVE_VERSION_FULL="$(pveversion 2>/dev/null || true)"
PVE_VER="$(printf '%s\n' "$PVE_VERSION_FULL" | awk -F/ 'NR==1{print $2}')"
[[ -n "$PVE_VER" ]] || PVE_VER="unknown"
BACKUP_DIR="/var/lib/disk_monitor/$PVE_VER"
OFFICIAL_NP="$BACKUP_DIR/Nodes.pm"
OFFICIAL_PVEJS="$BACKUP_DIR/pvemanagerlib.js"
OFFICIAL_PLIBJS="$BACKUP_DIR/proxmoxlib.js"
PVE_JSON="$BASE_DIR/pve.json"
RAID_JSON="$BASE_DIR/raid.json"
RAID_MAP="$BASE_DIR/raid_map.json"
DISKS_JSON="$BASE_DIR/disks.json"
NVME_JSON="$BASE_DIR/nvme.json"
CPU_JSON="$BASE_DIR/cpu.json"
THERMAL_FILE="$BASE_DIR/thermal.txt"
CONTENT_NP="$BASE_DIR/content_nodes.pm"
CONTENT_CPU_JS="$BASE_DIR/content_cpu.js"
CONTENT_DISK_JS="$BASE_DIR/content_disk.js"
cleanup(){ rm -rf "$BASE_DIR"; }
trap cleanup EXIT
log(){ echo "[ $(date '+%Y-%m-%d %H:%M:%S') ] $*" >&2; }
die(){ log "錯誤：$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "找不到必要程式：$1"; }
safe(){ local v="${1:-}"; v="$(printf '%s' "$v" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"; [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' UNKNOWN; }
[[ $EUID -eq 0 ]] || die "請以 root 執行"
for c in jq lsblk smartctl lspci pvesh pveversion perl dpkg-query awk sed timeout; do need "$c"; done
PVE_NODE="$(hostname -s 2>/dev/null || hostname)"
PVE_MANAGER="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || true)"
has_marker(){ grep -qE 'disk_monitor_1\.0\.|diskMonitorNvme|diskMonitorSd|diskMonitorRaid|diskMonitorThermal|diskMonitorData|dm_cpumhz|dm_thermalstate' "$1" 2>/dev/null; }
backup_official(){
 mkdir -p "$BACKUP_DIR"
 if [[ -f "$OFFICIAL_NP" && -f "$OFFICIAL_PVEJS" && -f "$OFFICIAL_PLIBJS" ]]; then
  if has_marker "$OFFICIAL_NP" || has_marker "$OFFICIAL_PVEJS" || has_marker "$OFFICIAL_PLIBJS"; then die "既有 official backup 含 disk_monitor 注入，拒絕使用：$BACKUP_DIR"; fi
  return 0
 fi
 has_marker "$NP" && die "Nodes.pm 尚有舊版注入，請先 restore。"
 has_marker "$PVEJS" && die "pvemanagerlib.js 尚有舊版注入，請先 restore。"
 has_marker "$PLIBJS" && die "proxmoxlib.js 尚有舊版注入，請先 restore。"
 cp -a "$NP" "$OFFICIAL_NP"; cp -a "$PVEJS" "$OFFICIAL_PVEJS"; cp -a "$PLIBJS" "$OFFICIAL_PLIBJS"
 perl -c "$OFFICIAL_NP" >/dev/null 2>&1 || die "官方 Nodes.pm backup 語法錯誤"
}
restore(){
 backup_official
 cp -af "$OFFICIAL_NP" "$NP"; cp -af "$OFFICIAL_PVEJS" "$PVEJS"; cp -af "$OFFICIAL_PLIBJS" "$PLIBJS"
 perl -c "$NP" >/dev/null 2>&1 || die "Nodes.pm 還原後語法錯誤"
 ! has_marker "$NP" || die "Nodes.pm 還原後仍有舊注入"
 ! has_marker "$PVEJS" || die "pvemanagerlib.js 還原後仍有舊注入"
 ! has_marker "$PLIBJS" || die "proxmoxlib.js 還原後仍有舊注入"
 if [[ -f "$CRON_FILE" ]]; then rm -f "$CRON_FILE"; systemctl restart cron 2>/dev/null || true; fi
}
collect_metrics(){
 local quiet="${1:-false}"
 mkdir -p "$BASE_DIR" "$RUNTIME_DIR" "$RUNTIME_DIR/nvme" "$RUNTIME_DIR/sd" "$RUNTIME_DIR/raid"
 if ! timeout 10 pvesh get /nodes/localhost/disks/list --output-format json >"$PVE_JSON" 2>/dev/null; then echo '[]' >"$PVE_JSON"; fi
 jq empty "$PVE_JSON" >/dev/null 2>&1 || echo '[]' >"$PVE_JSON"
 modprobe k10temp 2>/dev/null || true
 CPU_GOV=none
 for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do if [[ -r "$g" ]]; then CPU_GOV="$(cat "$g" 2>/dev/null || echo none)"; [[ "$CPU_GOV" != none ]] && break; fi; done
 CPU_MIN=none; CPU_MAX=none
 [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq ]] && CPU_MIN="$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq 2>/dev/null || echo none)"
 [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq ]] && CPU_MAX="$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null || echo none)"
 CPU_MHZ="$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%s%s",sep,$2; sep=","}' /proc/cpuinfo 2>/dev/null || true)"
 PKGWATT=none; [[ -x /usr/sbin/turbostat ]] && PKGWATT="$(timeout 3 turbostat --quiet --cpu package --show PkgWatt -S sleep 0.25 2>/dev/null | tail -n1 || true)"
 { echo "gov:$CPU_GOV"; echo "min:$CPU_MIN"; echo "max:$CPU_MAX"; echo "pkgwatt:$PKGWATT"; grep -i 'cpu mhz' /proc/cpuinfo 2>/dev/null || true; } >"$RUNTIME_DIR/cpuFreq.txt"
 if timeout 3 sensors -A >"$THERMAL_FILE" 2>/dev/null && [[ -s "$THERMAL_FILE" ]]; then cp -f "$THERMAL_FILE" "$RUNTIME_DIR/thermal.txt"; else echo 'No sensor data' >"$RUNTIME_DIR/thermal.txt"; cp -f "$RUNTIME_DIR/thermal.txt" "$THERMAL_FILE"; fi
 jq -n --arg gov "$CPU_GOV" --arg min "$CPU_MIN" --arg max "$CPU_MAX" --arg mhz "$CPU_MHZ" --arg watt "$PKGWATT" '{governor:$gov,min_freq_khz:$min,max_freq_khz:$max,cpu_mhz:$mhz,pkgwatt:$watt}' >"$CPU_JSON"
 RAID_CONTROLLER="$(lspci 2>/dev/null | grep -Ei 'RAID bus controller|MegaRAID|SAS39xx' | head -n1 || true)"; echo '[]' >"$RAID_JSON"; RAID_COUNT=0
 if [[ -n "$RAID_CONTROLLER" ]]; then
  for PD in {0..15}; do
   raw="$(timeout 5 smartctl -a -j -d "megaraid,$PD" /dev/bus/0 2>/dev/null || echo '{}')"; jq -e '.model_name or .model_family or .device_model' <<<"$raw" >/dev/null 2>&1 || continue
   product="$(jq -r '.model_name // .model_family // .device_model // "UNKNOWN"' <<<"$raw")"; serial="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw")"; wwn="$(jq -r '.scsi_lun // .wwn // "UNKNOWN"' <<<"$raw")"; temp="$(jq -r '.temperature.current // .temperature.drive_temperature // "UNKNOWN"' <<<"$raw")"; smart=UNKNOWN
   jq -e '.smart_status.passed==false' <<<"$raw" >/dev/null 2>&1 && smart=FAIL; jq -e '.smart_status.passed==true' <<<"$raw" >/dev/null 2>&1 && smart=OK
   printf '%s\n' "$raw" >"$RUNTIME_DIR/raid/raid${PD}.json"
   jq -n --arg pd "$PD" --arg product "$(safe "$product")" --arg serial "$(safe "$serial")" --arg wwn "$(safe "$wwn")" --arg temp "$(safe "$temp")" --arg smart "$smart" '{physical_disk:$pd,product:$product,serial:$serial,wwn:$wwn,temperature:$temp,smart:$smart}' >>"$RAID_JSON.items"; RAID_COUNT=$((RAID_COUNT+1))
  done
 fi
 [[ -s "$RAID_JSON.items" ]] && jq -s '.' "$RAID_JSON.items" >"$RAID_JSON" || echo '[]' >"$RAID_JSON"; rm -f "$RAID_JSON.items"
 echo '[]' >"$RAID_MAP"
 for dev in /dev/sd?; do
  [[ -b "$dev" ]] || continue; serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null|xargs||true)"; wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null|xargs||true)"; idx=""
  [[ -n "$serial" ]] && idx="$(jq -r --arg s "$serial" '.[]|select(.serial==$s)|.physical_disk' "$RAID_JSON"|head -n1||true)"; [[ -z "$idx" || "$idx" == null ]] && [[ -n "$wwn" ]] && idx="$(jq -r --arg w "$wwn" '.[]|select(.wwn==$w)|.physical_disk' "$RAID_JSON"|head -n1||true)"
  [[ -n "$idx" && "$idx" != null ]] && jq -n --arg d "$dev" --arg s "$serial" --arg w "$wwn" --arg p "$idx" '{device:$d,serial:$s,wwn:$w,raid_physical_disk:$p}' >>"$RAID_MAP.items"
 done
 [[ -s "$RAID_MAP.items" ]] && jq -s '.' "$RAID_MAP.items" >"$RAID_MAP" || echo '[]' >"$RAID_MAP"; rm -f "$RAID_MAP.items"
 echo '[]' >"$DISKS_JSON"; SATA_COUNT=0
 for dev in /dev/sd?; do
  [[ -b "$dev" ]] || continue; name="${dev##*/}"; raid_idx="$(jq -r --arg d "$dev" '.[]|select(.device==$d)|.raid_physical_disk' "$RAID_MAP"|head -n1||true)"; [[ "$raid_idx" == null ]] && raid_idx=''; [[ -n "$raid_idx" ]] && continue
  model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null||true)"; serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null||true)"; wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null||true)"; size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null||true)"; rota="$(lsblk -dn -o ROTA "$dev" 2>/dev/null||true)"; tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null||true)"; smartopt=''; bus=SATA
  case "$tran" in sas) smartopt='-d scsi';bus=SAS;;sata|ata)bus=SATA;;*)smartopt='-d scsi';bus='SATA/SAS';;esac; [[ "$rota" == 0 ]] && type="$bus 固態硬碟" || type="$bus 傳統硬碟"
  raw="$(timeout 5 smartctl $smartopt -a -j "$dev" 2>/dev/null||echo '{}')"; printf '%s\n' "$raw" >"$RUNTIME_DIR/sd/${name}.json"; smart=UNKNOWN; jq -e '.smart_status.passed==false'<<<"$raw" >/dev/null 2>&1&&smart=FAIL;jq -e '.smart_status.passed==true'<<<"$raw" >/dev/null 2>&1&&smart=OK
  model2="$(jq -r '.model_name // .model_family // "UNKNOWN"'<<<"$raw")";serial2="$(jq -r '.serial_number // "UNKNOWN"'<<<"$raw")";temp="$(jq -r '.temperature.current // .temperature.drive_temperature // "UNKNOWN"'<<<"$raw")";hours="$(jq -r '.power_on_time.hours // "UNKNOWN"'<<<"$raw")";[[ "$model2" == UNKNOWN ]]&&model2="$model";[[ "$serial2" == UNKNOWN ]]&&serial2="$serial"
  jq -n --arg type "$type" --arg device "$dev" --arg name "$name" --arg model "$(safe "$model2")" --arg serial "$(safe "$serial2")" --arg wwn "$(safe "$wwn")" --arg size "$(safe "$size")" --arg smart "$smart" --arg temp "$(safe "$temp")" --arg hours "$(safe "$hours")" '{type:$type,device:$device,name:$name,model:$model,serial:$serial,wwn:$wwn,size:$size,smart:$smart,temperature:$temp,power_on_hours:$hours}' >>"$DISKS_JSON.items";SATA_COUNT=$((SATA_COUNT+1))
 done
 [[ -s "$DISKS_JSON.items" ]]&&jq -s '.' "$DISKS_JSON.items">"$DISKS_JSON"||echo '[]'>"$DISKS_JSON";rm -f "$DISKS_JSON.items"
 echo '[]'>"$NVME_JSON";NVME_COUNT=0
 for dev in /dev/nvme*n1;do [[ -b "$dev" ]]||continue;name="${dev##*/}";raw="$(timeout 5 smartctl -a -j "$dev" 2>/dev/null||echo '{}')";printf '%s\n' "$raw">"$RUNTIME_DIR/nvme/${name}.json";smart=UNKNOWN;jq -e '.smart_status.passed==false'<<<"$raw">/dev/null 2>&1&&smart=FAIL;jq -e '.smart_status.passed==true'<<<"$raw">/dev/null 2>&1&&smart=OK;model="$(jq -r '.model_name // "UNKNOWN"'<<<"$raw")";serial="$(jq -r '.serial_number // "UNKNOWN"'<<<"$raw")";temp="$(jq -r '.temperature.current // "UNKNOWN"'<<<"$raw")";hours="$(jq -r '.power_on_time.hours // "UNKNOWN"'<<<"$raw")";cycles="$(jq -r '.power_cycle_count // "UNKNOWN"'<<<"$raw")";health="$(jq -r 'if .nvme_smart_health_information_log.percentage_used!=null then 100-(.nvme_smart_health_information_log.percentage_used|tonumber) else "UNKNOWN" end'<<<"$raw")";read_tb="$(jq -r 'if .nvme_smart_health_information_log.data_units_read!=null then ((.nvme_smart_health_information_log.data_units_read|tonumber)*512000/1000000000000) else "UNKNOWN" end'<<<"$raw")";write_tb="$(jq -r 'if .nvme_smart_health_information_log.data_units_written!=null then ((.nvme_smart_health_information_log.data_units_written|tonumber)*512000/1000000000000) else "UNKNOWN" end'<<<"$raw")";jq -n --arg type NVMe --arg device "$dev" --arg name "$name" --arg model "$(safe "$model")" --arg serial "$(safe "$serial")" --arg smart "$smart" --arg temp "$(safe "$temp")" --arg hours "$(safe "$hours")" --arg cycles "$(safe "$cycles")" --arg health "$(safe "$health")" --arg read "$(safe "$read_tb")" --arg write "$(safe "$write_tb")" '{type:$type,device:$device,name:$name,model:$model,serial:$serial,smart:$smart,temperature:$temp,power_on_hours:$hours,power_cycle_count:$cycles,health_percent:$health,read_tb:$read,write_tb:$write}'>>"$NVME_JSON.items";NVME_COUNT=$((NVME_COUNT+1));done
 [[ -s "$NVME_JSON.items" ]]&&jq -s '.' "$NVME_JSON.items">"$NVME_JSON"||echo '[]'>"$NVME_JSON";rm -f "$NVME_JSON.items";TOTAL_COUNT=$((NVME_COUNT+SATA_COUNT+RAID_COUNT))
 jq -n --arg version "$VERSION" --arg updated "$UPDATED" --arg pve "$PVE_VERSION_FULL" --arg node "$PVE_NODE" --arg controller "$RAID_CONTROLLER" --arg thermal "$(cat "$THERMAL_FILE")" --arg nvme "$NVME_COUNT" --arg sata "$SATA_COUNT" --arg raid "$RAID_COUNT" --arg total "$TOTAL_COUNT" --argjson cpu "$(cat "$CPU_JSON")" --argjson nvme_disks "$(cat "$NVME_JSON")" --argjson disks "$(cat "$DISKS_JSON")" --argjson raid_disks "$(cat "$RAID_JSON")" --argjson inventory "$(cat "$PVE_JSON")" '{monitor:{script:"disk_monitor.sh",version:$version,updated:$updated},pve:{version:$pve,node:$node},raid_controller:$controller,cpu:$cpu,thermal:$thermal,summary:{nvme:$nvme,sata_sas:$sata,raid_physical_disk:$raid,total:$total},nvme_disks:$nvme_disks,disks:$disks,raid_physical_disks:$raid_disks,pve_disk_inventory:$inventory}' >"$BASE_DIR/final.json";jq empty "$BASE_DIR/final.json" >/dev/null 2>&1||die 'JSON 驗證失敗';install -m 0644 "$BASE_DIR/final.json" "$FINAL_JSON"
}
case "${1:-}" in restore)restore;systemctl restart pveproxy;echo 'PVE Web UI 已還原';echo '請按 Ctrl + F5';exit 0;;remod)"$0" restore;exec "$0" install;;collect|cron)collect_metrics true;exit 0;;install|''): :;;*)die "用法：$0 [install|collect|restore|remod]";;esac
[[ -f "$NP" && -f "$PVEJS" && -f "$PLIBJS" ]]||die '找不到 PVE UI 檔案';backup_official;restore;collect_metrics false
cat >"$CONTENT_NP" <<'PERL'
# disk_monitor_1.0.52
my $dm_read = sub { my ($file)=@_; return '' unless -r $file; if(open(my $fh,'<:encoding(UTF-8)',$file)){local $/;my $data=<$fh>//'';close($fh);return $data;}return ''; };
$res->{thermalstate}=$dm_read->('/run/disk_monitor_runtime/thermal.txt');
$res->{cpuFreq}=$dm_read->('/run/disk_monitor_runtime/cpuFreq.txt');
PERL
nvi_backend=0;for dev in /dev/nvme*n1;do [[ -b "$dev" ]]||continue;name="${dev##*/}";printf '$res->{nvme%s} = $dm_read->("/run/disk_monitor_runtime/nvme/%s.json");\n' "$nvi_backend" "$name">>"$CONTENT_NP";nvi_backend=$((nvi_backend+1));done
sdi_backend=0;for dev in /dev/sd?;do [[ -b "$dev" ]]||continue;idx="$(jq -r --arg d "$dev" '.[]|select(.device==$d)|.raid_physical_disk' "$RAID_MAP"|head -n1||true)";[[ "$idx" == null ]]&&idx='';[[ -n "$idx" ]]&&continue;name="${dev##*/}";printf '$res->{sd%s} = $dm_read->("/run/disk_monitor_runtime/sd/%s.json");\n' "$sdi_backend" "$name">>"$CONTENT_NP";sdi_backend=$((sdi_backend+1));done
raidi_backend=0;while IFS= read -r pd;do [[ -n "$pd" ]]||continue;printf '$res->{raid%s} = $dm_read->("/run/disk_monitor_runtime/raid/raid%s.json");\n' "$raidi_backend" "$pd">>"$CONTENT_NP";raidi_backend=$((raidi_backend+1));done< <(jq -r '.[].physical_disk' "$RAID_JSON")
cat >"$CONTENT_CPU_JS" <<'JS'
// disk_monitor_1.0.52_cpu
{itemId:'dm_cpumhz',colspan:2,printBar:false,title:gettext('CPU 運作狀態'),textField:'cpuFreq',renderer:function(v){if(!v)return '無法取得 CPU 資訊';let m=v.match(/cpu MHz\s*:\s*[\d.]+/ig)||[],f=[];m.forEach(function(x){let z=x.match(/[\d.]+$/);if(z)f.push(Number(z[0])/1000);});let text='';if(f.length){let avg=f.reduce((a,b)=>a+b,0)/f.length;text='平均: '+avg.toFixed(2)+' GHz ('+Math.min.apply(null,f).toFixed(1)+' ~ '+Math.max.apply(null,f).toFixed(1)+' GHz)';}let g=v.match(/(?<=^gov:).+/im),govName=(g&&g[0].trim())?g[0].trim().toUpperCase():'NONE';return text+' | 調速器模式: '+govName;}},
{itemId:'dm_thermalstate',colspan:2,printBar:false,title:gettext('CPU溫度 (°C)'),textField:'thermalstate',renderer:function(value){if(!value||value==='No sensor data')return '無感測器資料';let cpuList=[],otherList=[],nicCount=0,blocks=value.trim().split(/\n\s*\n/);blocks.forEach(function(block){let lines=block.split('\n'),chip=(lines[0]||'').trim();if(/nvme/i.test(chip))return;if(/coretemp|k10temp|zenpower/i.test(chip)){let pkgTemp='',pm=block.match(/(?:Package id \d+|Tctl|Tdie):\s*([+-]?\d+(?:\.\d+)?)\s*°C/i);if(pm)pkgTemp=Math.round(Number(pm[1]));let coreTemps=[],re=/(?:Core \d+|Tccd\d+):\s*([+-]?\d+(?:\.\d+)?)\s*°C/ig,cm;while((cm=re.exec(block))!==null)coreTemps.push(Math.round(Number(cm[1])));let str='';if(pkgTemp!==''&&coreTemps.length)str=pkgTemp+' ('+coreTemps.join(' | ')+' )°C';else if(pkgTemp!=='')str=pkgTemp+'°C';else if(coreTemps.length)str='('+coreTemps.join(' | ')+' )°C';if(str)cpuList.push(str);}else{let devName=chip.split('-')[0].toUpperCase(),dm=block.match(/(?:temp1|Composite|Board|Sensor \d+):\s*([+-]?\d+(?:\.\d+)?)\s*°C/i);if(dm){if(/BNXT|TG3|E1000|IXGBE|I40E|ICE|MLX/i.test(devName)){nicCount++;devName='網卡'+nicCount;}otherList.push(devName+': '+Math.round(Number(dm[1]))+'°C');}}});let out=[];if(cpuList.length){let rows=[];for(let i=0;i<cpuList.length;i++)rows.push(['CPU'+(i+1)+': '+cpuList[i]]);for(let j=0;j<otherList.length;j++)rows[Math.min(j,rows.length-1)].push(otherList[j]);rows.forEach(r=>out.push(r.join(' | ')));}else{let ms=value.match(/[+-]?\d+(?:\.\d+)?\s*°C/g);out.push(ms&&ms.length?'感測器: '+ms.join(' | '):'正常');}return out.join('<br>');}},
JS
cat >"$CONTENT_DISK_JS" <<'JS'
// disk_monitor_1.0.52_disk
JS
nvi_js=0;for dev in /dev/nvme*n1;do [[ -b "$dev" ]]||continue;cat >>"$CONTENT_DISK_JS" <<JS
{itemId:'nvme${nvi_js}0',colspan:2,printBar:false,title:gettext('NVMe 硬碟 ${nvi_js}'),textField:'nvme${nvi_js}',renderer:function(value){try{let v=JSON.parse(value||'{}'),s=v.model_name||v.model_family||'未知型號';if(v.temperature&&v.temperature.current!==undefined)s+=' | 溫度: '+v.temperature.current+'°C';let l=v.nvme_smart_health_information_log;if(l&&l.percentage_used!==undefined)s+=' | 健康度: '+Math.max(0,100-Number(l.percentage_used))+'%';if(v.power_on_time&&v.power_on_time.hours!==undefined)s+=' | 通電: '+v.power_on_time.hours+' 小時';if(v.power_cycle_count!==undefined)s+=' (開關機: '+v.power_cycle_count+' 次)';if(l&&l.data_units_read!==undefined&&l.data_units_written!==undefined)s+=' | 讀寫: '+(Number(l.data_units_read)*512000/1000000000000).toFixed(1)+' TB / '+(Number(l.data_units_written)*512000/1000000000000).toFixed(1)+' TB';let p=v.smart_status&&v.smart_status.passed;s+=' | SMART: '+(p===true?'<span style="color:#21ba45;font-weight:bold;">正常</span>':p===false?'<span style="color:#db2828;font-weight:bold;">FAIL</span>':'<span style="color:#888;font-weight:bold;">未判定</span>');return s}catch(e){return '資料解析失敗';}}},
JS
nvi_js=$((nvi_js+1));done
RAID_SHORT="$(printf '%s\n' "$RAID_CONTROLLER"|sed -E -e 's/^[0-9A-Fa-f:.]+[[:space:]]+//' -e 's/^RAID bus controller:[[:space:]]*//' -e 's/[[:space:]]+\(rev[[:space:]]+[^)]*\)$//' -e 's/[[:space:]]+/ /g'|sed 's/^[[:space:]]*//;s/[[:space:]]*$//'|cut -c1-120)";[[ -n "$RAID_SHORT" ]]||RAID_SHORT='未偵測到 RAID Controller';RAID_SHORT_JS="$(printf '%s' "$RAID_SHORT"|sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e ':a;N;$!ba;s/\n/ /g')"
if ((RAID_COUNT>0));then cat >>"$CONTENT_DISK_JS" <<JS
{itemId:'raid-controller',colspan:2,printBar:false,title:gettext('RAID 控制器'),textField:'pveversion',renderer:function(){return '${RAID_SHORT_JS}';}},
JS
fi
raidi_js=0;while IFS= read -r pd;do [[ -n "$pd" ]]||continue;cat >>"$CONTENT_DISK_JS" <<JS
{itemId:'raid${raidi_js}0',colspan:2,printBar:false,title:gettext('RAID 硬碟 ${pd}'),textField:'raid${raidi_js}',renderer:function(value){try{let v=JSON.parse(value||'{}'),s=v.model_name||v.model_family||v.product||'未知型號';if(v.temperature&&v.temperature.current!==undefined)s+=' | 溫度: '+v.temperature.current+'°C';if(v.power_on_time&&v.power_on_time.hours!==undefined)s+=' | 通電: '+Number(v.power_on_time.hours).toLocaleString()+' 小時';let p=v.smart_status&&v.smart_status.passed;s+=' | SMART: '+(p===true?'<span style="color:#21ba45;font-weight:bold;">正常</span>':p===false?'<span style="color:#db2828;font-weight:bold;">FAIL</span>':'<span style="color:#888;font-weight:bold;">未判定</span>');return s}catch(e){return '資料解析失敗';}}},
JS
raidi_js=$((raidi_js+1));done< <(jq -r '.[].physical_disk' "$RAID_JSON")
sdi_js=0;for dev in /dev/sd?;do [[ -b "$dev" ]]||continue;idx="$(jq -r --arg d "$dev" '.[]|select(.device==$d)|.raid_physical_disk' "$RAID_MAP"|head -n1||true)";[[ "$idx" == null ]]&&idx='';[[ -n "$idx" ]]&&continue;name="${dev##*/}";rot="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null||echo 1)";tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null|tr -d '[:space:]')";case "$tran" in sas)bus=SAS;;sata|ata)bus=SATA;;*)bus='SATA/SAS';;esac;[[ "$rot" == 0 ]]&&typ="$bus 固態硬碟"||typ="$bus 傳統硬碟";cat >>"$CONTENT_DISK_JS" <<JS
{itemId:'sd${sdi_js}0',colspan:2,printBar:false,title:gettext('${typ} ${sdi_js}'),textField:'sd${sdi_js}',renderer:function(value){try{let v=JSON.parse(value||'{}'),s=v.model_name||v.model_family||'未知型號';if(v.temperature&&v.temperature.current!==undefined)s+=' | 溫度: '+v.temperature.current+'°C';if(v.power_on_time&&v.power_on_time.hours!==undefined)s+=' | 通電: '+v.power_on_time.hours+' 小時';let p=v.smart_status&&v.smart_status.passed;s+=' | SMART: '+(p===true?'<span style="color:#21ba45;font-weight:bold;">正常</span>':p===false?'<span style="color:#db2828;font-weight:bold;">FAIL</span>':'<span style="color:#888;font-weight:bold;">未判定</span>');return s}catch(e){return '資料解析失敗';}}},
JS
sdi_js=$((sdi_js+1));done
sed -i "/PVE::pvecfg::version_text()/r $CONTENT_NP" "$NP"
awk -v file="$CONTENT_CPU_JS" 'BEGIN{armed=0;found=0}/render_cpu_model/&&!found{armed=1}armed{print;if($0~/^[[:space:]]*},[[:space:]]*$/){while((getline line<file)>0)print line;close(file);found=1;armed=0;next}next}{print}END{if(!found)exit 2}' "$PVEJS" >"$BASE_DIR/pvemanagerlib.cpu.js" || { restore;systemctl restart pveproxy 2>/dev/null||true;die '找不到 render_cpu_model 插入位置'; }
awk -v file="$CONTENT_DISK_JS" 'BEGIN{armed=0;found=0}/textField:[[:space:]]*'"'"'pveversion'"'"'/&&!found{armed=1}armed{print;if($0~/^[[:space:]]*},[[:space:]]*$/){while((getline line<file)>0)print line;close(file);found=1;armed=0;next}next}{print}END{if(!found)exit 2}' "$BASE_DIR/pvemanagerlib.cpu.js" >"$BASE_DIR/pvemanagerlib.final.js" || { restore;systemctl restart pveproxy 2>/dev/null||true;die '找不到 pveversion 插入位置'; }
mv -f "$BASE_DIR/pvemanagerlib.final.js" "$PVEJS"
awk -v marker='widget.pveNodeStatus' -v repl='height: "auto", minHeight: 300' 'BEGIN{armed=0;left=0;changed=0}{if(!armed&&index($0,marker)>0){armed=1;left=80}if(armed&&$0~/height:[[:space:]]*[0-9]+/){sub(/height:[[:space:]]*[0-9]+/,repl);changed=1;armed=0;left=0}if(armed){left--;if(left<=0)armed=0}print}END{if(!changed)exit 2}' "$PVEJS" >"$BASE_DIR/pvemanagerlib.height.js" || { rm -f "$BASE_DIR/pvemanagerlib.height.js";restore;systemctl restart pveproxy 2>/dev/null||true;die '找不到 widget.pveNodeStatus height'; }
mv -f "$BASE_DIR/pvemanagerlib.height.js" "$PVEJS"
if ! grep -q 'disk_monitor_1.0.52_subscription' "$PLIBJS" && grep -q '/nodes/localhost/subscription' "$PLIBJS";then sed -E -i '/\/nodes\/localhost\/subscription/,+15{ / if \(/,/Ext\.Msg\.show/{ H; /Ext\.Msg\.show/!d; x; s/(.* if \().*(\).*)/\1false\2/; i\\//disk_monitor_1.0.52_subscription } }' "$PLIBJS" || { restore;systemctl restart pveproxy 2>/dev/null||true;die 'proxmoxlib.js subscription 注入失敗';};fi
perl -c "$NP" >/dev/null 2>&1||{restore;systemctl restart pveproxy 2>/dev/null||true;die 'Nodes.pm Perl syntax error';}
grep -q 'disk_monitor_1.0.52' "$NP"||{restore;systemctl restart pveproxy 2>/dev/null||true;die 'Nodes.pm 注入標記不存在';}
grep -q 'disk_monitor_1.0.52_cpu' "$PVEJS"||{restore;systemctl restart pveproxy 2>/dev/null||true;die 'pvemanagerlib.js CPU 注入標記不存在';}
cat >"$CRON_FILE" <<EOF
* * * * * root ${SCRIPT_PATH} collect >/dev/null 2>&1
EOF
chmod 0644 "$CRON_FILE";systemctl restart cron 2>/dev/null||true
if ! timeout 10 pvesh get /nodes/localhost/status --output-format json >"$BASE_DIR/api_before.json" 2>/dev/null;then restore;systemctl restart pveproxy 2>/dev/null||true;die '套用後 PVE API 失敗';fi
jq -e '.cpuFreq != null and .thermalstate != null' "$BASE_DIR/api_before.json" >/dev/null 2>&1||{restore;systemctl restart pveproxy 2>/dev/null||true;die 'PVE API 缺少 backend fields';}
systemctl restart pveproxy;sleep 2
if ! timeout 10 pvesh get /nodes/localhost/status --output-format json >"$BASE_DIR/api_after.json" 2>/dev/null;then restore;systemctl restart pveproxy 2>/dev/null||true;die 'pveproxy restart 後 PVE API 失敗';fi
jq -e '.cpuFreq != null and .thermalstate != null' "$BASE_DIR/api_after.json" >/dev/null 2>&1||{restore;systemctl restart pveproxy 2>/dev/null||true;die 'pveproxy restart 後缺少 backend fields';}
echo "disk_monitor.sh ${VERSION} 完成 (All-in-One)";echo "NVMe=${NVME_COUNT} SATA/SAS=${SATA_COUNT} RAID=${RAID_COUNT} Total=${TOTAL_COUNT}";echo "Cron=${CRON_FILE} 每分鐘採集";echo '請瀏覽器執行 Ctrl + F5'
