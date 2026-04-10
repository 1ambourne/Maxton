#!/usr/bin/env bash
# ==============================================================================
# Azure Ubuntu VM Generalization Script
# Azure Ubuntu VM 泛用化清理腳本
# ==============================================================================
#
# Purpose / 用途
# ------------------------------------------------------------------------------
# This script prepares an Azure Ubuntu virtual machine for generalization before
# creating a reusable image or snapshot. It removes system-unique identity data
# and provisioning artifacts so that newly created VMs can initialize correctly.
#
# 本腳本用於 Azure Ubuntu VM 在進行 generalization 與建立可重複使用的
# image / snapshot 前的清理作業。它會移除系統唯一性資料與佈署殘留資訊，
# 使後續由該映像建立的新 VM 能正確重新初始化。
#
# Main cleanup actions / 主要清理行為
# ------------------------------------------------------------------------------
# 1. Reset cloud-init execution state
# 2. Remove cloud-init cached state and logs
# 3. Clear machine-id
# 4. Remove SSH host keys
# 5. Deprovision Azure Linux Agent
#
# 1. 重設 cloud-init 執行狀態
# 2. 移除 cloud-init 快取與記錄
# 3. 清除 machine-id
# 4. 移除 SSH host keys
# 5. 執行 Azure Linux Agent deprovision
#
# High-risk warning / 高風險警告
# ------------------------------------------------------------------------------
# This script destroys system identity data. After execution, this VM must not
# continue to be used as a normal working machine. If deprovision is completed,
# the VM may no longer be suitable for direct operational use or login as-is.
# Use this only in an image-building workflow.
#
# 本腳本會破壞系統唯一性資料。執行後，此 VM 不應再作為一般工作機持續使用。
# 若執行到 deprovision 完成，該 VM 可能不再適合直接作為既有作業機持續登入或操作。
# 本腳本僅可用於 image 建置流程。
#
# Production restriction / 不可用於正式運行中的 Production VM
# ------------------------------------------------------------------------------
# Never run this script on an actively used production VM.
# 絕不可在正式運行中的 Production VM 上執行本腳本。
#
# Backup recommendation / 備份建議
# ------------------------------------------------------------------------------
# Always create a snapshot or backup before execution.
# 執行前務必先建立 snapshot 或備份。
#
# Execution modes / 執行模式
# ------------------------------------------------------------------------------
# dry-run : Show and log planned actions only; do not execute commands.
# safe    : Ask for confirmation before each step; execute only after approval.
# execute : Execute all steps directly.
#
# dry-run : 僅顯示並記錄將執行的動作，不實際執行。
# safe    : 每一步都要求人工確認後才執行。
# execute : 直接正式執行全部步驟。
#
# Mandatory logging / 強制記錄
# ------------------------------------------------------------------------------
# Logging is always enabled in all modes. Logs are written to both console and
# log file for auditability. Logging cannot be disabled.
#
# 所有模式皆強制啟用 logging。log 會同時輸出到 console 與 log file，
# 以滿足可審計需求，且不可停用。
#
# CLI options / CLI 參數
# ------------------------------------------------------------------------------
# --mode dry-run|safe|execute
# --log-path /path/to/logfile
# -h | --help
#
# Examples / 範例
# ------------------------------------------------------------------------------
# sudo bash azure-generalize.sh --mode dry-run
# sudo bash azure-generalize.sh --mode safe
# sudo bash azure-generalize.sh --mode execute --log-path /var/log/azure-generalize.log
#
# ==============================================================================

set -Eeuo pipefail

MODE="dry-run"
LOG_PATH="/var/log/azure-generalize.log"
SCRIPT_NAME="$(basename "$0")"
STEP_COUNTER=0
RUN_ID="$(date '+%Y%m%d%H%M%S')-$$"

readonly AZURE_CHASSIS_TAG="7783-7084-3265-9085-8269-3286-77"

# ------------------------------------------------------------------------------
# Logging / 記錄函式
# ------------------------------------------------------------------------------

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_msg() {
  local level="$1"
  local message="$2"
  local line
  line="$(printf '[%s] [%s] [%s] [run_id=%s] %s' "$(timestamp)" "$level" "$SCRIPT_NAME" "$RUN_ID" "$message")"
  echo "$line" | tee -a "$LOG_PATH" >/dev/null
}

