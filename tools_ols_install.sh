#!/usr/bin/env bash
#
# Optolink-Splitter Installer
# Copyright 2026 EarlSneedSinclair
# Version: 1.0
#
# Flags:
#   --dry-run    Print commands without executing them (for testing output)
#
# Distribution Compatibility:
#   Raspberry Pi OS (recommended)
#   Should work on any Debian/Ubuntu-based system.
#   Other distros: apt-get steps may need manual intervention.
#
# Usage:
#   chmod +x tools_ols_install.sh
#   sudo ./tools_ols_install.sh
#
# Description:
#   Interactive step-by-step installer for optolink-splitter.
#   Idempotent; safe to run multiple times.
#   Logs all output to install.log.

set -euo pipefail

# =====================================
# Default settings
# =====================================

INSTALL_PATH="/opt/optolink-splitter"          # installation directory
VENV_DIR="myvenv"                              # virtual environment directory
SERVICE_NAME="optolink-splitter"               # systemd service name
SERVICE_USER="optolink"                        # dedicated system user
PYTHON_CMD="python3"                           # python command
GITHUB_URL="https://github.com/philippoo66/optolink-splitter/archive/refs/heads/main.tar.gz"
MAIN_SCRIPT="optolinkvs2_switch.py"            # Optolink-Splitter script

# =====================================
# DO NOT EDIT BELOW THIS LINE
# =====================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install-optolink-splitter.log"
STEP_TOTAL=10

# =====================================
# Flags
# =====================================

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# =====================================
# Colors (only if terminal; before tee redirect)
# =====================================

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
# Logging; tee everything to install.log
# =====================================

exec > >(tee >(sed 's/\x1b\[[0-9;]*[mGKHJsu]//g; s/\x1b[=>]//g' >> "$LOG_FILE")) 2>&1

# =====================================
# Summary tracking
# =====================================

declare -A STEP_STATUS   # done / already / skipped / failed
declare -A STEP_LABEL

# =====================================
# Output helpers
# =====================================

# Normal text
info() { echo "  $*"; }

# Divider
div()  { echo "  ----------------------------------------"; }

# Commands being run
print_cmd() {
  printf "  ${C_DIM}+"
  printf ' %q' "$@"
  printf "${C_RESET}
"
}

# Result lines; always: blank + div + blank + result + blank
ok()   { echo ""; div; echo ""; echo "  ${C_GREEN}✓ $*${C_RESET}"; echo ""; }
skip() { echo ""; div; echo ""; echo "  ${C_YELLOW}– $*${C_RESET}"; echo ""; }
warn() { echo ""; echo "  ${C_YELLOW}! $*${C_RESET}"; echo ""; }
err()  { echo ""; div; echo ""; echo "  ${C_RED}✗ $*${C_RESET}"; echo ""; }

run() {
  print_cmd "$@"
  if [[ "$DRY_RUN" == false ]]; then
    "$@"
  fi
}

# =====================================
# Interaction helpers
# =====================================

pause() {
  read -n1 -s -r -p "  Press any key to continue..." _
  echo ""
  echo ""
}

# confirm: div → blank → QUESTION → blank → [Y/n] or [y/N] → blank → Your choice → blank
confirm() {
  local prompt="$1"
  local hint="${2:-}"
  local default="${3:-Y}"
  local answer
  echo ""
  div
  echo ""
  echo "  ${C_YELLOW}${prompt}${C_RESET}"
  if [[ -n "$hint" ]]; then
    echo "  (${hint})"
  fi
  echo ""
  while true; do
    if [[ "$default" == "Y" ]]; then
      read -r -p "  [Y/n] > " answer
    else
      read -r -p "  [y/N] > " answer
    fi
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]*) echo ""; echo "  Your choice: Yes"; echo ""; return 0 ;;
      [Nn]*) echo ""; echo "  Your choice: No";  echo ""; return 1 ;;
      *) echo "  Please answer Y or n." ;;
    esac
  done
}

