#!/usr/bin/env bash
# tools_backup_update.sh
# Optolink-Splitter Backup & Update
# Copyright 2025-2026 EarlSneedSinclair
# Version: 1.7
#
# Usage:
#   chmod +x tools_backup_update.sh
#   ./tools_backup_update.sh           # Interactive menu
#   ./tools_backup_update.sh --dry-run # Only check, no changes
#
# Requirements:
#   - This script is located in the Optolink directory (next to settings_ini.py)
#   - Config file: tools_backup_update.conf (same directory)
#   - Packages: wget, tar, rsync
#   - Optional: systemd service (works without)

set -euo pipefail

# =====================================
# DO NOT EDIT BELOW THIS LINE
# =====================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF_FILE="${SCRIPT_DIR}/tools_ols_backup_update.conf"
CONF_EXAMPLE="${SCRIPT_DIR}/tools_ols_backup_update.conf.example"

# =====================================
# Config file handling
# =====================================

CONF_VARS=(
    GITHUB_USER
    GITHUB_REPO
    GITHUB_BRANCH
    MAX_BACKUPS
    BACKUP_BASE_DIR
    TMP_DIR
    EXCLUDE_PATTERNS
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
        if ! grep -qE "^${var}=" "${CONF_FILE}" && ! grep -qE "^${var}\s*\(" "${CONF_FILE}"; then
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

    # Derive variables that depend on conf values
    if [[ -n "${BACKUP_BASE_DIR}" ]]; then
        BACKUP_PREFIX="${BACKUP_BASE_DIR}/$(basename "${INSTALL_DIR}")_backup_"
    else
        BACKUP_PREFIX="${INSTALL_DIR}_backup_"
    fi
    REPO_TAR_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
    GITHUB_API_URL="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}"
    TAR_FILE="${TMP_DIR}/optolink-splitter.tar.gz"

    # Detect service availability (SERVICE_NAME is optional in conf)
    HAS_SERVICE=false
    if [[ -n "${SERVICE_NAME:-}" ]] && command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        if systemctl list-unit-files "${SERVICE_NAME}" &>/dev/null 2>&1; then
            HAS_SERVICE=true
        fi
    fi
}

# =====================================
# Initialisation
# =====================================

INSTALL_DIR="${SCRIPT_DIR}"
LOCK_FILE="/tmp/optolink-update.lock"
DRY_RUN=false
HAS_SERVICE=false

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
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
# Service helpers
# =====================================

service_status() {
    if [[ "$HAS_SERVICE" == true ]]; then
        local active
        active="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "unknown")"
        case "$active" in
            active)   printf "%s%s (%s%s%s)%s" "${SERVICE_NAME}" "" "$C_GREEN" "active" "$C_RESET" "" ;;
            inactive) printf "%s (%s%s%s)" "${SERVICE_NAME}" "$C_YELLOW" "inactive" "$C_RESET" ;;
            failed)   printf "%s (%s%s%s)" "${SERVICE_NAME}" "$C_RED" "failed" "$C_RESET" ;;
            *)        printf "%s (%s%s%s)" "${SERVICE_NAME}" "$C_DIM" "$active" "$C_RESET" ;;
        esac
    else
        echo "(none configured)"
    fi
}

service_status_plain() {
    if [[ "$HAS_SERVICE" == true ]]; then
        systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive"
    else
        echo "no service"
    fi
}

service_stop() {
    if [[ "$HAS_SERVICE" == true ]]; then
        echo "==> Stopping service ${SERVICE_NAME}"
        if ! ${SUDO} systemctl stop "${SERVICE_NAME}"; then
            echo "ERROR: 'systemctl stop ${SERVICE_NAME}' failed."
            return 1
        fi
    fi
}

service_start() {
    if [[ "$HAS_SERVICE" == true ]]; then
        echo "==> Starting service ${SERVICE_NAME}"
        ${SUDO} systemctl start "${SERVICE_NAME}"
        sleep 3
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo "✓ Service is running."
        else
            echo "✗ Service could not be started!"
            echo ""
            echo "Status:"
            ${SUDO} systemctl status "${SERVICE_NAME}" --no-pager || true
            echo ""
            echo "Last logs:"
            ${SUDO} journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
            return 1
        fi
    fi
}

