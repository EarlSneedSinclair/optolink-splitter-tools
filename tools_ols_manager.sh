#!/usr/bin/env bash
#
# Optolink-Splitter Manager
# Copyright 2025-2026 EarlSneedSinclair
# Version: 1.0
#
# Usage:
#   chmod +x tools_ols_manager.sh
#   ./tools_ols_manager.sh
#
# Description:
#   Interactive service manager for optolink-splitter
#   Control service, view logs, run manual start

set -euo pipefail

# =====================================
# DO NOT EDIT BELOW THIS LINE
# =====================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF_FILE="${SCRIPT_DIR}/tools_ols_manager.conf"
CONF_EXAMPLE="${SCRIPT_DIR}/tools_ols_manager.conf.example"

# =====================================
# Config file handling
# =====================================

CONF_VARS=(
    SERVICE_NAME
    VENV_DIR
    OLS_FILE
    LOG_LINES
)

check_conf() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        echo "ERROR: Config file not found: ${CONF_FILE}"
        echo ""
        echo "  Create it by copying the example file:"
        echo "    cp ${CONF_EXAMPLE} ${CONF_FILE}"
        echo "  Then edit it to match your setup."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${CONF_FILE}"

    local missing=()
    for var in "${CONF_VARS[@]}"; do
        if ! grep -qE "^${var}=" "${CONF_FILE}"; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: The following settings are missing from ${CONF_FILE}:"
        echo ""
        for var in "${missing[@]}"; do
            echo "  - ${var}"
        done
        echo ""
        echo "  Check ${CONF_EXAMPLE} for reference."
        exit 1
    fi
}

# =====================================
# Initialisation
# =====================================

# Sudo detection
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

# Colors (only if terminal)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
else
  C_RESET="" ; C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_DIM=""
fi

# =====================================
# Helper functions (used everywhere)
# =====================================

print_cmd() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
}

run() {
  print_cmd "$@"
  "$@"
}

run_sc() {
  if [[ -n "$SUDO" ]]; then
    run sudo systemctl "$@"
  else
    run systemctl "$@"
  fi
}

run_jc() {
  if [[ -n "$SUDO" ]]; then
    run sudo journalctl "$@"
  else
    run journalctl "$@"
  fi
}

run_follow() {
  local pid
  print_cmd "$@"
  "$@" &
  pid=$!

  local oldtrap
  oldtrap="$(trap -p INT || true)"
  trap 'kill "$pid" 2>/dev/null; true' INT
  wait "$pid" 2>/dev/null || true

  if [[ -n "$oldtrap" ]]; then
    eval "$oldtrap"
  else
    trap - INT
  fi
  echo
}

run_jc_follow() {
  if [[ -n "$SUDO" ]]; then
    run_follow sudo journalctl "$@"
  else
    run_follow journalctl "$@"
  fi
}

pause() {
  echo
  read -n1 -s -r -p "Press any key to continue..." _
  echo ""
  echo
}

sc_safe() {
  run_sc "$@" || true
  pause
}

get_service_status() {
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "active (running)"
  else
    echo "inactive"
  fi
}

service_summary() {
  local active enabled sub
  active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")"
  enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo "unknown")"
  sub="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>/dev/null || echo "")"

  case "$active" in
    active)   printf "%sRUNNING%s" "$C_GREEN"  "$C_RESET" ;;
    inactive) printf "%sSTOPPED%s" "$C_YELLOW" "$C_RESET" ;;
    failed)   printf "%sFAILED%s"  "$C_RED"    "$C_RESET" ;;
    *)        printf "%sUNKNOWN%s" "$C_DIM"    "$C_RESET" ;;
  esac

  if [[ -n "${sub// }" ]] && [[ "$sub" != "$active" ]]; then
    printf " %s(%s)%s" "$C_DIM" "$sub" "$C_RESET"
  fi

  case "$enabled" in
    enabled)  printf " %s[enabled]%s"  "$C_DIM" "$C_RESET" ;;
    disabled) printf " %s[disabled]%s" "$C_DIM" "$C_RESET" ;;
    *)        printf " %s[%s]%s"       "$C_DIM" "$enabled" "$C_RESET" ;;
  esac
}