# prompt_value: div → blank → LABEL → blank → hint → blank → > → blank → Your choice → blank
# Display to stderr, return value on stdout
prompt_value() {
  local label="$1"
  local default="$2"
  local hint="${3:-}"
  local answer
  echo "" >&2
  div >&2
  echo "" >&2
  echo "  ${C_YELLOW}${label}${C_RESET}" >&2
  echo "" >&2
  if [[ -n "$hint" ]]; then
    info "(${hint})" >&2
  fi
  echo "" >&2
  read -r -p "  [Default: ${default}] > " answer </dev/tty
  echo "" >&2
  echo "  Your choice: ${answer:-$default}" >&2
  echo "${answer:-$default}"
}

# =====================================
# Step helpers
# =====================================

step_header() {
  local num="$1"
  local title="$2"
  clear
  echo "========================================"
  echo "  Optolink-Splitter Installer"
  echo "========================================"
  echo ""
  echo "  Step ${num}/${STEP_TOTAL}; ${title}"
  echo "  ----------------------------------------"
  echo ""
}

step_info() {
  local summary="$1"
  info "${summary}"
  echo ""
}

# Step results: div → blank → result → blank
step_done()    { STEP_STATUS["$1"]="done";    ok "Done"; }
step_skipped() { STEP_STATUS["$1"]="skipped"; skip "Skipped"; }
step_already() { STEP_STATUS["$1"]="already"; }

# =====================================
# Utilities
# =====================================

# =====================================
# Summary
# =====================================

print_summary() {
  clear
  echo "========================================"
  echo "  Optolink-Splitter Installer"
  echo "========================================"
  echo ""
  echo "  Installation Summary"
  echo "  ----------------------------------------"
  echo ""
  for key in serial ttyama download python venv_pkg user serial_grp venv deps service; do
    local label="${STEP_LABEL[$key]:-$key}"
    local status="${STEP_STATUS[$key]:-unknown}"
    case "$status" in
      done)    printf "  ${C_GREEN}✓${C_RESET}  %-40s ${C_GREEN}done${C_RESET}
"      "$label" ;;
      already) printf "  ${C_DIM}✓  %-40s already done${C_RESET}
"                    "$label" ;;
      skipped) printf "  ${C_YELLOW}–${C_RESET}  %-40s ${C_YELLOW}skipped${C_RESET}
" "$label" ;;
      failed)  printf "  ${C_RED}✗${C_RESET}  %-40s ${C_RED}FAILED${C_RESET}
"        "$label" ;;
      *)       printf "  ${C_DIM}?  %-40s unknown${C_RESET}
"                          "$label" ;;
    esac
  done
  echo ""
  info "Log saved to: ${LOG_FILE}"
  echo ""
}

# =====================================
# Register step labels
# =====================================

STEP_LABEL["serial"]="Serial port (optional)"
STEP_LABEL["ttyama"]="ttyAMA0 setup (optional)"
STEP_LABEL["download"]="Download optolink-splitter"
STEP_LABEL["python"]="Python 3 installation"
STEP_LABEL["venv_pkg"]="python3-venv package"
STEP_LABEL["user"]="System user '${SERVICE_USER}'"
STEP_LABEL["serial_grp"]="Serial group membership"
STEP_LABEL["venv"]="Virtual environment (${VENV_DIR})"
STEP_LABEL["deps"]="Python dependencies"
STEP_LABEL["service"]="systemd service"

# =====================================
# Header
# =====================================

echo ""
echo "========================================"
echo "  Optolink-Splitter Installer"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

if [[ "$DRY_RUN" == true ]]; then
  warn "DRY-RUN MODE; no changes will be made"
fi

# =====================================
# STEP 0; Welcome
# =====================================

step_header 0 "Welcome"

# -- info --
step_info   "This installer will guide you through the setup of Optolink-Splitter
  step by step. Each step can be skipped or confirmed individually."