# =====================================
# Dependency & environment checks
# =====================================

REQUIRED_CMDS=(wget tar rsync)

check_dependencies() {
    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: The following required commands are missing:"
        for cmd in "${missing[@]}"; do
            echo "  - $cmd"
        done
        echo ""
        echo "Install hint (Debian/Ubuntu/Raspbian):"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                wget)  echo "  sudo apt install wget" ;;
                tar)   echo "  sudo apt install tar" ;;
                rsync) echo "  sudo apt install rsync" ;;
            esac
        done
        exit 1
    fi
}

check_install_dir() {
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        echo "ERROR: Installation directory not found: ${INSTALL_DIR}"
        exit 1
    fi

    if [[ ! -w "${INSTALL_DIR}" ]] && [[ "${EUID}" -ne 0 ]]; then
        echo "WARNING: Installation directory may not be writable: ${INSTALL_DIR}"
        echo "         You might need to run this script with sudo."
    fi
}

cleanup() {
    [[ -n "${TAR_FILE:-}" ]]  && rm -f "${TAR_FILE}" 2>/dev/null || true
    [[ -n "${TMP_DIR:-}" ]]   && rm -rf "${TMP_DIR}" 2>/dev/null || true
    rm -f "${LOCK_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

check_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        pid=$(cat "${LOCK_FILE}")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "ERROR: Update already running (PID: $pid)"
            exit 1
        else
            echo "Stale lock file found, removing..."
            rm -f "${LOCK_FILE}"
        fi
    fi
    echo "$$" > "${LOCK_FILE}"
}

show_help() {
    cat << EOF
Usage: $0 [OPTION]

Options:
  --dry-run     Only check, do not make changes
  -h, --help    Show this help

Examples:
  $0             # Interactive menu
  $0 --dry-run   # Only check
EOF
    exit 0
}