# =====================================
# Main menu
# =====================================

menu_main() {
  local summary
  summary="$(service_summary)"
  clear
  echo "========================================"
  echo "  Optolink-Splitter Manager"
  echo "========================================"
  echo ""
  echo "Service: ${SERVICE_NAME}"
  echo "Status:  ${summary}"
  echo ""
  echo "1) Logs            (submenu)"
  echo "2) Service Control (submenu: restart/start/stop/...)"
  echo "3) Service Info    (submenu: status/errors)"
  echo "4) Manual Start    (exits menu → starts splitter (venv))"
  echo "5) Venv Shell      (exits menu → enters venv shell)"
  echo ""
  echo "s) Settings        (submenu: view/edit)"
  echo ""
  echo "q) Quit"
  echo
}

# =====================================
# 1) Logs
# =====================================

menu_logs() {
  local summary
  summary="$(service_summary)"
  clear
  echo "========================================"
  echo "  Logs"
  echo "========================================"
  echo ""
  echo "Service: ${SERVICE_NAME}"
  echo "Status:  ${summary}"
  echo ""
  echo "1) Follow (last ${LOG_LINES})          (Ctrl+C to exit)"
  echo "2) Follow with timestamps      (Ctrl+C to exit)"
  echo "3) Last N (no follow)"
  echo ""
  echo "q) Back"
  echo
}

run_logs_menu() {
  while true; do
    menu_logs
    read -n1 -s -r -p "Choose [1-3, q]: " opt
    echo ""

    case "$opt" in
      q|Q) return 0 ;;
      1) run_jc_follow -u "$SERVICE_NAME" -f -n "$LOG_LINES" ;;
      2) run_jc_follow -u "$SERVICE_NAME" -f -n "$LOG_LINES" -o short-iso ;;
      3)
        printf "How many lines (N): "
        read -r n
        if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
          echo "Invalid N."
          pause
          continue
        fi
        run_jc -u "$SERVICE_NAME" --no-pager -n "$n" || true
        pause
        ;;
      *)
        echo "Invalid choice: $opt"
        pause
        ;;
    esac
  done
}

# =====================================
# 2) Service Control
# =====================================

menu_service() {
  local summary
  summary="$(service_summary)"
  clear
  echo "========================================"
  echo "  Service Control"
  echo "========================================"
  echo ""
  echo "Service: ${SERVICE_NAME}"
  echo "Status:  ${summary}"
  echo ""
  echo "1) Restart"
  echo "2) Start"
  echo "3) Stop"
  echo ""
  echo "4) Enable"
  echo "5) Disable"
  echo ""
  echo "q) Back"
  echo
}

run_service_menu() {
  while true; do
    menu_service
    read -n1 -s -r -p "Choose [1-5, q]: " opt
    echo ""

    case "$opt" in
      q|Q) return 0 ;;
      1) sc_safe restart "$SERVICE_NAME" ;;
      2) sc_safe start   "$SERVICE_NAME" ;;
      3) sc_safe stop    "$SERVICE_NAME" ;;
      4) sc_safe enable  "$SERVICE_NAME" ;;
      5) sc_safe disable "$SERVICE_NAME" ;;
      *)
        echo "Invalid choice: $opt"
        pause
        ;;
    esac
  done
}

# =====================================
# 3) Service Info
# =====================================

menu_status() {
  local summary
  summary="$(service_summary)"
  clear
  echo "========================================"
  echo "  Service Info"
  echo "========================================"
  echo ""
  echo "Service: ${SERVICE_NAME}"
  echo "Status:  ${summary}"
  echo ""
  echo "1) systemctl status      (detailed)"
  echo "2) is-active / is-enabled (quick)"
  echo "3) Last errors           (journalctl -p err..alert)"
  echo "4) systemctl cat         (show unit file)"
  echo ""
  echo "q) Back"
  echo
}