info "What can be installed:"
echo ""
info "  - Current Optolink-Splitter version"
info "  - Python3 & Python virtual environment with required packages"
info "  - systemd service for automatic startup"
info "  - Service User and Group"
echo ""
info "Steps that require a reboot (serial port/Vitoconnect users only):"
echo ""
info "  - Serial port setup (raspi-config)"
info "  - ttyAMA0 / Bluetooth configuration"
echo ""
info "Compatibility:"
echo ""
info "  This installer is designed for Raspberry Pi OS and should work on"
info "  most Debian-based systems. On other distributions, the package"
info "  installation steps (apt-get) may fail. In that case, install"
info "  Python 3 and python3-venv manually and re-run. All other steps"
info "  will work regardless of distribution."
echo ""
info "Before you continue, make sure you have:"
echo ""
info "  - A working internet connection"
info "  - Root access (sudo)"

# -- ask --
if ! confirm "READY TO BEGIN?"; then
  echo ""
  info "Installation cancelled. Run the installer again whenever you are ready."
  echo ""
  exit 0
fi

# -- check --
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && [[ "$DRY_RUN" == false ]]; then
  err "This installer must be run as root."
  info "Usage: sudo ./install.sh"
  info "Tip:   ./install.sh --dry-run   (preview without root)"
  exit 1
fi

info "Checking internet connection..."
if ping -c4 -W3 github.com >/dev/null 2>&1; then
  ok "Internet connection available"
else
  warn "No internet connection detected."
  info "The download step will fail without internet access."
fi

# =====================================
# STEP 1; Serial port (optional, RPi)
# =====================================

step_header 1 "Serial Port Setup (optional)"

# -- info --
step_info \
  "On Raspberry Pi the serial port is used by the login console by default.
  To use a device connected via serial (e.g. Vitoconnect), you need to
  disable the console and enable the serial port hardware first."

info "More information in our Wiki:"
info "https://github.com/philippoo66/optolink-splitter/wiki/050-Prepare:-enable-serial-port,-disable-serial-console"
echo ""

info "Required only if connecting Vitoconnect or a device via serial port."
info "Not needed if you use USB only."

# -- ask --
if confirm "ENABLE SERIAL PORT NOW? (Raspberry Pi only)" "only required for Vitoconnect / serial port; not needed for USB" "N"; then
  echo ""
  info "Please complete the following steps manually:"
  echo ""
  info "  sudo raspi-config"
  info "  → Interface Options → Serial Port"
  info "  → Login shell over serial?  → No"
  info "  → Serial port hardware?     → Yes"
  warn "A reboot is required before the serial port changes take effect."
  info "Complete the steps above, then reboot and re-run this installer."
  echo ""
  warn "Complete the manual steps above, then reboot and re-run this installer."
  echo ""
  exit 0
else
  step_skipped "serial"
  info "You can enable the serial port manually later if needed."
fi

pause

# =====================================
# STEP 2; ttyAMA0 setup (optional)
# =====================================

step_header 2 "ttyAMA0 Setup (optional)"

# -- info --
step_info \
  "On Raspberry Pi 3/4, using ttyS0 can cause a termios error when the port
  is opened more than once. The fix is to use ttyAMA0 instead, which requires
  freeing it from Bluetooth first."

info "More information in our Wiki:"
info "https://github.com/philippoo66/optolink-splitter/wiki/520-termios.error:-(22,-'Invalid-argument')"
echo ""

info "Required only if connecting Vitoconnect or a device via serial port."
info "Not needed if you use USB only."
echo ""
info "If necessary, please complete the steps above, then reboot and re-run this installer."

# -- ask --
if confirm "PLEASE CONFIRM!" "only required for Vitoconnect / serial port; not needed for USB" "N"; then
  warn "Complete the manual steps above, then reboot and re-run this installer."
  exit 0
else
  step_skipped "ttyama"
fi

pause

# =====================================
# STEP 3; Download
# =====================================

step_header 3 "Download Optolink-Splitter"