format_backup_date() {
    local raw="$1"
    if [[ "$raw" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    else
        echo "$raw"
    fi
}

backup_timestamp() {
    local path="$1"
    local name
    name="$(basename "$path")"
    echo "${name#*_backup_}"
}

get_backups() {
    mapfile -t BACKUPS < <(ls -dt "${BACKUP_PREFIX}"* 2>/dev/null || true)
}

count_backups() {
    get_backups
    echo "${#BACKUPS[@]}"
}

latest_backup_date() {
    get_backups
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        echo "none"
    else
        format_backup_date "$(backup_timestamp "${BACKUPS[0]}")"
    fi
}

cleanup_old_backups() {
    echo "==> Checking old backups..."
    get_backups
    local count=${#BACKUPS[@]}
    if [[ $count -gt $MAX_BACKUPS ]]; then
        echo "    Deleting $(( count - MAX_BACKUPS )) old backup(s)..."
        for ((i=MAX_BACKUPS; i<count; i++)); do
            echo "    Removing: ${BACKUPS[$i]}"
            rm -rf "${BACKUPS[$i]}"
        done
    else
        echo "    Backups: ${count} / ${MAX_BACKUPS} – nothing to clean up."
    fi
}


check_network() {
    echo -n "==> Checking network connectivity to github.com... "
    if wget -q --spider --timeout=5 https://github.com 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        echo "ERROR: Cannot reach github.com. Please check your internet connection."
        exit 1
    fi
}

get_latest_commit() {
    wget -q -O - "${GITHUB_API_URL}/commits/${GITHUB_BRANCH}" 2>/dev/null \
        | grep -m1 '"sha"' \
        | sed 's/.*"sha": *"\([^"]*\)".*/\1/' \
        | cut -c1-12 \
        || echo "unknown"
}

build_rsync_excludes() {
    RSYNC_EXCLUDES=()
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        RSYNC_EXCLUDES+=("--exclude=${pattern}")
    done
}

FILES_NEW=()
FILES_CHANGED=()
FILES_DELETED=()
PROTECTED_AFFECTED=()

analyse_changes() {
    local new_dir="$1"
    local install_dir="$2"

    FILES_NEW=()
    FILES_CHANGED=()
    FILES_DELETED=()
    PROTECTED_AFFECTED=()

    # --- Run rsync dry-runs ---
    # raw_all:      no excludes → detect all changes including protected ones
    # raw_filtered: with excludes → actual changes to apply
    local raw_all
    raw_all=$(rsync -rnvc \
        --delete \
        --itemize-changes \
        "${new_dir}/" "${install_dir}/" 2>/dev/null || true)

    local raw_filtered
    raw_filtered=$(rsync -rnvc \
        --delete \
        --itemize-changes \
        "${RSYNC_EXCLUDES[@]}" \
        "${new_dir}/" "${install_dir}/" 2>/dev/null || true)

    # --- Parse helper: classify a single rsync itemize line ---
    _item_action=""
    _item_filename=""

    classify_rsync_line() {
        _item_action=""
        _item_filename=""
        local line="$1"
        [[ -z "$line" ]] && return

        local flag="${line:0:1}"
        local ftype="${line:1:1}"

        # Deletion line: "*deleting"
        if [[ "$flag" == "*" ]] && [[ "${line:1:8}" == "deleting" ]]; then
            local rest="${line:9}"
            rest="${rest#"${rest%%[! ]*}"}"   # ltrim spaces
            [[ -z "$rest" ]] && return
            _item_filename="$rest"
            _item_action="deleted"
            return
        fi

        # Skip directory entries and non-transfer lines
        [[ "$ftype" == "d" ]] && return
        [[ "$flag" != ">" ]] && [[ "$flag" != "c" ]] && return

        # filename starts at position 12 (10 flag chars + space)
        local filename="${line:12}"
        [[ -z "$filename" ]] && return
        [[ "$filename" == */ ]] && return  # trailing slash = directory

        _item_filename="$filename"

        local extra="${line:2:9}"
        if [[ "$extra" == "+++++++++" ]]; then
            _item_action="new"
        else
            _item_action="changed"
        fi
    }

    # --- Pass 1: find protected files affected by this update ---
    while IFS= read -r line; do
        classify_rsync_line "$line"
        [[ -z "$_item_action" ]] || [[ -z "$_item_filename" ]] && continue

        # Check whether this file is excluded: must match in raw_all but not raw_filtered
        # Use line-anchored grep to avoid substring false positives
        if ! echo "$raw_filtered" | grep -qxF "${line}"; then
            local desc=""
            case "$_item_action" in
                new)     desc="new in update" ;;
                changed) desc="changed in update" ;;
                deleted) desc="deleted in update" ;;
            esac
            PROTECTED_AFFECTED+=("${_item_filename} (${desc})")
        fi
    done <<< "$raw_all"

    # --- Pass 2: collect actual changes (excludes applied) ---
    while IFS= read -r line; do
        classify_rsync_line "$line"
        [[ -z "$_item_action" ]] || [[ -z "$_item_filename" ]] && continue

        case "$_item_action" in
            new)     FILES_NEW+=("$_item_filename") ;;
            changed) FILES_CHANGED+=("$_item_filename") ;;
            deleted) FILES_DELETED+=("$_item_filename") ;;
        esac
    done <<< "$raw_filtered"
}

parse_selection() {
    local input="$1"
    local max="$2"
    SELECTED_INDICES=()

    if [[ -z "$input" ]] || [[ "$input" == "a" ]] || [[ "$input" == "A" ]]; then
        for ((i=1; i<=max; i++)); do SELECTED_INDICES+=($i); done
        return
    fi

    if [[ "$input" == "n" ]] || [[ "$input" == "N" ]]; then
        return
    fi

    IFS=',' read -ra PARTS <<< "$input"
    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            if [[ $start -lt 1 ]] || [[ $end -gt $max ]] || [[ $start -gt $end ]]; then
                echo "Invalid range: $part (must be 1-$max)"
                return 1
            fi
            for ((i=start; i<=end; i++)); do SELECTED_INDICES+=($i); done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [[ $part -lt 1 ]] || [[ $part -gt $max ]]; then
                echo "Invalid number: $part (must be 1-$max)"
                return 1
            fi
            SELECTED_INDICES+=($part)
        else
            echo "Invalid input: $part"
            return 1
        fi
    done
    SELECTED_INDICES=($(echo "${SELECTED_INDICES[@]}" | tr ' ' '\n' | sort -nu))
}

