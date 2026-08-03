#!/usr/bin/env bash
# NVIDIA GPU TUI Manager
# Manage per-GPU PowerMizer mode, power limits, systemd service, and GNOME autostart.

set -Eeuo pipefail

APP_NAME="NVIDIA GPU TUI Manager"
APP_ID="nvidia-gpu-tui"
VERSION="1.0.0"

CONFIG_DIR="/etc/${APP_ID}"
CONFIG_FILE="${CONFIG_DIR}/config"
ROOT_HELPER="/usr/local/libexec/${APP_ID}-apply"
SERVICE_FILE="/etc/systemd/system/${APP_ID}.service"
SERVICE_NAME="${APP_ID}.service"

INVOKING_USER="${SUDO_USER:-$(id -un)}"
if [[ "$INVOKING_USER" == "root" ]]; then
    INVOKING_USER="$(logname 2>/dev/null || true)"
fi
if [[ -z "$INVOKING_USER" || "$INVOKING_USER" == "root" ]]; then
    printf '请以普通桌面用户运行本脚本，不要直接以 root 登录后运行。\n' >&2
    exit 1
fi
if (( EUID == 0 )); then
    printf '请直接运行脚本，不要在命令前加 sudo；脚本会在需要时自行请求管理员权限。\n' >&2
    exit 1
fi

USER_HOME="$(getent passwd "$INVOKING_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    printf '无法确定用户 %s 的主目录。\n' "$INVOKING_USER" >&2
    exit 1
fi

USER_HELPER="${USER_HOME}/.local/bin/${APP_ID}-powermizer"
USER_AUTOSTART="${USER_HOME}/.config/autostart/${APP_ID}-powermizer.desktop"
USER_STATE_DIR="${USER_HOME}/.local/state/${APP_ID}"
USER_LOG="${USER_STATE_DIR}/powermizer.log"

UI=""
BACKTITLE="${APP_NAME} v${VERSION}  |  用户: ${INVOKING_USER}"

declare -a GPU_INDEXES=()
declare -A GPU_NAME=()
declare -A GPU_MIN=()
declare -A GPU_DEFAULT=()
declare -A GPU_MAX=()
declare -A CFG_HIGH=()
declare -A CFG_LIMIT=()

cleanup() {
    clear 2>/dev/null || true
}
trap cleanup EXIT

need_command() {
    command -v "$1" >/dev/null 2>&1
}

setup_ui() {
    if need_command dialog; then
        UI="dialog"
    elif need_command whiptail; then
        UI="whiptail"
    else
        printf '未找到 dialog 或 whiptail，正在安装 dialog……\n'
        sudo apt-get update
        sudo apt-get install -y dialog
        UI="dialog"
    fi
}

ui_msg() {
    local title="$1" text="$2"
    "$UI" --backtitle "$BACKTITLE" --title "$title" --msgbox "$text" 18 76
}

ui_yesno() {
    local title="$1" text="$2"
    "$UI" --backtitle "$BACKTITLE" --title "$title" --yesno "$text" 16 76
}

ui_input() {
    local title="$1" text="$2" initial="${3:-}"
    "$UI" --backtitle "$BACKTITLE" --title "$title" \
        --inputbox "$text" 17 78 "$initial" 3>&1 1>&2 2>&3
}

ui_menu() {
    local title="$1" text="$2"
    shift 2
    "$UI" --backtitle "$BACKTITLE" --title "$title" \
        --menu "$text" 22 84 12 "$@" 3>&1 1>&2 2>&3
}

ui_checklist() {
    local title="$1" text="$2"
    shift 2
    "$UI" --backtitle "$BACKTITLE" --title "$title" \
        --separate-output --checklist "$text" 22 92 12 "$@" \
        3>&1 1>&2 2>&3
}

ui_textbox_from_command() {
    local title="$1"
    shift
    local tmp
    tmp="$(mktemp)"
    { "$@"; } >"$tmp" 2>&1 || true
    "$UI" --backtitle "$BACKTITLE" --title "$title" --textbox "$tmp" 24 100
    rm -f "$tmp"
}