die() {
  local message="$1"
  log_msg "ERROR" "$message"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  local failed_command="${3:-unknown}"
  log_msg "ERROR" "Script failed at line ${line_no}, exit_code=${exit_code}, command=${failed_command}"
  exit "$exit_code"
}

trap 'on_error $? ${LINENO} "${BASH_COMMAND}"' ERR

# ------------------------------------------------------------------------------
# Usage / 說明
# ------------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  sudo bash azure-generalize.sh --mode dry-run|safe|execute [--log-path /path/to/logfile]

Options:
  --mode       Execution mode: dry-run / safe / execute
  --log-path   Log file path (default: /var/log/azure-generalize.log)
  -h, --help   Show this help message
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing / 參數解析
# ------------------------------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "Missing value for --mode / 缺少 --mode 參數值"
        MODE="$2"
        shift 2
        ;;
      --log-path)
        [[ $# -ge 2 ]] || die "Missing value for --log-path / 缺少 --log-path 參數值"
        LOG_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument / 未知參數: $1"
        ;;
    esac
  done

  case "$MODE" in
    dry-run|safe|execute) ;;
    *)
      die "Invalid mode / 無效模式: ${MODE}. Allowed: dry-run | safe | execute"
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Environment checks / 環境檢查
# ------------------------------------------------------------------------------

check_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must run as root / 此腳本必須以 root 權限執行"
}

ensure_log_file() {
  local log_dir
  log_dir="$(dirname "$LOG_PATH")"

  if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir"
  fi

  touch "$LOG_PATH" || die "Cannot create or write log file / 無法建立或寫入 log 檔: $LOG_PATH"
}

check_command_exists() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found / 必要指令不存在: $cmd"
}

check_cloud_init() {
  check_command_exists "cloud-init"
}

check_waagent() {
  check_command_exists "waagent"
}

check_azure_vm() {
  local product_name=""
  local chassis_asset=""

  if [[ -r /sys/class/dmi/id/product_name ]]; then
    product_name="$(tr -d '\0' < /sys/class/dmi/id/product_name || true)"
  fi

  if [[ -r /sys/class/dmi/id/chassis_asset_tag ]]; then
    chassis_asset="$(tr -d '\0' < /sys/class/dmi/id/chassis_asset_tag || true)"
  fi

  if [[ "$product_name" != *"Virtual Machine"* && "$chassis_asset" != *"$AZURE_CHASSIS_TAG"* ]]; then
    die "Azure VM validation failed / Azure VM 環境檢查失敗: product_name='${product_name}', chassis_asset_tag='${chassis_asset}'"
  fi
}

preflight_checks() {
  check_root
  ensure_log_file
  log_msg "INFO" "Starting preflight checks / 開始前置檢查, mode=${MODE}, log_path=${LOG_PATH}"

  check_cloud_init
  check_waagent
  check_azure_vm

  log_msg "INFO" "Preflight checks passed / 前置檢查完成"
}

# ------------------------------------------------------------------------------
# Prompt / 互動確認
# ------------------------------------------------------------------------------

confirm_step() {
  local prompt="$1"
  local answer=""

  while true; do
    read -r -p "${prompt} Type yes to continue: " answer
    case "$answer" in
      yes) return 0 ;;
      no|"") return 1 ;;
      *)
        echo "Please type yes or no"
        ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Unified step execution / 統一步驟執行
# ------------------------------------------------------------------------------

run_step() {
  local step_name="$1"
  local command="$2"

  STEP_COUNTER=$((STEP_COUNTER + 1))

  log_msg "INFO" "STEP ${STEP_COUNTER} START: ${step_name}"
  log_msg "INFO" "STEP ${STEP_COUNTER} COMMAND: ${command}"

  case "$MODE" in
    dry-run)
      echo "[DRY-RUN] ${command}"
      log_msg "INFO" "STEP ${STEP_COUNTER} RESULT: dry-run"
      ;;
    safe)
      if confirm_step "[SAFE MODE] ${step_name}. "; then
        eval "$command"
        log_msg "INFO" "STEP ${STEP_COUNTER} RESULT: success"
      else
        log_msg "WARN" "STEP ${STEP_COUNTER} RESULT: skipped_by_user"
        die "Execution cancelled by user / 使用者已取消執行，停止於步驟: ${step_name}"
      fi
      ;;
    execute)
      eval "$command"
      log_msg "INFO" "STEP ${STEP_COUNTER} RESULT: success"
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Cleanup steps / 清理步驟
# ------------------------------------------------------------------------------