apply_changes() {
    local new_dir="$1"
    local install_dir="$2"
    local -n to_copy=$3
    local -n to_delete=$4
    local copied=0
    local deleted=0
    local skipped=0

    for f in "${to_copy[@]}"; do
        local src="${new_dir}/${f}"
        local dst="${install_dir}/${f}"
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$src" "$dst"
            echo "  ✓ copied: $f"
            (( copied++ )) || true
        else
            echo "  ⚠ source not found, skipped: $f"
            (( skipped++ )) || true
        fi
    done

    for f in "${to_delete[@]}"; do
        local target="${install_dir}/${f}"
        if [[ -f "$target" ]]; then
            rm -f "$target"
            echo "  ✓ deleted: $f"
            (( deleted++ )) || true
        else
            echo "  - already gone: $f"
        fi
    done

    echo ""
    echo "  Summary: $copied copied, $deleted deleted, $skipped skipped"
}

format_exclude_list() {
    local result=""
    local count=${#EXCLUDE_PATTERNS[@]}
    if [[ $count -eq 0 ]]; then
        echo "(none)"
        return
    fi
    for ((i=0; i<count && i<3; i++)); do
        [[ -n "$result" ]] && result+=", "
        result+="${EXCLUDE_PATTERNS[$i]}"
    done
    if [[ $count -gt 3 ]]; then
        result+=", ... (${count} total)"
    fi
    echo "$result"
}

show_protected_summary() {
    # Group affected files by their matching exclude pattern
    declare -A _prot_pattern_counts
    declare -A _prot_pattern_actions
    local _prot_ungrouped=()

    for item in "${PROTECTED_AFFECTED[@]}"; do
        local fname="${item%% (*}"    # strip " (changed in update)" etc.
        local action="${item##* (}"   # e.g. "changed in update)"
        action="${action%)}"          # strip trailing )
        local matched=false

        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            local pat_clean="${pattern%/}"
            if [[ "$fname" == "$pat_clean" ]] || [[ "$fname" == "$pat_clean/"* ]]; then
                _prot_pattern_counts["$pattern"]=$(( ${_prot_pattern_counts["$pattern"]:-0} + 1 ))
                if [[ ! "${_prot_pattern_actions["$pattern"]:-}" == *"$action"* ]]; then
                    _prot_pattern_actions["$pattern"]="${_prot_pattern_actions["$pattern"]:-}${_prot_pattern_actions["$pattern"]:+, }${action}"
                fi
                matched=true
                break
            fi
            # shellcheck disable=SC2254
            if [[ "$fname" == $pattern ]]; then
                _prot_pattern_counts["$pattern"]=$(( ${_prot_pattern_counts["$pattern"]:-0} + 1 ))
                if [[ ! "${_prot_pattern_actions["$pattern"]:-}" == *"$action"* ]]; then
                    _prot_pattern_actions["$pattern"]="${_prot_pattern_actions["$pattern"]:-}${_prot_pattern_actions["$pattern"]:+, }${action}"
                fi
                matched=true
                break
            fi
        done

        if [[ "$matched" == false ]]; then
            _prot_ungrouped+=("$item")
        fi
    done

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        local count="${_prot_pattern_counts["$pattern"]:-0}"
        [[ $count -eq 0 ]] && continue
        local actions="${_prot_pattern_actions["$pattern"]}"
        if [[ $count -eq 1 ]]; then
            echo "  ⚠ ${pattern} (${actions})"
        else
            echo "  ⚠ ${pattern} (${count} files; ${actions})"
        fi
    done

    for item in "${_prot_ungrouped[@]}"; do
        echo "  ⚠ $item"
    done

    unset _prot_pattern_counts _prot_pattern_actions
}

show_main_menu() {
    local n_backups latest_date
    n_backups="$(count_backups)"
    latest_date="$(latest_backup_date)"
    clear
    echo "========================================"
    echo "  Optolink-Splitter Backup & Update"
    echo "========================================"
    echo ""
    printf "Backups:      %s / %s\n" "$n_backups" "$MAX_BACKUPS"
    printf "Latest:       %s\n" "$latest_date"
    echo ""
    printf "Repository:   %s/%s\n" "$GITHUB_USER" "$GITHUB_REPO"
    printf "Branch:       %s\n" "$GITHUB_BRANCH"
    echo "Protected"
    printf "from update:  %s files/patterns\n" "${#EXCLUDE_PATTERNS[@]}"
    printf "Service:      %s\n" "$(service_status)"
    echo ""
    echo "1) Create backup"
    echo "2) List backups"
    echo "3) Restore backup"
    echo ""
    echo "4) Update from GitHub"
    echo ""
    echo "s) Settings"
    echo "q) Quit"
    echo ""
    read -n1 -s -p "Select option [1-4, s, q]: " MENU_CHOICE
    echo ""
}

print_backup_table() {
    printf "  %-5s %-22s %8s %s\n" "No." "Date & Time" "Size" "Files"
    echo "  ──────────────────────────────────────────────────"
    for i in "${!BACKUPS[@]}"; do
        local path="${BACKUPS[$i]}"
        local ts; ts="$(backup_timestamp "$path")"
        local date_fmt; date_fmt="$(format_backup_date "$ts")"
        local size; size="$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")"
        local files; files="$(find "$path" -type f 2>/dev/null | wc -l || echo "?")"
        local label=""
        [[ $i -eq 0 ]] && label=" ← latest"
        printf "  %-5s %-22s %8s %5s files%s\n" \
            "$((i+1)))" "$date_fmt" "$size" "$files" "$label"
    done
}