# -- info --
step_info \
  "The source code will now be downloaded from GitHub and extracted to the install directory." \
  "https://github.com/philippoo66/optolink-splitter"

# -- input --
INSTALL_PATH="$(prompt_value \
  "CHOOSE INSTALLATION DIRECTORY" \
  "$INSTALL_PATH" \
  "Recommendation to leave as default")"

# -- check / run --
if [[ -d "$INSTALL_PATH" ]]; then
  ok "Directory already exists: ${INSTALL_PATH}"
  step_already "download"
else
  echo ""
  info "Downloading from GitHub..."
  TMP_TAR="$(mktemp /tmp/optolink-splitter-XXXXXX.zip)"
  run wget -q --show-progress -O "$TMP_TAR" "$GITHUB_URL"
  echo ""
  info "Extracting..."
  TMP_DIR="$(mktemp -d /tmp/optolink-splitter-XXXXXX)"
  run tar -xzf "$TMP_TAR" -C "$TMP_DIR"
  if [[ "$DRY_RUN" == false ]]; then
    EXTRACTED_DIR="$(find "$TMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
    run mv "$EXTRACTED_DIR" "$INSTALL_PATH"
  fi
  run rm -f "$TMP_TAR"
  run rm -rf "$TMP_DIR"
  step_done "download"
fi

pause

# =====================================
# STEP 4; Python 3
# =====================================

step_header 4 "Python 3"

# -- info --
step_info \
  "Python 3 is required to run Optolink-Splitter. Checking if it is installed."

# -- check / run --
if command -v "$PYTHON_CMD" >/dev/null 2>&1; then
  PY_VERSION="$("$PYTHON_CMD" --version 2>&1)"
  ok "Python already installed: ${PY_VERSION}"
  step_already "python"
else
  warn "Python 3 not found."
  if confirm "INSTALL PYTHON 3?"; then
    if command -v apt-get >/dev/null 2>&1; then
      run apt-get install -y python3
      step_done "python"
    else
      err "apt-get not found. Please install Python 3 manually and re-run."
      STEP_STATUS["python"]="failed"
      print_summary
      exit 1
    fi
  else
    step_skipped "python"
    warn "Python 3 is required. The installation cannot continue without it."
    print_summary
    exit 1
  fi
fi

pause

# =====================================
# STEP 5; python3-venv
# =====================================

step_header 5 "python3-venv package"

# -- info --
step_info \
  "Installs the package to create Python virtual environments
  which isolates the project's packages from the system Python.
  This is best practise on most modern Debian/Ubuntu systems."

info "More information in our Wiki:"
info "https://github.com/philippoo66/optolink-splitter/wiki/510-error:-externally%E2%80%90managed%E2%80%90environment-%E2%80%90%E2%80%90-venv"
echo ""

# -- check / run --
if "$PYTHON_CMD" -c "import ensurepip" >/dev/null 2>&1; then
  ok "python3-venv is already available"
  step_already "venv_pkg"
else
  echo ""
  div
  warn "python3-venv not found. Installing..."
  if command -v apt-get >/dev/null 2>&1; then
    run apt-get install -y python3-venv
    step_done "venv_pkg"
  else
    err "apt-get not found. Please install python3-venv manually and re-run."
    STEP_STATUS["venv_pkg"]="failed"
    print_summary
    exit 1
  fi
fi

pause

# =====================================
# STEP 6; Service user
# =====================================

step_header 6 "Service User"

# -- info --
step_info \
  "Creates a dedicated user '${SERVICE_USER}' to run the service.
  It has no login shell and no home directory."

# -- check / ask / run --
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  ok "User '${SERVICE_USER}' already exists"
  step_already "user"
else
  if confirm "CREATE SERVICE USER '${SERVICE_USER}'?" "recommended; more secure than running as root or pi"; then
    run useradd -r -s /usr/sbin/nologin -M "$SERVICE_USER"
    step_done "user"
  else
    step_skipped "user"
    echo ""
    div
    warn "Without a dedicated user the service will not work as configured."
  fi
