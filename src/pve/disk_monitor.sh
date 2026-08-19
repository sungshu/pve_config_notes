#!/usr/bin/env bash
# PVE 磁碟健康監控腳本 (v1.0.5)
# 功能：SMART 健康檢查、溫度監控、MegaRAID 支援、JSON 輸出、HTML 報告
# 作者：Perplexity AI
# 最後更新：2025-08-19

set -euo pipefail

# ============ 配置 ============
SCRIPT_VERSION="1.0.5"
OUTPUT_DIR="/root/pve_monitor"
HTML_REPORT="${OUTPUT_DIR}/disk_health_report.html"
JSON_OUTPUT="${OUTPUT_DIR}/disk_health.json"
LOG_FILE="${OUTPUT_DIR}/disk_monitor.log"
MAX_LOG_SIZE=1048576  # 1MB
SMART_TIMEOUT=30
TEMP_WARN=45
TEMP_CRIT=55

# ============ 初始化 ============
mkdir -p "$OUTPUT_DIR"

# 日誌輪轉
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "啟動磁碟健康監控腳本 v${SCRIPT_VERSION}"

# ============ 工具函數 ============
command_exists() {
    command -v "$1" &> /dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "錯誤：需要 root 權限"
        exit 1
    fi
}

cleanup() {
    log "清理臨時檔案..."
    rm -f /tmp/smart_*.tmp /tmp/megaraid_*.tmp 2>/dev/null || true
}
trap cleanup EXIT

# ============ 依賴檢查 ============
check_dependencies() {
    log "檢查依賴..."
    local deps=("smartmontools" "jq" "lsblk")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "警告：缺少依賴 ${missing[*]}，部分功能可能無法使用"
        return 1
    fi
    
    log "依賴檢查通過"
    return 0
}

# ============ 磁碟偵測 ============
detect_drives() {
    log "偵測磁碟..."
    local drives=()
    
    # NVMe 磁碟
    if command_exists nvme; then
        while IFS= read -r nvme_dev; do
            [[ -n "$nvme_dev" ]] && drives+=("$nvme_dev")
        done < <(nvme list 2>/dev/null | grep -oP '/dev/nvme\d+n\d+' | sort -u)
    fi
    
    # SATA/SAS 磁碟
    while IFS= read -r sd_dev; do
        [[ -n "$sd_dev" ]] && drives+=("$sd_dev")
    done < <(lsblk -nd -o NAME 2>/dev/null | grep -E '^sd[a-z]+$' | sed 's/^/\/dev\//')
    
    # MegaRAID 磁碟
    if command_exists storcli; then
        while IFS= read -r raid_dev; do
            [[ -n "$raid_dev" ]] && drives+=("$raid_dev")
        done < <(storcli /call show | grep -oP 'E[0-9]+:S[0-9]+' | sort -u)
    fi
    
    printf '%s\n' "${drives[@]}" | sort -u
}

# ============ SMART 資料收集 ============
get_smart_data() {
    local drive="$1"
    local json_file="/tmp/smart_${drive//\//_}.json"
    
    log "收集 $drive 的 SMART 資料..."
    
    if [[ "$drive" =~ ^/dev/nvme ]]; then
        # NVMe 磁碟
        if smartctl -a "$drive" -o on >/dev/null 2>&1; then
            smartctl -a -j "$drive" 2>/dev/null | jq --arg dev "$drive" '. + {device: $dev}' > "$json_file"
        fi
    elif [[ "$drive" =~ ^/dev/sd ]]; then
        # SATA/SAS 磁碟
        if smartctl -a "$drive" -o on >/dev/null 2>&1; then
            smartctl -a -j "$drive" 2>/dev/null | jq --arg dev "$drive" '. + {device: $dev}' > "$json_file"
        fi
    elif [[ "$drive" =~ ^E[0-9]+:S[0-9]+ ]]; then
        # MegaRAID 磁碟
        local enc=$(echo "$drive" | grep -oP 'E[0-9]+')
        local slot=$(echo "$drive" | grep -oP 'S[0-9]+')
        local mega_dev="/dev/$(storcli /call show | grep "$enc:$slot" | awk '{print $NF}')"
        
        if smartctl -a "$mega_dev" -o on >/dev/null 2>&1; then
            smartctl -a -j "$mega_dev" 2>/dev/null | jq --arg dev "$drive" '. + {device: $dev, raid: true}' > "$json_file"
        fi
    fi
    
    [[ -f "$json_file" ]] && cat "$json_file"
}

# ============ 健康評估 ============
evaluate_health() {
    local smart_json="$1"
    
    # 檢查 SMART 整體健康狀態
    local smart_status
    smart_status=$(echo "$smart_json" | jq -r '.smart_status.passed // empty')
    
    if [[ "$smart_status" == "true" ]]; then
        echo "PASS"
    elif [[ "$smart_status" == "false" ]]; then
        echo "FAIL"
    else
        echo "UNKNOWN"
    fi
}