require_nvidia() {
    if ! need_command nvidia-smi; then
        ui_msg "缺少 NVIDIA 驱动" "未找到 nvidia-smi。\n\n请先安装并启用 NVIDIA 官方驱动，再运行本工具。"
        return 1
    fi
    if ! nvidia-smi -L >/dev/null 2>&1; then
        ui_msg "GPU 不可用" "nvidia-smi 存在，但当前无法访问 NVIDIA GPU。\n\n请检查驱动是否加载，或重启后再试。"
        return 1
    fi
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

refresh_gpu_data() {
    require_nvidia || return 1

    GPU_INDEXES=()
    GPU_NAME=()
    GPU_MIN=()
    GPU_DEFAULT=()
    GPU_MAX=()

    local idx name min default max
    while IFS=',' read -r idx name min default max; do
        idx="$(trim "$idx")"
        name="$(trim "$name")"
        min="$(trim "$min")"
        default="$(trim "$default")"
        max="$(trim "$max")"

        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        GPU_INDEXES+=("$idx")
        GPU_NAME["$idx"]="$name"
        GPU_MIN["$idx"]="$min"
        GPU_DEFAULT["$idx"]="$default"
        GPU_MAX["$idx"]="$max"
    done < <(nvidia-smi \
        --query-gpu=index,name,power.min_limit,power.default_limit,power.max_limit \
        --format=csv,noheader,nounits 2>/dev/null)

    if ((${#GPU_INDEXES[@]} == 0)); then
        ui_msg "没有 GPU" "未能从 nvidia-smi 读取 GPU 信息。"
        return 1
    fi
}

load_config() {
    CFG_HIGH=()
    CFG_LIMIT=()

    local idx key value
    for idx in "${GPU_INDEXES[@]}"; do
        CFG_HIGH["$idx"]="0"
        CFG_LIMIT["$idx"]=""
    done

    [[ -r "$CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        case "$key" in
            GPU_*_HIGH_PERF)
                idx="${key#GPU_}"
                idx="${idx%_HIGH_PERF}"
                [[ "$idx" =~ ^[0-9]+$ ]] && CFG_HIGH["$idx"]="${value:-0}"
                ;;
            GPU_*_POWER_LIMIT)
                idx="${key#GPU_}"
                idx="${idx%_POWER_LIMIT}"
                [[ "$idx" =~ ^[0-9]+$ ]] && CFG_LIMIT["$idx"]="$value"
                ;;
        esac
    done < "$CONFIG_FILE"
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

within_range() {
    local value="$1" min="$2" max="$3"
    awk -v v="$value" -v lo="$min" -v hi="$max" \
        'BEGIN { exit !(v >= lo && v <= hi) }'
}

render_config() {
    local idx
    printf '# Generated by %s v%s\n' "$APP_NAME" "$VERSION"
    printf 'CONFIG_VERSION=1\n'
    printf 'GPU_INDEXES="'
    printf '%s ' "${GPU_INDEXES[@]}"
    printf '"\n'
    for idx in "${GPU_INDEXES[@]}"; do
        printf 'GPU_%s_HIGH_PERF=%s\n' "$idx" "${CFG_HIGH[$idx]:-0}"
        printf 'GPU_%s_POWER_LIMIT=%s\n' "$idx" "${CFG_LIMIT[$idx]:-}"
    done
}

save_config() {
    local tmp
    tmp="$(mktemp)"
    render_config > "$tmp"
    sudo install -d -m 0755 "$CONFIG_DIR"
    sudo install -m 0644 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

configure_gpus() {
    refresh_gpu_data || return
    load_config

    local -a items=()
    local idx state selected current answer min default max prompt
    for idx in "${GPU_INDEXES[@]}"; do
        state="OFF"
        [[ "${CFG_HIGH[$idx]:-0}" == "1" ]] && state="ON"
        items+=("$idx" "GPU ${idx}  ${GPU_NAME[$idx]}" "$state")
    done

    selected="$(ui_checklist \
        "选择高性能模式 GPU" \
        "勾选需要登录后设置为 PowerMizer 最高性能模式的 GPU。\n未勾选 GPU 会设置为自适应模式。" \
        "${items[@]}")" || return

    for idx in "${GPU_INDEXES[@]}"; do
        CFG_HIGH["$idx"]="0"
    done
    while IFS= read -r idx; do
        [[ "$idx" =~ ^[0-9]+$ ]] && CFG_HIGH["$idx"]="1"
    done <<< "$selected"

    for idx in "${GPU_INDEXES[@]}"; do
        min="${GPU_MIN[$idx]}"
        default="${GPU_DEFAULT[$idx]}"
        max="${GPU_MAX[$idx]}"
        current="${CFG_LIMIT[$idx]:-}"

        if [[ "$min" == "N/A" || "$max" == "N/A" || ! "$min" =~ ^[0-9] ]]; then
            CFG_LIMIT["$idx"]=""
            ui_msg "GPU ${idx}" "${GPU_NAME[$idx]}\n\n驱动未报告可调功耗范围，将跳过功耗限制。"
            continue
        fi

        prompt="${GPU_NAME[$idx]}\n\n允许范围：${min} W ～ ${max} W\n默认功耗：${default} W\n\n输入功耗上限（W）。留空表示不覆盖驱动默认值。"
        while true; do
            answer="$(ui_input "GPU ${idx} 功耗上限" "$prompt" "$current")" || return
            answer="$(trim "$answer")"
            if [[ -z "$answer" ]]; then
                CFG_LIMIT["$idx"]=""
                break
            fi
            if is_number "$answer" && within_range "$answer" "$min" "$max"; then
                CFG_LIMIT["$idx"]="$answer"
                break
            fi
            ui_msg "输入无效" "请输入 ${min} 到 ${max} 之间的数字，或留空。"
        done
    done

    save_config
    ui_msg "配置已保存" "GPU 配置已写入：\n${CONFIG_FILE}\n\n选择“安装/更新服务”后可确保开机自动应用。"
}

install_root_helper() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<'__ROOT_HELPER__'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/nvidia-gpu-tui/config"
NVIDIA_SMI="/usr/bin/nvidia-smi"

for _ in $(seq 1 30); do
    "$NVIDIA_SMI" -L >/dev/null 2>&1 && break
    sleep 2
done

if ! "$NVIDIA_SMI" -L >/dev/null 2>&1; then
    echo "NVIDIA GPU unavailable after waiting 60 seconds" >&2
    exit 1
fi

[[ -r "$CONFIG_FILE" ]] || {
    echo "Missing configuration: $CONFIG_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

"$NVIDIA_SMI" -pm 1 || true

for idx in ${GPU_INDEXES:-}; do
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    var="GPU_${idx}_POWER_LIMIT"
    limit="${!var:-}"
    [[ -n "$limit" ]] || continue
    "$NVIDIA_SMI" -i "$idx" -pl "$limit"
done
__ROOT_HELPER__
    sudo install -d -m 0755 "$(dirname "$ROOT_HELPER")"
    sudo install -m 0755 "$tmp" "$ROOT_HELPER"
    rm -f "$tmp"
}

install_service_file() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<__SERVICE__
[Unit]
Description=NVIDIA per-GPU power limit manager
After=systemd-modules-load.service multi-user.target
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
ExecStart=${ROOT_HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
__SERVICE__
    sudo install -m 0644 "$tmp" "$SERVICE_FILE"
    rm -f "$tmp"
}

install_user_helper() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<__USER_HELPER__
#!/usr/bin/env bash
set -u

CONFIG_FILE="${CONFIG_FILE}"
NVIDIA_SETTINGS="/usr/bin/nvidia-settings"
LOG_FILE="${USER_LOG}"

mkdir -p "\$(dirname "\$LOG_FILE")"
exec >>"\$LOG_FILE" 2>&1

echo "===== \$(date --iso-8601=seconds) ====="

[[ -x "\$NVIDIA_SETTINGS" ]] || {
    echo "nvidia-settings not found"
    exit 1
}
[[ -r "\$CONFIG_FILE" ]] || {
    echo "configuration not readable: \$CONFIG_FILE"
    exit 1
}

for _ in \$(seq 1 12); do
    if "\$NVIDIA_SETTINGS" -q gpus >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

# shellcheck disable=SC1090
source "\$CONFIG_FILE"

for idx in \${GPU_INDEXES:-}; do
    [[ "\$idx" =~ ^[0-9]+\$ ]] || continue
    var="GPU_\${idx}_HIGH_PERF"
    high="\${!var:-0}"
    mode=0
    [[ "\$high" == "1" ]] && mode=1
    "\$NVIDIA_SETTINGS" -a "[gpu:\${idx}]/GPUPowerMizerMode=\${mode}" || true
done
__USER_HELPER__

    sudo -u "$INVOKING_USER" mkdir -p \
        "$(dirname "$USER_HELPER")" \
        "$(dirname "$USER_AUTOSTART")" \
        "$USER_STATE_DIR"
    sudo install -o "$INVOKING_USER" -g "$INVOKING_USER" -m 0755 "$tmp" "$USER_HELPER"
    rm -f "$tmp"

    tmp="$(mktemp)"
    cat > "$tmp" <<__AUTOSTART__
[Desktop Entry]
Type=Application
Name=NVIDIA GPU Performance Profile
Comment=Apply per-GPU NVIDIA PowerMizer settings
Exec=/bin/bash ${USER_HELPER}
X-GNOME-Autostart-enabled=true
NoDisplay=true
Hidden=false
Terminal=false
__AUTOSTART__
    sudo install -o "$INVOKING_USER" -g "$INVOKING_USER" -m 0644 "$tmp" "$USER_AUTOSTART"
    rm -f "$tmp"
}

install_or_update() {
    refresh_gpu_data || return
    load_config

    if [[ ! -r "$CONFIG_FILE" ]]; then
        ui_msg "尚未配置" "请先为各 GPU 选择高性能模式和功耗上限。"
        configure_gpus || return
        refresh_gpu_data || return
        load_config
    fi

    install_root_helper
    install_service_file
    install_user_helper

    sudo systemctl daemon-reload
    if sudo systemctl enable --now "$SERVICE_NAME" >/tmp/${APP_ID}-systemctl.log 2>&1; then
        ui_msg "安装完成" "已安装并启动：${SERVICE_NAME}\n\n系统启动时应用功耗上限；用户登录 GNOME 后应用 PowerMizer 模式。"
    else
        local details
        details="$(cat /tmp/${APP_ID}-systemctl.log 2>/dev/null || true)"
        ui_msg "服务启动失败" "服务文件已安装，但启动失败：\n\n${details}\n\n可在“查看状态”中读取详细日志。"
    fi
    rm -f /tmp/${APP_ID}-systemctl.log
}

apply_now() {
    refresh_gpu_data || return
    load_config

    if [[ ! -r "$CONFIG_FILE" ]]; then
        ui_msg "没有配置" "请先完成 GPU 配置。"
        return
    fi

    local root_ok="否" user_ok="否" root_log

    if [[ -x "$ROOT_HELPER" ]]; then
        if sudo "$ROOT_HELPER" >/tmp/${APP_ID}-root-apply.log 2>&1; then
            root_ok="是"
        fi
    else
        ui_msg "服务未安装" "尚未安装 root 应用脚本。请选择“安装/更新服务”。"
        return
    fi

    if [[ -x "$USER_HELPER" ]]; then
        if "$USER_HELPER" >/dev/null 2>&1; then
            user_ok="是"
        fi
    fi

    root_log="$(cat /tmp/${APP_ID}-root-apply.log 2>/dev/null || true)"
    rm -f /tmp/${APP_ID}-root-apply.log

    ui_msg "立即应用结果" "功耗上限应用成功：${root_ok}\nPowerMizer 应用成功：${user_ok}\n\n${root_log}"
}

show_gpu_status() {
    require_nvidia || return
    ui_textbox_from_command "当前 GPU 状态" bash -lc '
        echo "GPU 实时状态"
        echo "============"
        nvidia-smi --query-gpu=index,name,pstate,utilization.gpu,temperature.gpu,power.draw,power.limit,power.default_limit --format=csv
        echo
        echo "PCIe / 进程摘要"
        echo "================"
        nvidia-smi
    '
}

show_config_status() {
    refresh_gpu_data || return
    load_config

    local tmp idx hp limit service_state
    tmp="$(mktemp)"
    service_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    {
        echo "$APP_NAME v$VERSION"
        echo
        printf 'systemd 服务: %s\n' "${service_state:-未安装}"
        printf '配置文件: %s\n' "$CONFIG_FILE"
        printf '用户自启动: %s\n' "$USER_AUTOSTART"
        echo
        printf '%-6s %-46s %-12s %-16s\n' "GPU" "型号" "高性能" "功耗上限"
        printf '%-6s %-46s %-12s %-16s\n' "---" "----" "------" "--------"
        for idx in "${GPU_INDEXES[@]}"; do
            hp="自适应"
            [[ "${CFG_HIGH[$idx]:-0}" == "1" ]] && hp="最高性能"
            limit="${CFG_LIMIT[$idx]:-}"
            [[ -n "$limit" ]] && limit="${limit} W" || limit="驱动默认"
            printf '%-6s %-46.46s %-12s %-16s\n' "$idx" "${GPU_NAME[$idx]}" "$hp" "$limit"
        done
        echo
        echo "说明：GPU 编号基于当前 nvidia-smi 枚举顺序。更换插槽后请重新配置。"
    } > "$tmp"

    "$UI" --backtitle "$BACKTITLE" --title "配置与安装状态" --textbox "$tmp" 23 100
    rm -f "$tmp"
}

show_service_logs() {
    ui_textbox_from_command "systemd 服务与日志" bash -lc "
        echo '=== 服务状态 ==='
        systemctl status '${SERVICE_NAME}' --no-pager 2>&1 || true
        echo
        echo '=== 本次启动日志 ==='
        journalctl -u '${SERVICE_NAME}' -b --no-pager -n 100 2>&1 || true
        echo
        echo '=== PowerMizer 用户日志 ==='
        tail -n 100 '${USER_LOG}' 2>&1 || true
    "
}

reset_gpu_defaults() {
    require_nvidia || return 1

    local idx default
    for idx in "${GPU_INDEXES[@]}"; do
        default="${GPU_DEFAULT[$idx]}"
        if is_number "$default"; then
            sudo nvidia-smi -i "$idx" -pl "$default" || true
        fi
        if need_command nvidia-settings; then
            nvidia-settings -a "[gpu:${idx}]/GPUPowerMizerMode=0" >/dev/null 2>&1 || true
        fi
    done
}

uninstall_all() {
    refresh_gpu_data || true
    if ! ui_yesno "确认卸载" "将执行以下操作：\n\n• 停用并删除 systemd 服务\n• 删除 root 应用脚本和配置\n• 删除当前用户的 GNOME 自启动\n\n是否继续？"; then
        return
    fi

    if ui_yesno "恢复默认值" "卸载前是否尝试把所有 GPU 恢复为默认功耗，并将 PowerMizer 设为自适应？"; then
        reset_gpu_defaults || true
    fi

    sudo systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo rm -f "$SERVICE_FILE" "$ROOT_HELPER"
    sudo rm -rf "$CONFIG_DIR"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    rm -f "$USER_HELPER" "$USER_AUTOSTART"
    rm -rf "$USER_STATE_DIR"

    ui_msg "卸载完成" "服务、配置和当前用户的自启动文件已删除。"
}

about() {
    ui_msg "关于" "${APP_NAME} v${VERSION}\n\n功能：\n• 自动识别 NVIDIA GPU\n• 逐卡设置 PowerMizer 模式\n• 逐卡设置功耗上限\n• systemd 开机应用功耗限制\n• GNOME 登录后应用高性能模式\n• 查看状态、日志并完整卸载\n\n注意：更换 GPU 插槽后，编号可能改变，请重新配置。"
}

main_menu() {
    local choice
    while true; do
        choice="$(ui_menu \
            "$APP_NAME" \
            "请选择操作。建议顺序：配置 GPU → 安装/更新服务 → 查看状态。" \
            "1" "配置 GPU 高性能模式与功耗" \
            "2" "安装或更新 systemd 服务和自启动" \
            "3" "立即应用当前配置" \
            "4" "查看当前 GPU 状态" \
            "5" "查看配置与安装状态" \
            "6" "查看服务日志" \
            "7" "卸载服务并清理配置" \
            "8" "关于" \
            "0" "退出")" || break

        case "$choice" in
            1) configure_gpus ;;
            2) install_or_update ;;
            3) apply_now ;;
            4) show_gpu_status ;;
            5) show_config_status ;;
            6) show_service_logs ;;
            7) uninstall_all ;;
            8) about ;;
            0) break ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_ui
    main_menu
fi