# Step 1
# 做什麼：
#   使用 cloud-init clean 清除 cloud-init 執行狀態。
# 為什麼：
#   確保新 VM 啟動時會重新執行 cloud-init 初始化。
# 不做風險：
#   新 VM 可能沿用舊 instance 的狀態，導致初始化不完整。
step_1_cloud_init_clean() {
  run_step \
    "Step 1 - Reset cloud-init state / 重設 cloud-init 狀態" \
    "cloud-init clean"
}

# Step 2
# 做什麼：
#   移除 /var/lib/cloud 內的 cloud-init 快取與 instance state。
# 為什麼：
#   避免新 VM 繼承舊 VM 的 metadata、cache 與初始化痕跡。
# 不做風險：
#   後續 VM 可能出現部署不一致、初始設定未重跑等問題。
step_2_remove_cloud_state() {
  run_step \
    "Step 2 - Remove cloud-init cached state / 清除 cloud-init 狀態資料夾" \
    "rm -rf /var/lib/cloud/*"
}

# Step 3
# 做什麼：
#   移除 cloud-init 相關 log 檔案。
# 為什麼：
#   避免新 VM 保留舊 VM 的初始化記錄，降低審查與除錯混淆。
# 不做風險：
#   映像內殘留舊 VM 操作痕跡，不利後續判讀與稽核。
step_3_remove_cloud_logs() {
  run_step \
    "Step 3 - Remove cloud-init logs / 清除 cloud-init 記錄" \
    "rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log && rm -f /var/log/cloud-init*.log || true"
}

# Step 4
# 做什麼：
#   清空 /etc/machine-id，並移除 /var/lib/dbus/machine-id（若存在）。
# 為什麼：
#   讓新 VM 開機時產生新的 machine identity。
# 不做風險：
#   多台 VM 可能共用相同 machine-id，影響系統識別與管理。
step_4_clear_machine_id() {
  run_step \
    "Step 4 - Clear machine-id / 清除 machine-id" \
    ": > /etc/machine-id && rm -f /var/lib/dbus/machine-id"
}

# Step 5
# 做什麼：
#   刪除系統目前的 SSH host keys。
# 為什麼：
#   確保新 VM 於首次啟動時重新產生自己的 host keys。
# 不做風險：
#   不同 VM 可能共用相同 SSH host key，造成嚴重安全風險。
step_5_remove_ssh_host_keys() {
  run_step \
    "Step 5 - Remove SSH host keys / 移除 SSH host keys" \
    "find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' -delete && find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key.pub' -delete"
}

# Step 6
# 做什麼：
#   使用 waagent 執行 deprovision，移除 Azure provisioning 狀態。
# 為什麼：
#   讓此 VM 可作為 Azure 映像來源，避免新 VM 帶入舊實例狀態。
# 不做風險：
#   後續由映像建立的 VM 可能繼承不應保留的 Azure agent 與帳號狀態。
# 注意：
#   此步驟風險最高，執行後原 VM 不應再作為一般機器使用。
step_6_waagent_deprovision() {
  run_step \
    "Step 6 - Deprovision Azure agent / 執行 Azure Agent 去佈署清理" \
    "waagent -force -deprovision"
}

# ------------------------------------------------------------------------------
# Main / 主流程
# ------------------------------------------------------------------------------

main() {
  parse_args "$@"
  preflight_checks

  log_msg "INFO" "Azure Ubuntu VM generalization script started / 腳本開始執行"

  step_1_cloud_init_clean
  step_2_remove_cloud_state
  step_3_remove_cloud_logs
  step_4_clear_machine_id
  step_5_remove_ssh_host_keys
  step_6_waagent_deprovision

  log_msg "INFO" "All steps completed / 所有步驟執行完成"
  log_msg "INFO" "This VM should now be shut down and captured as image or snapshot / 建議立即關機並建立 image 或 snapshot"
}

main "$@"