# ============ 溫度監控 ============
get_temperature() {
    local smart_json="$1"
    
    # NVMe 溫度
    local temp
    temp=$(echo "$smart_json" | jq -r '.temperature.current // empty')
    
    if [[ -n "$temp" ]]; then
        echo "$temp"
        return
    fi
    
    # SATA/SAS 溫度
    temp=$(echo "$smart_json" | jq -r '.ata_smart_data.temperature.current // empty')
    [[ -n "$temp" ]] && echo "$temp"
}

# ============ JSON 輸出 ============
generate_json_output() {
    local drives=("$@")
    local results=()
    
    for drive in "${drives[@]}"; do
        local smart_json
        smart_json=$(get_smart_data "$drive")
        
        if [[ -n "$smart_json" ]]; then
            local health
            health=$(evaluate_health "$smart_json")
            
            local temp
            temp=$(get_temperature "$smart_json")
            
            results+=("$(echo "$smart_json" | jq --arg health "$health" --arg temp "$temp" '. + {health: $health, temperature: $temp}')")
        fi
    done
    
    echo "${results[@]}" | jq -s '.'
}

# ============ HTML 報告 ============
generate_html_report() {
    local json_data="$1"
    
    cat > "$HTML_REPORT" << 'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PVE 磁碟健康報告</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #007bff; padding-bottom: 10px; }
        .disk { border: 1px solid #ddd; margin: 10px 0; padding: 15px; border-radius: 4px; }
        .disk.pass { border-left: 4px solid #28a745; }
        .disk.fail { border-left: 4px solid #dc3545; }
        .disk.unknown { border-left: 4px solid #ffc107; }
        .status { font-weight: bold; }
        .status.pass { color: #28a745; }
        .status.fail { color: #dc3545; }
        .status.unknown { color: #ffc107; }
        .temp { color: #666; }
        .temp.warn { color: #ffc107; }
        .temp.crit { color: #dc3545; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background: #f8f9fa; }
    </style>
</head>
<body>
    <div class="container">
        <h1>PVE 磁碟健康報告</h1>
        <p>生成時間：<span id="timestamp"></span></p>
        <div id="disks"></div>
    </div>
    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString('zh-TW');
        const disks = JSON.parse(`$json_data`);
        const container = document.getElementById('disks');
        
        disks.forEach(disk => {
            const div = document.createElement('div');
            div.className = `disk ${disk.health.toLowerCase()}`;
            
            let tempClass = '';
            if (disk.temperature && disk.temperature > 55) tempClass = 'crit';
            else if (disk.temperature && disk.temperature > 45) tempClass = 'warn';
            
            div.innerHTML = `
                <h3>磁碟：${disk.device}</h3>
                <p>健康狀態：<span class="status ${disk.health.toLowerCase()}">${disk.health}</span></p>
                <p class="temp">溫度：${disk.temperature || 'N/A'} °C ${tempClass ? `<span class="temp ${tempClass}">(${tempClass.toUpperCase()})</span>` : ''}</p>
                <p>MegaRAID: ${disk.raid ? '是' : '否'}</p>
                <p>SMART 整體通過：${disk.smart_status && disk.smart_status.passed ? '是' : '否'}</p>
            `;
            container.appendChild(div);
        });
    </script>
</body>
</html>
EOF

    log "HTML 報告已生成：$HTML_REPORT"
}

# ============ 主程式 ============
main() {
    check_root
    check_dependencies || true
    
    local drives
    drives=($(detect_drives))
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        log "警告：未偵測到任何磁碟"
        exit 0
    fi
    
    log "偵測到 ${#drives[@]} 個磁碟：${drives[*]}"
    
    # JSON 輸出
    local json_output
    json_output=$(generate_json_output "${drives[@]}")
    echo "$json_output" | jq '.' > "$JSON_OUTPUT"
    log "JSON 輸出已儲存：$JSON_OUTPUT"
    
    # HTML 報告
    generate_html_report "$json_output"
    
    # 輸出摘要
    local pass_count=0
    local fail_count=0
    local unknown_count=0
    
    for drive in "${drives[@]}"; do
        local smart_json
        smart_json=$(get_smart_data "$drive")
        
        if [[ -n "$smart_json" ]]; then
            local health
            health=$(evaluate_health "$smart_json")
            
            case "$health" in
                PASS) ((pass_count++)) ;;
                FAIL) ((fail_count++)) ;;
                *) ((unknown_count++)) ;;
            esac
        fi
    done
    
    log "健康檢查完成：$pass_count 通過，$fail_count 失敗，$unknown_count 未知"
    
    if [[ $fail_count -gt 0 ]]; then
        log "警告：有磁碟健康檢查失敗！"
        exit 1
    fi
}

main