fi

if id -u "$SERVICE_USER" >/dev/null 2>&1 && [[ -d "$INSTALL_PATH" ]]; then
  if [[ "$(stat -c '%U' "$INSTALL_PATH")" == "$SERVICE_USER" ]]; then
    ok "Ownership of ${INSTALL_PATH} already correct"
  else
    run chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_PATH"
    ok "Ownership of ${INSTALL_PATH} set to ${SERVICE_USER}"
  fi
fi

pause

# =====================================
# STEP 7; Serial group
# =====================================

step_header 7 "Serial Group"

# -- info --
step_info \
  "Makes service user a member of the serial group to access the port.
  On Debian/Raspberry Pi this is 'dialout', on Arch-based systems 'uucp'."

# -- input --
if getent group dialout >/dev/null 2>&1; then
  DETECTED_GROUP="dialout"
elif getent group uucp >/dev/null 2>&1; then
  DETECTED_GROUP="uucp"
else
  DETECTED_GROUP="dialout"
fi
info "Detected serial group: ${DETECTED_GROUP}"

SERIAL_GROUP="$(prompt_value \
  "SERIAL GROUP" \
  "$DETECTED_GROUP" \
  "Recommendation to leave as default unless your system uses a different group")"

# -- check / ask / run --
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  if groups "$SERVICE_USER" 2>/dev/null | grep -qw "$SERIAL_GROUP"; then
    ok "User '${SERVICE_USER}' is already in group '${SERIAL_GROUP}'"
    step_already "serial_grp"
  else
    if confirm "ADD '${SERVICE_USER}' TO GROUP '${SERIAL_GROUP}'?"; then
      run usermod -a -G "$SERIAL_GROUP" "$SERVICE_USER"
      step_done "serial_grp"
    else
      step_skipped "serial_grp"
      echo ""
      div
      warn "Serial port access may not work without group membership."
    fi
  fi
else
  echo ""
  div
  warn "User '${SERVICE_USER}' does not exist; skipping group assignment."
  step_skipped "serial_grp"
  info "This will be resolved if you re-run the installer after creating the user."
fi

pause

# =====================================
# STEP 8; Virtual environment
# =====================================

step_header 8 "Virtual Environment"

# -- info --
step_info \
  "Creates an isolated Python environment (${VENV_DIR}) inside the install directory.
  All required packages will be installed here, separate from the system Python.
  This is best practise on most modern Debian/Ubuntu systems."

info "More information in our Wiki:"
info "https://github.com/philippoo66/optolink-splitter/wiki/510-error:-externally%E2%80%90managed%E2%80%90environment-%E2%80%90%E2%80%90-venv"
echo ""

# -- input --
VENV_DIR="$(prompt_value \
  "VIRTUAL ENVIRONMENT NAME" \
  "$VENV_DIR" \
  "Recommendation to leave as default")"

VENV_PATH="${INSTALL_PATH}/${VENV_DIR}"
info "Path: ${VENV_PATH}"

# -- check --
if [[ -d "$VENV_PATH" && -f "${VENV_PATH}/bin/activate" ]]; then
  ok "Virtual environment already exists"
  step_already "venv"
else
  # -- run --
  echo ""
  info "Creating virtual environment..."
  run "$PYTHON_CMD" -m venv "$VENV_PATH"
  run chown -R "${SERVICE_USER}:${SERVICE_USER}" "$VENV_PATH" 2>/dev/null || true
  step_done "venv"
fi

pause

# =====================================
# STEP 9; Python dependencies
# =====================================

step_header 9 "Python Dependencies"

# -- info --
step_info \
  "Installs the required Python packages into the virtual environment:
  pyserial ; serial port communication with the heating system
  paho-mqtt; publishing data to an MQTT broker"

# -- input --
PIP="${VENV_PATH}/bin/pip"