do_list_backups() {
    clear
    echo "========================================"
    echo "  Backups"
    echo "========================================"
    echo ""
    get_backups
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        echo "No backups found."
        echo ""
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    print_backup_table
    echo ""
    echo "  Total: ${#BACKUPS[@]} / ${MAX_BACKUPS} backups"
    echo ""
    read -n1 -s -p "Press any key to continue..." && echo ""
}

do_backup() {
    clear
    echo "========================================"
    echo "  Create Backup"
    echo "========================================"
    echo ""
    local BACKUP_DIR="${BACKUP_PREFIX}$(date +%Y%m%d_%H%M%S)"
    echo "Backing up: ${INSTALL_DIR}"
    echo "       to : ${BACKUP_DIR}"
    echo ""
    read -n1 -s -p "Continue? [Y/n]: " confirm
    echo ""
    if [[ -n "$confirm" ]] && [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        echo "Backup cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    echo ""
    echo "==> Creating backup..."
    mkdir -p "${BACKUP_DIR}"
    rsync -a "${INSTALL_DIR}/" "${BACKUP_DIR}/"
    echo ""
    echo "✓ Backup created successfully!"
    echo "  Location: ${BACKUP_DIR}"
    echo ""
    cleanup_old_backups
    echo ""
    read -n1 -s -p "Press any key to continue..." && echo ""
}

do_restore() {
    clear
    echo "========================================"
    echo "  Restore Backup"
    echo "========================================"
    echo ""
    get_backups
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        echo "No backups found!"
        echo ""
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    print_backup_table
    echo ""
    read -p "Select backup [1-${#BACKUPS[@]}] or 'q' to cancel: " choice

    if [[ "$choice" == "q" ]] || [[ "$choice" == "Q" ]]; then
        echo "Cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#BACKUPS[@]} ]]; then
        echo "Invalid selection."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    local selected_backup="${BACKUPS[$((choice-1))]}"
    local selected_date
    selected_date="$(format_backup_date "$(backup_timestamp "$selected_backup")")"

    echo ""
    echo "Selected: ${selected_date}"
    echo ""
    if [[ "$HAS_SERVICE" == true ]]; then
        echo "⚠ This will stop the service and overwrite current files."
    else
        echo "⚠ This will overwrite current files."
    fi
    read -n1 -s -p "Continue? [y/N]: " confirm
    echo ""
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        echo "Cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    echo ""
    service_stop || true
    echo "==> Restoring backup..."
    rsync -av --delete "${selected_backup}/" "${INSTALL_DIR}/"
    service_start || true
    echo ""
    echo "✓ Restore complete."
    echo ""
    read -n1 -s -p "Press any key to continue..." && echo ""
}

do_update() {
    build_rsync_excludes
    clear
    echo "========================================"
    echo "  Update from GitHub"
    echo "========================================"
    echo ""
    echo "Installation directory: ${INSTALL_DIR}"
    if [[ "$HAS_SERVICE" == true ]]; then
        printf "Service:                %s\n" "$(service_status)"
    fi
    echo "Repository:             ${GITHUB_USER}/${GITHUB_REPO}"
    echo "Branch:                 ${GITHUB_BRANCH}"
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo "*** DRY RUN MODE - No changes will be made ***"
    fi
    echo ""

    check_network

    echo "==> Creating temporary directory: ${TMP_DIR}"
    rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}"

    echo "==> Downloading tarball from GitHub..."
    wget -q --show-progress -O "${TAR_FILE}" "${REPO_TAR_URL}"

    echo "==> Extracting..."
    tar -xzf "${TAR_FILE}" -C "${TMP_DIR}"

    local NEW_DIR="${TMP_DIR}/${GITHUB_REPO}-${GITHUB_BRANCH}"
    if [[ ! -d "${NEW_DIR}" ]]; then
        echo "ERROR: Expected directory ${NEW_DIR} not found."
        echo "Available directories:"
        ls -la "${TMP_DIR}"
        exit 1
    fi

    echo "==> Fetching latest commit info..."
    local latest_version
    latest_version=$(get_latest_commit)
    echo "    Latest commit: ${latest_version}"

    echo ""
    echo "==> Analysing changes..."
    analyse_changes "${NEW_DIR}" "${INSTALL_DIR}"

    local total_changes=$(( ${#FILES_NEW[@]} + ${#FILES_CHANGED[@]} + ${#FILES_DELETED[@]} ))

    # Show protected files inline (grouped)
    if [[ ${#PROTECTED_AFFECTED[@]} -gt 0 ]]; then
        echo ""
        echo "Protected files (skipped):"
        show_protected_summary
    else
        echo ""
        echo "Protected files: None affected by this update."
    fi

    echo ""
    echo "──────────────────────────────────────────"
    echo "  Change summary"
    echo "──────────────────────────────────────────"
    printf "  [+] New files:        %3d\n" "${#FILES_NEW[@]}"
    printf "  [~] Changed files:    %3d\n" "${#FILES_CHANGED[@]}"
    printf "  [-] Removed in repo:  %3d\n" "${#FILES_DELETED[@]}"
    echo "──────────────────────────────────────────"
    echo ""

    if [[ $total_changes -eq 0 ]]; then
        echo "Everything is already up to date."
        echo ""
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ ${#FILES_NEW[@]} -gt 0 ]]; then
            echo "New files:"
            for f in "${FILES_NEW[@]}"; do echo "  + $f"; done
            echo ""
        fi
        if [[ ${#FILES_CHANGED[@]} -gt 0 ]]; then
            echo "Changed files:"
            for f in "${FILES_CHANGED[@]}"; do echo "  ~ $f"; done
            echo ""
        fi
        if [[ ${#FILES_DELETED[@]} -gt 0 ]]; then
            echo "Files removed from repo (would be deleted locally):"
            for f in "${FILES_DELETED[@]}"; do echo "  - $f"; done
            echo ""
        fi
        echo "*** DRY RUN finished – no changes made ***"
        echo ""
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    local ALL_FILES=()
    for f in "${FILES_NEW[@]}";     do ALL_FILES+=("$f"); done
    for f in "${FILES_CHANGED[@]}"; do ALL_FILES+=("$f"); done
    for f in "${FILES_DELETED[@]}"; do ALL_FILES+=("$f"); done

    if [[ ${#ALL_FILES[@]} -eq 0 ]]; then
        echo "No changes to apply."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    clear
    echo "========================================"
    echo "  Select Files to Update"
    echo "========================================"
    echo ""
    local idx=1
    if [[ ${#FILES_NEW[@]} -gt 0 ]]; then
        echo "New files (${#FILES_NEW[@]}):"
        for f in "${FILES_NEW[@]}"; do
            echo "  $idx) [NEW] $f"
            ((idx++))
        done
        echo ""
    fi
    if [[ ${#FILES_CHANGED[@]} -gt 0 ]]; then
        echo "Changed files (${#FILES_CHANGED[@]}):"
        for f in "${FILES_CHANGED[@]}"; do
            echo "  $idx) [CHG] $f"
            ((idx++))
        done
        echo ""
    fi
    if [[ ${#FILES_DELETED[@]} -gt 0 ]]; then
        echo "Files no longer in repo – delete locally? (${#FILES_DELETED[@]}):"
        for f in "${FILES_DELETED[@]}"; do
            echo "  $idx) [DEL] $f"
            ((idx++))
        done
        echo ""
    fi

    echo "──────────────────────────────────────────"
    echo ""
    echo "Selection options:"
    echo "  1,3,5 = Select specific files"
    echo "  1-5   = Select range"
    echo "  4,6-8 = Combine"
    echo "  a     = Select all (default)"
    echo "  n     = Select none"
    echo ""
    echo "  q     = Cancel"
    echo ""
    read -p "Enter your selection [a]: " selection

    if [[ "$selection" == "q" ]] || [[ "$selection" == "Q" ]]; then
        echo "Update cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    if ! parse_selection "$selection" "${#ALL_FILES[@]}"; then
        echo "Invalid selection. Update cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    local COPY_SELECTED=()
    local DELETE_SELECTED=()
    for idx in "${SELECTED_INDICES[@]}"; do
        local file="${ALL_FILES[$((idx-1))]}"
        local is_deleted=false
        for df in "${FILES_DELETED[@]}"; do
            [[ "$df" == "$file" ]] && is_deleted=true && break
        done
        if [[ "$is_deleted" == true ]]; then
            DELETE_SELECTED+=("$file")
        else
            COPY_SELECTED+=("$file")
        fi
    done

    clear
    echo "========================================"
    echo "  Confirm Update"
    echo "========================================"
    echo ""
    if [[ ${#COPY_SELECTED[@]} -gt 0 ]]; then
        echo "Files to update (${#COPY_SELECTED[@]}):"
        for f in "${COPY_SELECTED[@]}"; do
            local is_new=false
            for nf in "${FILES_NEW[@]}"; do [[ "$nf" == "$f" ]] && is_new=true && break; done
            if [[ "$is_new" == true ]]; then echo "  [NEW] $f"; else echo "  [CHG] $f"; fi
        done
        echo ""
    fi
    if [[ ${#DELETE_SELECTED[@]} -gt 0 ]]; then
        echo "Files to delete (${#DELETE_SELECTED[@]}):"
        for f in "${DELETE_SELECTED[@]}"; do echo "  [DEL] $f"; done
        echo ""
    fi
    if [[ ${#COPY_SELECTED[@]} -eq 0 ]] && [[ ${#DELETE_SELECTED[@]} -eq 0 ]]; then
        echo "No files selected. Update cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    echo "Protected files (unchanged):"
    echo "  $(format_exclude_list)"
    echo ""

    # Backup hint
    local n_backups
    n_backups="$(count_backups)"
    if [[ $n_backups -eq 0 ]]; then
        echo "⚠ No backups exist. Consider creating one first (menu option 2)."
        echo ""
    fi

    echo "──────────────────────────────────────────"
    echo ""
    read -n1 -s -p "Apply these changes? [Y/n]: " confirm
    echo ""
    if [[ -n "$confirm" ]] && [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        echo "Update cancelled."
        read -n1 -s -p "Press any key to continue..." && echo ""
        return
    fi

    echo ""
    if ! service_stop; then
        exit 1
    fi

    echo ""
    echo "==> Applying changes..."
    echo ""
    apply_changes "${NEW_DIR}" "${INSTALL_DIR}" COPY_SELECTED DELETE_SELECTED

    echo ""
    service_start || true

    echo ""
    echo "========================================"
    echo "  ✓ Update completed successfully!"
    echo "========================================"
    echo ""
    echo "New version : ${latest_version}"
    if [[ "$HAS_SERVICE" == true ]]; then
        printf "Service:      %s\n" "$(service_status)"
    fi

    # Warn if the script itself was updated
    local self_updated=false
    for f in "${COPY_SELECTED[@]}"; do
        [[ "$f" == "${SCRIPT_NAME}" ]] && self_updated=true && break
    done
    if [[ "$self_updated" == true ]]; then
        echo ""
        echo "⚠ ${SCRIPT_NAME} was updated."
        echo "  Please restart the script to use the new version."
    fi

    echo ""
    read -n1 -s -p "Press any key to continue..." && echo ""
}

view_settings() {
    clear
    echo "========================================"
    echo "  Settings – View"
    echo "========================================"
    echo ""
    echo "Config file: ${CONF_FILE}"
    echo ""
    echo "Installation:"
    echo "  Directory : ${INSTALL_DIR}"
    if [[ "$HAS_SERVICE" == true ]]; then
        printf "  Service   : %s\n" "$(service_status)"
    else
        echo "  Service   : (none configured)"
    fi
    echo ""
    echo "GitHub:"
    echo "  User/Org  : ${GITHUB_USER}"
    echo "  Repository: ${GITHUB_REPO}"
    echo "  Branch    : ${GITHUB_BRANCH}"
    echo "  URL       : https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo ""
    echo "Backup:"
    echo "  Max backups  : ${MAX_BACKUPS}"
    echo "  Backup dir   : ${BACKUP_BASE_DIR:-"(default: backup beside install dir)"}"
    echo "  Backup prefix: ${BACKUP_PREFIX}"
    echo "  Current count: $(count_backups)"
    echo ""
    echo "Temp directory : ${TMP_DIR}"
    echo ""
    echo "Protected files (${#EXCLUDE_PATTERNS[@]}):"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        echo "  ✓ $pattern"
    done
    echo ""
    read -n1 -s -p "Press any key to continue..." && echo ""
}

run_settings_menu() {
    while true; do
        clear
        echo "========================================"
        echo "  Settings"
        echo "========================================"
        echo ""
        echo "  1) View settings"
        echo "  2) Edit settings"
        echo ""
        echo "  q) Back"
        echo ""
        read -n1 -s -p "  Select option [1-2, q]: " SETTINGS_CHOICE
        echo ""
        case $SETTINGS_CHOICE in
            1) view_settings ;;
            2)
                if command -v nano &>/dev/null; then
                    nano "${CONF_FILE}"
                elif command -v vim &>/dev/null; then
                    vim "${CONF_FILE}"
                elif command -v vi &>/dev/null; then
                    vi "${CONF_FILE}"
                else
                    echo "  ERROR: No text editor found (nano, vim, vi)!"
                    read -n1 -s -p "  Press any key to continue..." && echo ""
                fi
                check_conf
                ;;
            q|Q) return ;;
            *) ;;
        esac
    done
}

# =====================================
# Parse parameters
# =====================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

# =====================================
# Startup checks
# =====================================
check_dependencies
check_conf
check_install_dir

# =====================================
# Main loop
# =====================================
check_lock

if [[ "$DRY_RUN" == true ]]; then
    do_update
    exit 0
fi

while true; do
    show_main_menu
    case $MENU_CHOICE in
        1) do_backup ;;
        2) do_list_backups ;;
        3) do_restore ;;
        4) do_update ;;
        s|S) run_settings_menu ;;
        q|Q) clear; echo "Goodbye!"; exit 0 ;;
        *) ;;
    esac
done