run_status_menu() {
  while true; do
    menu_status
    read -n1 -s -r -p "Choose [1-4, q]: " opt
    echo ""

    case "$opt" in
      q|Q) return 0 ;;
      1) run_sc status "$SERVICE_NAME" --no-pager || true; pause ;;
      2)
        systemctl is-active  "$SERVICE_NAME" || true
        systemctl is-enabled "$SERVICE_NAME" || true
        pause
        ;;
      3) run_jc -u "$SERVICE_NAME" -p err..alert --no-pager -n 200 || true; pause ;;
      4) run_sc cat "$SERVICE_NAME" || true; pause ;;
      *)
        echo "Invalid choice: $opt"
        pause
        ;;
    esac
  done
}

# =====================================
# 4) Manual Start
# =====================================

ensure_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Venv dir not found: '$VENV_DIR' (set VENV_DIR in ${CONF_FILE})."
    return 1
  fi
  if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    echo "Venv activate not found: '$VENV_DIR/bin/activate'."
    return 1
  fi
}

run_manual_start() {
  ensure_venv || { pause; return 0; }
  if [[ ! -f "$OLS_FILE" ]]; then
    echo "Manual script not found: '$OLS_FILE' (set OLS_FILE in ${CONF_FILE})."
    pause
    return 0
  fi
  clear
  echo "Leaving menu and starting Optolink-Splitter (in venv)..."
  echo "  Press 'CTRL'+'C' to stop Optolink-Splitter"
  echo "  Script: ${OLS_FILE}"
  pause
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  exec python "$OLS_FILE"
}

# =====================================
# 5) Venv Shell
# =====================================

run_venv_shell() {
  ensure_venv || { pause; return 0; }
  clear
  echo "Leaving menu and entering venv shell..."
  echo "  Venv: ${VENV_DIR}"
  echo "  Type 'exit' to return to your previous shell."
  pause
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  exec bash -i
}

# =====================================
# s) Settings
# =====================================

run_settings_menu() {
  while true; do
    clear
    echo "========================================"
    echo "  Settings"
    echo "========================================"
    echo ""
    echo "1) View settings"
    echo "2) Edit settings"
    echo ""
    echo "q) Back"
    echo ""
    read -n1 -s -r -p "Choose [1-2, q]: " opt
    echo ""

    case "$opt" in
      q|Q) return 0 ;;
      1) view_settings ;;
      2) edit_settings ;;
      *)
        echo "Invalid choice: $opt"
        pause
        ;;
    esac
  done
}

view_settings() {
  clear
  echo "========================================"
  echo "  Settings – View"
  echo "========================================"
  echo ""
  echo "Script:"
  echo "  Location:                  ${SCRIPT_DIR}/${SCRIPT_NAME}"
  echo "  Config file:               ${CONF_FILE}"
  echo ""
  echo "Service:"
  echo "  Name:                       ${SERVICE_NAME}"
  echo "  Status:                     $(get_service_status)"
  echo ""
  echo "Paths:"
  echo "  Venv directory:             ${VENV_DIR}"
  echo "  Optolink-Splitter script:   ${OLS_FILE}"
  echo ""
  echo "Configuration:"
  echo "  Default logs:               ${LOG_LINES} lines"
  echo ""
  read -n1 -s -p "Press any key to continue..."
  echo ""
}

edit_settings() {
  clear

  if command -v nano &>/dev/null; then
    nano "${CONF_FILE}"
  elif command -v vim &>/dev/null; then
    vim "${CONF_FILE}"
  elif command -v vi &>/dev/null; then
    vi "${CONF_FILE}"
  else
    echo "ERROR: No text editor found (nano, vim, vi)!"
    read -n1 -s -p "Press any key to continue..."
    echo ""
    return
  fi

  check_conf
}

# =====================================
# Startup checks
# =====================================

check_conf

# =====================================
# Main loop
# =====================================

while true; do
  menu_main
  read -n1 -s -r -p "Choose [1-5, s, q]: " choice
  echo ""

  case "$choice" in
    q|Q) clear; echo "Goodbye!"; exit 0 ;;
    1) run_logs_menu ;;
    2) run_service_menu ;;
    3) run_status_menu ;;
    4) run_manual_start ;;
    5) run_venv_shell ;;
    s|S) run_settings_menu ;;
    *)
      echo "Invalid choice: $choice"
      pause
      ;;
  esac
done