# -- ask / run --
if confirm "INSTALL / UPGRADE PYTHON PACKAGES?"; then
  run "$PIP" install -q --upgrade pip setuptools wheel
  run "$PIP" install -q pyserial paho-mqtt
  step_done "deps"
else
  step_skipped "deps"
fi

pause

# =====================================
# STEP 10; systemd service
# =====================================

step_header 10 "systemd Service"

# -- info --
step_info \
  "Installs a systemd service for Optolink-Splitter. The service handles
  automatic startup on boot and restarts on failure. Even if you plan to
  start it manually for now, having the service file in place makes it
  easy to enable later."

info "More information in our Wiki:"
info "https://github.com/philippoo66/optolink-splitter/wiki/120-optolinkvs2_switch-automatisch-starten"
echo ""

# -- input --
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
info "Service file: ${SERVICE_FILE}"

# -- check --
if [[ -f "$SERVICE_FILE" ]]; then
  echo ""
  div
  warn "Service file already exists."
  if ! confirm "OVERWRITE EXISTING SERVICE FILE?"; then
    ok "Service file kept as is"
    step_already "service"
    pause
  fi
fi

# -- run --
if [[ "$DRY_RUN" == true ]]; then
  print_cmd cat ">" "$SERVICE_FILE"
  info "  [Unit]    Description=Optolink-Splitter  After=network-online.target"
  info "  [Service] User=${SERVICE_USER}  ExecStart=${VENV_PATH}/bin/python ${INSTALL_PATH}/${MAIN_SCRIPT}"
  info "  [Install] WantedBy=multi-user.target"
else
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Optolink-Splitter Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
SupplementaryGroups=${SERIAL_GROUP}
WorkingDirectory=${INSTALL_PATH}
Environment="PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${VENV_PATH}/bin/python ${INSTALL_PATH}/${MAIN_SCRIPT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
fi

ok "Service file written"

if [[ "$DRY_RUN" == false ]]; then
  answer=""
  echo ""
  div
  echo ""
  echo "  ${C_YELLOW}VIEW SERVICE FILE?${C_RESET}"
  echo ""
  while true; do
    read -r -p "  [y/N] > " answer
    answer="${answer:-N}"
    case "$answer" in
      [Yy]*) echo ""; echo "  Your choice: Yes"; echo ""
             cat "$SERVICE_FILE"; break ;;
      [Nn]*) echo ""; echo "  Your choice: No"; break ;;
      *) echo "  Please answer Y or n." ;;
    esac
  done
  echo ""
  div
  echo ""
  info "To edit the file:"
  info "  sudo nano ${SERVICE_FILE}"
  echo ""
  info "After editing, reload systemd:"
  info "  sudo systemctl daemon-reload"
  echo ""
fi

run systemctl daemon-reload

# -- ask --
info "Enabling means the service starts automatically on every boot."
if confirm "ENABLE SERVICE (auto-start on boot)?" "recommended"; then
  run systemctl enable "${SERVICE_NAME}.service"
  ok "Service enabled"
else
  skip "Not enabled. Enable later:  sudo systemctl enable ${SERVICE_NAME}"
fi

step_done "service"

pause

# =====================================
# Summary
# =====================================

print_summary

echo "========================================"
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

pause
clear

# =====================================
# Final Steps
# =====================================

echo ""
echo "========================================"
echo "  Final Steps"
echo "========================================"
echo ""
warn "Before starting, create the config files:"
info "  ${INSTALL_PATH}/settings_ini.py"
info "  ${INSTALL_PATH}/poll_list.py"
echo ""
info "Wiki:           https://github.com/philippoo66/optolink-splitter/wiki"
info "Start service:  sudo systemctl start ${SERVICE_NAME}"
info "Service status: sudo systemctl status ${SERVICE_NAME}"
info "Service logs:   sudo journalctl -u ${SERVICE_NAME} -f"
info "Manual start:   cd ${INSTALL_PATH} && source ${VENV_DIR}/bin/activate && python ${MAIN_SCRIPT}"
echo ""
