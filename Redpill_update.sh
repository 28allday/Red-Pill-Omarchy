#!/usr/bin/env bash
set -euo pipefail

# ===== RED PILL — unified backup (green #9ece6a on black, invert highlight, CaskaydiaMono) =====
# Never edits icons or your System menu.

# 0) Deps — check only, these all ship with omarchy
missing=()
for pkg in rsync libnewt zstd alacritty desktop-file-utils; do
  pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
done
if (( ${#missing[@]} > 0 )); then
  echo "Installing missing packages: ${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}" || {
    echo "Error: Failed to install dependencies" >&2
    exit 1
  }
fi

# 1) redpill (TUI) — unified config + data backup with rsync hardlink snapshots
sudo tee /usr/local/bin/redpill >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
# Load NEWT_COLORS if present (whiptail palette)
[[ -f "$HOME/.config/redpill/theme.env" ]] && set -a && . "$HOME/.config/redpill/theme.env" && set +a

APP_NAME="redpill"; APP_TITLE="RED PILL"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APP_NAME"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME"
LOCAL_BACKUP_DIR="${STATE_DIR}/backups"
INCLUDES_FILE="${CONF_DIR}/includes.conf"
EXCLUDES_FILE="${CONF_DIR}/excludes.conf"
DEST_FILE="${CONF_DIR}/destination.conf"
mkdir -p "$LOCAL_BACKUP_DIR" "$CONF_DIR"

# ── First-run: includes.conf ──
# If the file doesn't exist, create with full defaults.
# If it exists but lacks the "User data" section, append it (upgrade path).
if [[ ! -f "$INCLUDES_FILE" ]]; then
  cat >"$INCLUDES_FILE" <<'EOF'
# All configs
~/.config

# Shell
~/.bashrc
~/.bash_profile

# Keys
~/.ssh
~/.gnupg

# Fonts & launchers
~/.local/share/fonts
~/.local/share/applications

# User data
~/Documents
~/Pictures
~/Music
~/Videos
~/Desktop
~/Downloads
~/Templates
EOF
elif ! grep -q '# User data' "$INCLUDES_FILE"; then
  cat >>"$INCLUDES_FILE" <<'EOF'

# User data (added by redpill upgrade)
~/Documents
~/Pictures
~/Music
~/Videos
~/Desktop
~/Downloads
~/Templates
EOF
fi

# ── First-run: excludes.conf ──
if [[ ! -f "$EXCLUDES_FILE" ]]; then
  cat >"$EXCLUDES_FILE" <<'EOF'
.cache/
.local/state/
node_modules/
__pycache__/
.Trash*/
*.tmp
*.swp
.thumbnails/
EOF
fi

# ── Helpers ──
have(){ command -v "$1" >/dev/null 2>&1; }
timestamp(){ date +"%Y-%m-%d_%H-%M-%S"; }
hosttag(){ hostnamectl --static 2>/dev/null || hostname; }
choose_comp(){ have zstd && echo zstd || echo gzip; }

# ── Prompt to reboot after restore ──
prompt_reboot(){
  echo
  _hr
  printf '  %s%sA reboot is recommended to fully apply all restored configs.%s\n' "$_c_bold" "$_c_yellow" "$_c_reset"
  echo
  read -r -p "  Reboot now? [Y/n] " _reboot_yn
  if [[ "${_reboot_yn,,}" != "n" ]]; then
    _ok "Rebooting in 3 seconds..."
    sleep 3
    systemctl reboot
  else
    _warn "Skipped reboot. Some changes may not take effect until you reboot."
  fi
}

# ── Fix paths after restore if username/home changed ──
# Usage: fix_restored_paths /path/to/snapshot_or_backup.log
fix_restored_paths(){
  local source_log="$1"
  local old_home=""

  # Read old home from backup.log
  if [[ -f "$source_log" ]]; then
    old_home="$(grep -oP 'Home:\s+\K.*' "$source_log" 2>/dev/null)" || true
  fi

  # Nothing to fix if same home or no old home recorded
  [[ -n "$old_home" && "$old_home" != "$HOME" ]] || return 0

  _info "Username change" "$(basename "$old_home") → $(basename "$HOME")"
  _info "Fixing paths" "$old_home → $HOME"

  # Fix absolute symlinks that point to old home
  while IFS= read -r link; do
    local target
    target="$(readlink "$link")"
    if [[ "$target" == "$old_home/"* || "$target" == "$old_home" ]]; then
      local new_target="${target/$old_home/$HOME}"
      ln -snf "$new_target" "$link"
    fi
  done < <(find "$HOME/.config" "$HOME/.local" -type l 2>/dev/null)

  # Fix hardcoded paths in all config files (escape regex metacharacters in paths)
  local old_home_escaped new_home_escaped
  old_home_escaped="$(printf '%s\n' "$old_home" | sed 's/[][\/.^$*]/\\&/g')"
  new_home_escaped="$(printf '%s\n' "$HOME" | sed 's/[\/&]/\\&/g')"
  while IFS= read -r file; do
    if grep -Iql "$old_home" "$file" 2>/dev/null; then
      sed -i "s|${old_home_escaped}|${new_home_escaped}|g" "$file"
    fi
  done < <(find "$HOME/.config" -type f -size -1M 2>/dev/null)

  _ok "Paths updated for new home directory"
}

# Pick a terminal-friendly editor (GUI editors like kate won't work in TTY)
tui_editor(){
  # If EDITOR is a known terminal editor, use it
  local e="${EDITOR:-}"
  case "${e##*/}" in
    nvim|vim|vi|micro|helix|hx|nano|emacs) echo "$e"; return ;;
  esac
  # Otherwise find one
  for cmd in nvim vim vi micro nano; do
    have "$cmd" && echo "$cmd" && return
  done
  echo "vi"
}

# ── TUI formatting ──
_c_green=$'\033[38;2;158;206;106m'
_c_red=$'\033[38;2;247;118;142m'
_c_yellow=$'\033[38;2;224;175;104m'
_c_cyan=$'\033[38;2;125;207;255m'
_c_dim=$'\033[2m'
_c_bold=$'\033[1m'
_c_reset=$'\033[0m'

_hr(){
  printf '%s────────────────────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
}

_header(){
  echo
  _hr
  printf '  %s%s%s\n' "${_c_bold}${_c_green}" "$1" "$_c_reset"
  _hr
}

_info(){
  printf '  %s%-18s%s %s\n' "$_c_dim" "$1" "$_c_reset" "$2"
}

_ok(){
  printf '\n  %s✓%s %s\n' "$_c_green" "$_c_reset" "$1"
}

_warn(){
  printf '\n  %s⚠%s %s\n' "$_c_yellow" "$_c_reset" "$1"
}

_err(){
  printf '\n  %s✗%s %s\n' "$_c_red" "$_c_reset" "$1"
}

_pause(){
  echo
  _hr
  read -r -p "  Press Enter to continue..."
}

# ── Read backup mode from a snapshot's backup.log ──
_snap_mode(){
  local log="$1/backup.log"
  if [[ -f "$log" ]]; then
    grep -oP 'Mode:\s+\K.*' "$log" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

_mode_tag(){
  case "$1" in
    configs) printf '%s[configs]%s' "$_c_cyan" "$_c_reset" ;;
    data)    printf '%s[data]%s' "$_c_yellow" "$_c_reset" ;;
    all)     printf '%s[full]%s' "$_c_green" "$_c_reset" ;;
    *)       printf '%s[unknown]%s' "$_c_dim" "$_c_reset" ;;
  esac
}

# Read include paths by section
# Usage: read_includes [all|configs|data]
read_includes(){
  local mode="${1:-all}"
  case "$mode" in
    configs)
      # Lines from start until "# User data" header (exclusive)
      awk '/^# User data/{exit} /^\s*#/{next} /^\s*$/{next} {print}' "$INCLUDES_FILE"
      ;;
    data)
      # Lines after "# User data" header
      awk 'BEGIN{found=0} /^# User data/{found=1; next} !found{next} /^\s*#/{next} /^\s*$/{next} {print}' "$INCLUDES_FILE"
      ;;
    *)
      # All non-comment, non-empty lines
      grep -vE '^\s*#' "$INCLUDES_FILE" | sed '/^\s*$/d'
      ;;
  esac
}

pre_backup_note(){
  echo
  printf '  %s%s%s\n' "$_c_dim" "You take the red pill, you stay in hyprland and" "$_c_reset"
  printf '  %s%s%s\n' "$_c_dim" "I show you how deep the rabbit-hole goes..." "$_c_reset"
  sleep 3
}

# ── Destination management ──
read_destination(){
  if [[ -f "$DEST_FILE" ]]; then
    local d
    d="$(head -n1 "$DEST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$d" ]] && echo "$d" && return 0
  fi
  return 1
}

check_destination(){
  local dest
  dest="$(read_destination)" || { _err "No backup destination configured. Use 'Set backup destination' first."; return 1; }
  if [[ ! -d "$dest" ]]; then
    _err "Destination not mounted: $dest"
    printf '  %s\n' "Plug in the drive or run 'Set backup destination' to pick a new one."
    return 1
  fi
  echo "$dest"
}

# ── Scan for external drives (mounted or not) ──
# Populates parallel arrays: _scan_dev, _scan_mount, _scan_size, _scan_label, _scan_fstype
scan_drives(){
  _scan_dev=(); _scan_mount=(); _scan_size=(); _scan_label=(); _scan_fstype=()

  # Use lsblk pairs mode (-P) for reliable parsing of fields with spaces/empty values
  while IFS= read -r line; do
    local dev="" mnt="" sz="" lbl="" typ="" fs=""
    # Parse KEY="VALUE" pairs
    while [[ "$line" =~ ([A-Z]+)=\"([^\"]*)\" ]]; do
      case "${BASH_REMATCH[1]}" in
        PATH)       dev="${BASH_REMATCH[2]}" ;;
        MOUNTPOINT) mnt="${BASH_REMATCH[2]}" ;;
        SIZE)       sz="${BASH_REMATCH[2]}" ;;
        LABEL)      lbl="${BASH_REMATCH[2]}" ;;
        TYPE)       typ="${BASH_REMATCH[2]}" ;;
        FSTYPE)     fs="${BASH_REMATCH[2]}" ;;
      esac
      line="${line#*\""${BASH_REMATCH[2]}"\"}"
    done

    # Only partitions or unlocked LUKS volumes with a real filesystem
    [[ "$typ" == "part" || "$typ" == "crypt" ]] || continue
    [[ -n "$fs" && "$fs" != "crypto_LUKS" && "$fs" != "swap" ]] || continue

    # Skip system volumes by mountpoint
    case "$mnt" in
      /|/boot|/boot/*|/home|/var|/var/*) continue ;;
    esac

    _scan_dev+=("$dev")
    _scan_mount+=("${mnt:-(not mounted)}")
    _scan_size+=("$sz")
    _scan_label+=("${lbl:-(no label)}")
    _scan_fstype+=("$fs")
  done < <(lsblk -Pno PATH,MOUNTPOINT,SIZE,LABEL,TYPE,FSTYPE 2>/dev/null)
}

set_destination(){
  scan_drives
  local -a menu_items=()

  if (( ${#_scan_dev[@]} == 0 )); then
    if command -v whiptail >/dev/null; then
      whiptail --title "$APP_TITLE" --msgbox "No external drives detected.\nPlug in a drive and try again, or enter a path manually." 10 60
      local manual
      manual=$(whiptail --title "$APP_TITLE" --inputbox "Enter backup destination path:" 10 60 "" 3>&1 1>&2 2>&3) || return 1
      [[ -n "$manual" ]] || return 1
      echo "$manual" > "$DEST_FILE"
      _ok "Destination set to: $manual"
    else
      _warn "No external drives detected."
      local manual
      read -r -p "  Enter backup destination path: " manual
      [[ -n "$manual" ]] || return 1
      echo "$manual" > "$DEST_FILE"
      _ok "Destination set to: $manual"
    fi
    return 0
  fi

  # Build menu
  local i
  for i in "${!_scan_dev[@]}"; do
    local desc="${_scan_label[$i]}  ${_scan_size[$i]}  ${_scan_fstype[$i]}  ${_scan_mount[$i]}"
    menu_items+=("$((i+1))" "$desc")
  done
  menu_items+=("M" "Enter path manually")

  local pick
  if command -v whiptail >/dev/null; then
    pick=$(whiptail --title "$APP_TITLE" --menu "Select backup destination" 18 78 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
  else
    echo "Available drives:"
    for i in "${!_scan_dev[@]}"; do
      echo "  $((i+1))) ${_scan_label[$i]}  ${_scan_size[$i]}  ${_scan_fstype[$i]}  ${_scan_mount[$i]}"
    done
    echo "  M) Enter path manually"
    read -r -p "Pick: " pick
  fi

  if [[ "$pick" == "M" || "$pick" == "m" ]]; then
    local manual
    if command -v whiptail >/dev/null; then
      manual=$(whiptail --title "$APP_TITLE" --inputbox "Enter backup destination path:" 10 60 "" 3>&1 1>&2 2>&3) || return 1
    else
      read -r -p "Enter backup destination path: " manual
    fi
    [[ -n "$manual" ]] || return 1
    echo "$manual" > "$DEST_FILE"
    echo "Destination set to: $manual"
    return 0
  fi

  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_scan_dev[@]} )); then
    _err "Invalid selection: $pick"
    return 1
  fi
  local idx=$((pick-1))
  local chosen_dev="${_scan_dev[$idx]}"
  local chosen_mount="${_scan_mount[$idx]}"

  # If not mounted, mount it via udisksctl
  if [[ "$chosen_mount" == "(not mounted)" ]]; then
    printf '  Mounting %s ...\n' "$chosen_dev"
    if command -v udisksctl >/dev/null; then
      local mount_output
      mount_output="$(udisksctl mount -b "$chosen_dev" 2>&1)" || {
        echo "Failed to mount: $mount_output"
        return 1
      }
      # udisksctl prints "Mounted /dev/sda1 at /run/media/user/Label"
      chosen_mount="$(echo "$mount_output" | grep -oP 'at \K.+')" || {
        # Fallback: re-read from lsblk
        chosen_mount="$(lsblk -Pno MOUNTPOINT "$chosen_dev" 2>/dev/null | grep -oP 'MOUNTPOINT="\K[^"]+')"
      }
      if [[ -z "$chosen_mount" || ! -d "$chosen_mount" ]]; then
        echo "Mounted but could not determine mount point."
        return 1
      fi
      _ok "Mounted at: $chosen_mount"
    else
      echo "udisksctl not found. Please mount $chosen_dev manually and try again."
      return 1
    fi
  fi

  echo "$chosen_mount" > "$DEST_FILE"
  _ok "Destination set to: $chosen_mount"
}

# ── Expand include paths ──
# Usage: expand_includes [all|configs|data]
expand_includes(){
  local mode="${1:-all}"
  local -a paths=()
  while IFS= read -r p; do
    local x="${p/#\~/$HOME}"
    if [[ -e "$x" ]]; then
      paths+=("$x")
    else
      echo "Skip (not found): $x" >&2
    fi
  done < <(read_includes "$mode")
  (( ${#paths[@]} )) || { echo "Nothing to back up." >&2; return 1; }
  printf '%s\n' "${paths[@]}"
}

# ── Build rsync args + relative source list (shared by estimate & backup) ──
# Usage: build_rsync_plan [all|configs|data]
build_rsync_plan(){
  local mode="${1:-all}"
  _bk_mode="$mode"
  _bk_dest="$(check_destination)" || return 1

  _bk_snap_dir="$_bk_dest/redpill/snapshots"
  _bk_latest="$_bk_dest/redpill/latest"

  local -a srcs=()
  mapfile -t srcs < <(expand_includes "$mode")
  (( ${#srcs[@]} )) || { echo "Nothing to back up." >&2; return 1; }

  _bk_args=( -aHAX --delete --no-owner --no-group )
  [[ -f "$EXCLUDES_FILE" ]] && _bk_args+=( "--exclude-from=$EXCLUDES_FILE" )

  # Find best --link-dest: most recent snapshot whose mode matches or is broader
  # e.g. backing up "all" should prefer the last "all" snapshot, not a "configs" one
  local _best_link=""
  if [[ -d "$_bk_snap_dir" ]]; then
    local _snap _snap_mode
    while IFS= read -r _snap; do
      [[ -f "$_snap/backup.log" ]] || continue
      _snap_mode="$(grep -oP 'Mode:\s+\K.*' "$_snap/backup.log" 2>/dev/null)" || continue
      # Accept: same mode, or "all" covers everything
      if [[ "$_snap_mode" == "$mode" || "$_snap_mode" == "all" ]]; then
        _best_link="$_snap"
        break
      fi
    done < <(find "$_bk_snap_dir" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort -r)
  fi

  if [[ -n "$_best_link" ]]; then
    _bk_args+=( "--link-dest=$_best_link" )
    # Also add latest if it's a different snapshot (rsync dedupes across multiple link-dests)
    if [[ -L "$_bk_latest" && -d "$_bk_latest" ]] && \
       [[ "$(readlink -f "$_bk_latest")" != "$(readlink -f "$_best_link")" ]]; then
      _bk_args+=( "--link-dest=$_bk_latest" )
    fi
  elif [[ -L "$_bk_latest" && -d "$_bk_latest" ]]; then
    _bk_args+=( "--link-dest=$_bk_latest" )
  fi

  _bk_rel_srcs=()
  for s in "${srcs[@]}"; do
    local rel="${s/#$HOME\//}"
    if [[ -d "$s" ]]; then
      _bk_rel_srcs+=( "./$rel/" )
    else
      _bk_rel_srcs+=( "./$rel" )
    fi
  done
  _bk_src_count=${#srcs[@]}
}

# ── Human-readable byte count ──
human_bytes(){
  local b=$1
  if (( b >= 1073741824 )); then
    awk "BEGIN{printf \"%.1f GiB\", $b/1073741824}"
  elif (( b >= 1048576 )); then
    awk "BEGIN{printf \"%.1f MiB\", $b/1048576}"
  elif (( b >= 1024 )); then
    awk "BEGIN{printf \"%.1f KiB\", $b/1024}"
  else
    echo "${b} B"
  fi
}

# ── Estimate backup size (dry-run rsync) ──
# Usage: estimate_backup [all|configs|data]
estimate_backup(){
  local mode="${1:-all}"
  build_rsync_plan "$mode" || return 1

  local tmp_target
  tmp_target="$_bk_snap_dir/.estimate_tmp_$$"
  mkdir -p "$tmp_target"

  printf '  %sScanning files...%s' "$_c_dim" "$_c_reset"
  local stats
  stats="$(cd "$HOME" && rsync "${_bk_args[@]}" --dry-run --stats \
    --relative "${_bk_rel_srcs[@]}" --no-implied-dirs \
    "$tmp_target/" 2>&1)" || true
  rm -rf "$tmp_target" 2>/dev/null || true
  printf '\r  %s              %s\n' "$_c_dim" "$_c_reset"

  # Parse stats
  local total_size transfer_size total_files transfer_files
  total_size="$(echo "$stats"   | grep -oP 'Total file size: \K[\d,]+' | tr -d ',')" || total_size=0
  transfer_size="$(echo "$stats" | grep -oP 'Total transferred file size: \K[\d,]+' | tr -d ',')" || transfer_size=0
  total_files="$(echo "$stats"  | grep -oP 'Number of files: \K[\d,]+' | tr -d ',')" || total_files=0
  transfer_files="$(echo "$stats" | grep -oP 'Number of .* files transferred: \K[\d,]+' | tr -d ',')" || transfer_files=0

  local mode_label
  case "$mode" in
    configs) mode_label="Configs only" ;;
    data)    mode_label="User data only" ;;
    *)       mode_label="Everything" ;;
  esac

  _header "BACKUP ESTIMATE  —  $mode_label"
  _info "Sources"        "$_bk_src_count paths"
  _info "Total files"    "$total_files"
  _info "Total size"     "$(human_bytes "$total_size")"
  if [[ -L "$_bk_latest" && -d "$_bk_latest" ]]; then
    _info "Changed files"  "$transfer_files"
    _info "New data"       "${_c_cyan}$(human_bytes "$transfer_size")${_c_reset} (rest will be hardlinked)"
  else
    echo
    printf '  %s(First backup — no hardlink savings yet)%s\n' "$_c_dim" "$_c_reset"
  fi

  # Check free space on destination
  local free_bytes
  free_bytes="$(df -B1 --output=avail "$_bk_dest" 2>/dev/null | tail -n1 | tr -d ' ')" || free_bytes=0
  _info "Drive free"     "$(human_bytes "$free_bytes")"
  _hr

  if (( free_bytes > 0 && transfer_size > free_bytes )); then
    _err "Not enough free space on destination!"
    return 1
  fi
}

# ── Unified backup: rsync hardlink snapshots to external drive ──
# Usage: mk_backup [all|configs|data]
mk_backup(){
  local mode="${1:-all}"
  build_rsync_plan "$mode" || return 1

  local ts
  ts="$(timestamp)"
  local target="$_bk_snap_dir/$ts"
  mkdir -p "$target"

  local logfile="$target/backup.log"

  # Start log
  {
    echo "RED PILL backup log"
    echo "==================="
    echo "Date:        $(date)"
    echo "Mode:        $mode"
    echo "Destination: $target"
    echo "Sources:     $_bk_src_count paths"
    echo "Hostname:    $(hosttag)"
    echo "User:        $USER"
    echo "Home:        $HOME"
    echo
  } > "$logfile"

  local mode_label
  case "$mode" in
    configs) mode_label="Configs only" ;;
    data)    mode_label="User data only" ;;
    *)       mode_label="Everything" ;;
  esac

  _header "BACKING UP  —  $mode_label"
  _info "Destination"  "$target"
  _info "Sources"      "$_bk_src_count paths"
  echo

  # Log skipped paths (re-run expand to capture stderr)
  expand_includes "$mode" >/dev/null 2>> "$logfile" || true

  # Run rsync — capture stderr to log, stdout (progress) to terminal
  # Skip progress output during shutdown autobackup (no terminal)
  local -a _rsync_extra=()
  [[ "${REDPILL_AUTOBACKUP:-}" != "1" ]] && _rsync_extra+=( --info=progress2 )
  local rsync_exit=0
  (cd "$HOME" && rsync "${_bk_args[@]}" "${_rsync_extra[@]}" --log-file="$logfile" \
    --relative "${_bk_rel_srcs[@]}" --no-implied-dirs \
    "$target/") || rsync_exit=$?

  # Append summary to log
  local snap_size
  snap_size="$(du -sh "$target" 2>/dev/null | cut -f1)" || snap_size="unknown"
  {
    echo
    echo "=== Summary ==="
    echo "Snapshot size: $snap_size"
    echo "rsync exit code: $rsync_exit"
    if (( rsync_exit == 0 )); then
      echo "Status: SUCCESS"
    else
      echo "Status: COMPLETED WITH ERRORS"
    fi
    echo "Finished: $(date)"
  } >> "$logfile"

  # Generate checksum manifest in background (xxh128sum is ~10x faster than sha256)
  # Skip during shutdown autobackup — background job would be killed or block unmount
  if [[ "${REDPILL_AUTOBACKUP:-}" != "1" ]]; then
    local cksum_file="$target/checksums.xxh128"
    local cksum_hash="xxh128sum"
    have xxh128sum || { cksum_hash="sha256sum"; cksum_file="$target/checksums.sha256"; }
    # Write to .tmp first — atomic rename on completion so partial files are never seen
    # Note: disable set -e/pipefail in subshell so a find/xargs warning doesn't kill the rename
    (set +eo pipefail; cd "$target" && find . -type f ! -name 'checksums.*' ! -name 'backup.log' -print0 \
      | sort -z | xargs -0 -r "$cksum_hash" > "${cksum_file}.tmp" 2>/dev/null \
      && mv -f "${cksum_file}.tmp" "$cksum_file") &
    disown
  fi

  # Update latest symlink (atomic: create tmp, rename) — use relative path
  # so the symlink works regardless of where the drive is mounted
  local tmp_link="$_bk_dest/redpill/.latest_tmp_$$"
  ln -snf "snapshots/$ts" "$tmp_link"
  mv -Tf "$tmp_link" "$_bk_latest"

  # Write standalone restore script to drive root (for new machine recovery)
  cat > "$_bk_dest/redpill/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
set -euo pipefail
# RED PILL — standalone restore for new machines
# Usage: bash /path/to/drive/redpill/restore.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_DIR="$SCRIPT_DIR/snapshots"
LATEST="$SCRIPT_DIR/latest"

# Ensure rsync is installed (needed for restore)
if ! command -v rsync >/dev/null 2>&1; then
  echo "  Installing rsync..."
  sudo pacman -S --needed --noconfirm rsync || { echo "  ERROR: Failed to install rsync"; exit 1; }
fi

_dim=$'\033[2m'
_green=$'\033[38;2;158;206;106m'
_cyan=$'\033[38;2;125;207;255m'
_yellow=$'\033[38;2;224;175;104m'
_reset=$'\033[0m'

# Read backup mode from a snapshot's backup.log
snap_mode(){
  local log="$1/backup.log"
  if [[ -f "$log" ]]; then
    grep -oP 'Mode:\s+\K.*' "$log" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

snap_mode_tag(){
  case "$1" in
    configs) printf '%s[configs]%s' "$_cyan" "$_reset" ;;
    data)    printf '%s[data]%s' "$_yellow" "$_reset" ;;
    all)     printf '%s[full]%s' "$_green" "$_reset" ;;
    *)       printf '%s[unknown]%s' "$_dim" "$_reset" ;;
  esac
}

echo
echo "  RED PILL — New Machine Restore"
echo "  ────────────────────────────────────────"

# Collect all snapshots
SNAPS=()
while IFS= read -r d; do
  [[ -d "$d" ]] && SNAPS+=("$d")
done < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r)

if (( ${#SNAPS[@]} == 0 )); then
  echo "  ERROR: No snapshots found in $SNAP_DIR"
  exit 1
fi

# Find which one is "latest"
LATEST_REAL=""
if [[ -L "$LATEST" && -d "$LATEST" ]]; then
  LATEST_REAL="$(readlink -f "$LATEST")"
fi

# Display all snapshots
echo
echo "  Available snapshots:"
echo "  ────────────────────────────────────────"
IDX=0
for s in "${SNAPS[@]}"; do
  IDX=$((IDX + 1))
  SNAME="$(basename "$s")"
  SMODE="$(snap_mode "$s")"
  STAG="$(snap_mode_tag "$SMODE")"
  SSIZE="?"
  if [[ -f "$s/backup.log" ]]; then
    SSIZE="$(grep -oP 'Snapshot size: \K.*' "$s/backup.log" 2>/dev/null)" || SSIZE="?"
  fi
  LATEST_MARK=""
  if [[ "$(readlink -f "$s")" == "$LATEST_REAL" ]]; then
    LATEST_MARK=" ${_green}← latest${_reset}"
  fi
  printf '  %s%2d.%s  %s  %-12s  %s(%s)%s%s\n' "$_dim" "$IDX" "$_reset" "$SNAME" "$STAG" "$_dim" "$SSIZE" "$_reset" "$LATEST_MARK"
done
echo "  ────────────────────────────────────────"
echo

# Let user pick
DEFAULT=1
read -r -p "  Select snapshot to restore [${DEFAULT}]: " PICK
PICK="${PICK:-$DEFAULT}"

if ! [[ "$PICK" =~ ^[0-9]+$ ]] || (( PICK < 1 || PICK > ${#SNAPS[@]} )); then
  echo "  Invalid selection: $PICK"
  exit 1
fi

SNAP="${SNAPS[$((PICK-1))]}"
SNAP_NAME="$(basename "$SNAP")"
SNAP_TYPE="$(snap_mode "$SNAP")"
SNAP_TAG="$(snap_mode_tag "$SNAP_TYPE")"

echo
echo "  Selected:  $SNAP_NAME  $SNAP_TAG"
echo "  Source:    $SNAP"
echo "  Target:    $HOME"
echo

# Show what this backup type means
case "$SNAP_TYPE" in
  configs)
    echo "  ${_cyan}Note:${_reset} This is a configs-only backup."
    echo "  User data (Documents, Pictures, etc.) is NOT included."
    echo ;;
  data)
    echo "  ${_yellow}Note:${_reset} This is a user-data-only backup."
    echo "  System configs (Hyprland, terminal, etc.) are NOT included."
    echo ;;
  all)
    echo "  ${_green}Note:${_reset} This is a full backup (configs + user data)."
    echo ;;
esac

# Count files
FILE_COUNT="$(find "$SNAP" -type f 2>/dev/null | wc -l)" || FILE_COUNT=0
echo "  Files to restore: $FILE_COUNT"
echo
echo "  This will copy files into your home directory."
echo "  Existing files with the same name will be overwritten."
echo "  Files not in the backup will NOT be deleted."
echo
read -r -p "  Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "  Cancelled."; exit 0; }

echo
echo "  Restoring..."
rsync -aHAX --info=progress2 --exclude='backup.log' --exclude='checksums.*' "$SNAP/" "$HOME/"

# Fix paths if username/home directory changed since backup
OLD_HOME=""
BACKUP_LOG="$SNAP/backup.log"
if [[ -f "$BACKUP_LOG" ]]; then
  OLD_HOME="$(grep -oP 'Home:\s+\K.*' "$BACKUP_LOG" 2>/dev/null)" || true
fi
if [[ -n "$OLD_HOME" && "$OLD_HOME" != "$HOME" ]]; then
  echo
  echo "  ${_yellow}Username change detected:${_reset} $(basename "$OLD_HOME") → $(basename "$HOME")"
  echo "  Fixing paths..."

  # Fix absolute symlinks pointing to old home
  while IFS= read -r link; do
    target="$(readlink "$link")"
    if [[ "$target" == "$OLD_HOME/"* || "$target" == "$OLD_HOME" ]]; then
      new_target="${target/$OLD_HOME/$HOME}"
      ln -snf "$new_target" "$link"
    fi
  done < <(find "$HOME/.config" "$HOME/.local" -type l 2>/dev/null)

  # Fix hardcoded paths in all config files (escape regex metacharacters)
  OLD_ESCAPED="$(printf '%s\n' "$OLD_HOME" | sed 's/[][\/.^$*]/\\&/g')"
  NEW_ESCAPED="$(printf '%s\n' "$HOME" | sed 's/[\/&]/\\&/g')"
  while IFS= read -r file; do
    if grep -Iql "$OLD_HOME" "$file" 2>/dev/null; then
      sed -i "s|${OLD_ESCAPED}|${NEW_ESCAPED}|g" "$file"
    fi
  done < <(find "$HOME/.config" -type f -size -1M 2>/dev/null)

  echo "  ${_green}✓${_reset} Paths updated for new home directory"
fi

# Reapply omarchy theme if available
THEME_NAME_FILE="$HOME/.config/omarchy/current/theme.name"
if command -v omarchy-theme-set >/dev/null 2>&1 && [[ -f "$THEME_NAME_FILE" ]]; then
  RESTORED_THEME="$(cat "$THEME_NAME_FILE")"
  if [[ -n "$RESTORED_THEME" ]]; then
    echo "  Applying theme: $RESTORED_THEME"
    omarchy-theme-set "$RESTORED_THEME" >/dev/null 2>&1 || true
    echo "  ${_green}✓${_reset} Theme applied"
  fi
fi

echo
echo "  ✓ Restore complete from: $SNAP_NAME  $SNAP_TAG"
echo
echo "  ────────────────────────────────────────"
echo "  ${_yellow}A reboot is recommended to fully apply all restored configs.${_reset}"
echo
read -r -p "  Reboot now? [Y/n] " _reboot_yn
if [[ "${_reboot_yn,,}" != "n" ]]; then
  echo "  ${_green}✓${_reset} Rebooting in 3 seconds..."
  sleep 3
  systemctl reboot
else
  echo
  echo "  Next steps:"
  echo "    1. Reboot to fully apply config changes"
  echo "    2. Run the Red Pill installer to set up the backup tool:"
  echo "       bash ~/Downloads/Redpill.sh"
  echo
fi
RESTORE

  _header "BACKUP COMPLETE"
  _info "Snapshot"      "$ts"
  _info "Size"          "$snap_size (hardlinked — actual new disk is smaller)"
  if [[ "${REDPILL_AUTOBACKUP:-}" != "1" ]]; then
    _info "Checksums"     "generating in background (${cksum_hash%sum})"
  else
    _info "Checksums"     "skipped (shutdown backup)"
  fi
  _info "Log"           "$logfile"

  # Show warnings if any issues
  if (( rsync_exit != 0 )); then
    _warn "rsync reported errors (exit code $rsync_exit). Check log for details."
  else
    _ok "All files backed up successfully"
  fi

  # Record last successful backup timestamp (used by redpill-notify)
  # Exit 23 = partial transfer (e.g. ACL/xattr unsupported on FAT32/exFAT) — files are fine
  if (( rsync_exit == 0 || rsync_exit == 23 )); then
    date -Iseconds > "$STATE_DIR/last_backup"
  fi

  local skip_count
  skip_count="$(grep -c 'Skip (not found)' "$logfile" 2>/dev/null)" || skip_count=0
  if (( skip_count > 0 )); then
    _warn "$skip_count path(s) were skipped (not found). See log for details."
  fi
}

# ── Config-only local tarball (legacy / no-drive fallback) ──
config_backup(){
  local tag="${1:-$(timestamp)}" comp ext out
  comp="$(choose_comp)"; [[ "$comp" == zstd ]] && ext=tar.zst || ext=tar.gz
  out="${LOCAL_BACKUP_DIR}/${tag}_$(hosttag).${ext}"

  # Only back up config paths (lines before "# User data" or all if no marker)
  local -a items=()
  while IFS= read -r p; do
    local x="${p/#\~/$HOME}"
    if [[ -e "$x" ]]; then
      items+=("$x")
    fi
  done < <(read_includes configs)
  (( ${#items[@]} )) || { echo "Nothing to back up."; return 1; }

  pushd "$HOME" >/dev/null
  local -a rels=()
  for f in "${items[@]}"; do
    rels+=("${f/#$HOME\//}")
  done
  if [[ "$comp" == zstd ]]; then
    tar --zstd -cpf "$out" "${rels[@]}"
  else
    tar -czpf "$out" "${rels[@]}"
  fi
  popd >/dev/null
  _ok "Config backup written: $out"
}

# ── List snapshots on external drive ──
list_snapshots(){
  local dest
  dest="$(read_destination)" || { _err "No destination configured."; return 1; }
  local snap_dir="$dest/redpill/snapshots"
  if [[ ! -d "$snap_dir" ]]; then
    printf '  %sNo snapshots found.%s\n' "$_c_dim" "$_c_reset"
    return 1
  fi
  local -a snaps=()
  while IFS= read -r d; do
    snaps+=("$(basename "$d")")
  done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r)
  if (( ${#snaps[@]} == 0 )); then
    printf '  %sNo snapshots found.%s\n' "$_c_dim" "$_c_reset"
    return 1
  fi
  local idx=0
  for s in "${snaps[@]}"; do
    idx=$((idx + 1))
    local snap_size="?" log_status=""
    if [[ -f "$snap_dir/$s/backup.log" ]]; then
      snap_size="$(grep -oP 'Snapshot size: \K.*' "$snap_dir/$s/backup.log" 2>/dev/null)" || snap_size="?"
      if grep -q "Status: SUCCESS" "$snap_dir/$s/backup.log" 2>/dev/null; then
        log_status="${_c_green}ok${_c_reset}"
      else
        log_status="${_c_yellow}warnings${_c_reset}"
      fi
    fi
    local mtag
    mtag="$(_mode_tag "$(_snap_mode "$snap_dir/$s")")"
    printf '  %s%2d.%s  %s  %-12s  %s(%s)%s  %s\n' "$_c_dim" "$idx" "$_c_reset" "$s" "$mtag" "$_c_dim" "$snap_size" "$_c_reset" "$log_status"
  done
}

# ── List local tarballs (legacy) ──
list_local(){
  ls -1t "$LOCAL_BACKUP_DIR"/*.tar.zst "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null || true
}

# ── Delete backups ──
delete_backups(){
  local -a del_items=() del_labels=()
  local idx=0

  # Find destination
  local dest=""
  if read_destination >/dev/null 2>&1; then
    dest="$(read_destination)"
  fi

  # Collect external snapshots
  if [[ -n "$dest" ]]; then
    local snap_dir="$dest/redpill/snapshots"
    if [[ -d "$snap_dir" ]]; then
      while IFS= read -r d; do
        local name snap_size="?" smode=""
        name="$(basename "$d")"
        smode="$(_snap_mode "$d")"
        if [[ -f "$d/backup.log" ]]; then
          snap_size="$(grep -oP 'Snapshot size: \K.*' "$d/backup.log" 2>/dev/null)" || snap_size="?"
        fi
        local mode_label
        case "$smode" in
          configs) mode_label="configs" ;; data) mode_label="data" ;; all) mode_label="full" ;; *) mode_label="?" ;;
        esac
        idx=$((idx + 1))
        del_items+=("snap:$name")
        del_labels+=("$idx" "[Drive] $name [$mode_label] ($snap_size)" "OFF")
      done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r)
    fi
  fi

  # Collect local tarballs
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local fsize
    fsize="$(du -sh "$f" 2>/dev/null | cut -f1)" || fsize="?"
    idx=$((idx + 1))
    del_items+=("local:$f")
    del_labels+=("$idx" "[Local] $(basename "$f") ($fsize)" "OFF")
  done < <(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.zst "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null || true)

  if (( ${#del_items[@]} == 0 )); then
    if command -v whiptail >/dev/null; then
      whiptail --title "$APP_TITLE" --msgbox "No backups found." 8 40
    else
      _warn "No backups found."
    fi
    return 0
  fi

  # Select which to delete
  local -a picks=()
  if command -v whiptail >/dev/null; then
    local result
    result=$(whiptail --title "$APP_TITLE" --checklist \
      "Select backups to delete (Space to toggle, Enter to confirm)" \
      20 100 12 "${del_labels[@]}" 3>&1 1>&2 2>&3) || return 0
    # whiptail returns quoted space-separated values: "1" "3" "5"
    read -ra picks <<< "$(echo "$result" | tr -d '"')"
  else
    _header "SELECT BACKUPS TO DELETE"
    local i=0
    for di in "${del_items[@]}"; do
      i=$((i + 1))
      local dtype="${di%%:*}" dval="${di#*:}"
      if [[ "$dtype" == "snap" ]]; then
        local dest_dir
        dest_dir="$(read_destination 2>/dev/null)" || dest_dir=""
        local mtag
        mtag="$(_mode_tag "$(_snap_mode "$dest_dir/redpill/snapshots/$dval")")"
        printf '  %s%2d.%s  [Drive] %s  %s\n' "$_c_dim" "$i" "$_c_reset" "$dval" "$mtag"
      else
        printf '  %s%2d.%s  [Local] %s\n' "$_c_dim" "$i" "$_c_reset" "$(basename "$dval")"
      fi
    done
    _hr
    printf '  Enter numbers to delete (space-separated), or q to cancel: '
    local input
    read -r input
    [[ "$input" != "q" && -n "$input" ]] || return 0
    read -ra picks <<< "$input"
  fi

  (( ${#picks[@]} > 0 )) || return 0

  # Validate all picks are in range
  local valid_picks=()
  for p in "${picks[@]}"; do
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#del_items[@]} )); then
      valid_picks+=("$p")
    fi
  done
  picks=("${valid_picks[@]}")
  (( ${#picks[@]} > 0 )) || { _warn "No valid selections."; return 0; }

  # Show what will be deleted and confirm
  _header "CONFIRM DELETION"
  for p in "${picks[@]}"; do
    local sel="${del_items[$((p-1))]}"
    local stype="${sel%%:*}" sval="${sel#*:}"
    if [[ "$stype" == "snap" ]]; then
      local mtag
      mtag="$(_mode_tag "$(_snap_mode "$dest/redpill/snapshots/$sval")")"
      printf '  %s✗%s  [Drive] %s  %s\n' "$_c_red" "$_c_reset" "$sval" "$mtag"
    else
      printf '  %s✗%s  [Local] %s\n' "$_c_red" "$_c_reset" "$(basename "$sval")"
    fi
  done
  _hr
  echo
  printf '  %sThis cannot be undone.%s\n' "${_c_red}${_c_bold}" "$_c_reset"
  read -r -p "  Type YES to confirm deletion: " confirm
  [[ "$confirm" == "YES" ]] || { printf '  %sCancelled.%s\n' "$_c_dim" "$_c_reset"; return 0; }

  # Perform deletion
  local deleted=0
  for p in "${picks[@]}"; do
    local sel="${del_items[$((p-1))]}"
    local stype="${sel%%:*}" sval="${sel#*:}"
    if [[ "$stype" == "snap" && -n "$dest" ]]; then
      local snap_path="$dest/redpill/snapshots/$sval"
      if [[ -d "$snap_path" ]]; then
        if ! rm -rf "$snap_path" 2>/dev/null; then
          printf '  %s⚠%s  Permission denied, retrying with sudo...\n' "$_c_yellow" "$_c_reset"
          sudo rm -rf "$snap_path"
        fi
        deleted=$((deleted + 1))
        printf '  %s✓%s  Deleted snapshot: %s\n' "$_c_green" "$_c_reset" "$sval"
      fi
    elif [[ "$stype" == "local" ]]; then
      if [[ -f "$sval" ]]; then
        if ! rm -f "$sval" 2>/dev/null; then
          printf '  %s⚠%s  Permission denied, retrying with sudo...\n' "$_c_yellow" "$_c_reset"
          sudo rm -f "$sval"
        fi
        deleted=$((deleted + 1))
        printf '  %s✓%s  Deleted local backup: %s\n' "$_c_green" "$_c_reset" "$(basename "$sval")"
      fi
    fi
  done

  # Fix latest symlink if it points to a deleted snapshot
  if [[ -n "$dest" && -L "$dest/redpill/latest" ]]; then
    if [[ ! -d "$dest/redpill/latest" ]]; then
      rm -f "$dest/redpill/latest" 2>/dev/null || sudo rm -f "$dest/redpill/latest"
      # Point to the newest remaining snapshot
      local newest
      newest="$(find "$dest/redpill/snapshots" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r | head -n1)" || true
      if [[ -n "$newest" ]]; then
        ln -snf "snapshots/$(basename "$newest")" "$dest/redpill/latest"
        printf '\n  %s↳%s  Updated latest → %s\n' "$_c_cyan" "$_c_reset" "$(basename "$newest")"
      else
        printf '\n  %s(no snapshots remaining)%s\n' "$_c_dim" "$_c_reset"
      fi
    fi
  fi

  _ok "Deleted $deleted backup(s)"
}

# ── Verify backup integrity ──
# Finds the checksum manifest (xxh128 or sha256) and uses the matching tool
_find_cksum(){
  # Returns: sets _ck_file and _ck_cmd for the caller
  local snap="$1"
  if [[ -f "$snap/checksums.xxh128" ]]; then
    _ck_file="$snap/checksums.xxh128"; _ck_cmd="xxh128sum"
  elif [[ -f "$snap/checksums.sha256" ]]; then
    _ck_file="$snap/checksums.sha256"; _ck_cmd="sha256sum"
  else
    _ck_file=""; _ck_cmd=""
  fi
}

verify_backup(){
  # Find destination
  local dest=""
  if read_destination >/dev/null 2>&1; then
    dest="$(read_destination)"
  fi

  if [[ -z "$dest" ]]; then
    _err "No backup destination configured."
    return 1
  fi

  local snap_dir="$dest/redpill/snapshots"
  if [[ ! -d "$snap_dir" ]]; then
    _err "No snapshots found."
    return 1
  fi

  # Collect snapshots that have checksums
  local -a snap_items=() snap_labels=()
  local idx=0
  while IFS= read -r d; do
    local name
    name="$(basename "$d")"
    _find_cksum "$d"
    if [[ -n "$_ck_file" ]]; then
      # Check if still being generated (file is open by another process)
      local status_tag=""
      if fuser "$_ck_file" &>/dev/null; then
        status_tag=" [generating...]"
      fi
      local fcount smode="" mode_label=""
      fcount="$(wc -l < "$_ck_file" 2>/dev/null)" || fcount="?"
      smode="$(_snap_mode "$d")"
      case "$smode" in
        configs) mode_label="configs" ;; data) mode_label="data" ;; all) mode_label="full" ;; *) mode_label="?" ;;
      esac
      idx=$((idx + 1))
      snap_items+=("$name")
      snap_labels+=("$idx" "$name [$mode_label] ($fcount files)$status_tag")
    fi
  done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r)

  if (( ${#snap_items[@]} == 0 )); then
    _warn "No snapshots with checksum manifests found."
    printf '  %sRun a new backup to generate checksums.%s\n' "$_c_dim" "$_c_reset"
    return 1
  fi

  # Pick snapshot to verify
  local pick
  if command -v whiptail >/dev/null; then
    pick=$(whiptail --title "$APP_TITLE" --menu "Select snapshot to verify" 18 70 10 \
      "${snap_labels[@]}" 3>&1 1>&2 2>&3) || return 0
  else
    _header "SELECT SNAPSHOT TO VERIFY"
    local i=0
    for s in "${snap_items[@]}"; do
      i=$((i + 1))
      local mtag
      mtag="$(_mode_tag "$(_snap_mode "$snap_dir/$s")")"
      printf '  %s%2d.%s  %s  %s\n' "$_c_dim" "$i" "$_c_reset" "$s" "$mtag"
    done
    _hr
    printf '  Enter number (or q to cancel): '
    read -r pick
    [[ "$pick" != "q" && -n "$pick" ]] || return 0
  fi

  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#snap_items[@]} )); then
    _err "Invalid selection: $pick"
    return 1
  fi
  local snap_name="${snap_items[$((pick-1))]}"
  local snap_path="$snap_dir/$snap_name"

  _find_cksum "$snap_path"
  [[ -n "$_ck_file" ]] || { _err "No checksum file in snapshot: $snap_name"; return 1; }

  # Check if checksums are still being generated
  if fuser "$_ck_file" &>/dev/null; then
    _warn "Checksums are still being generated for this snapshot."
    printf '  %sPlease wait for it to finish, then try again.%s\n' "$_c_dim" "$_c_reset"
    return 1
  fi

  have "$_ck_cmd" || { _err "$_ck_cmd not found — cannot verify."; return 1; }

  local total_files
  total_files="$(wc -l < "$_ck_file")"
  local cksum_name="${_ck_file##*/}"

  _header "VERIFYING  —  $snap_name"
  _info "Files to check" "$total_files"
  _info "Hash"           "${_ck_cmd%sum}"
  echo

  # Run checksum verification
  local fail_count=0 pass_count=0 missing_count=0
  local -a failures=()

  while IFS= read -r line; do
    if [[ "$line" == *": OK" ]]; then
      pass_count=$((pass_count + 1))
      if (( pass_count % 500 == 0 )); then
        printf '\r  %sVerified %d / %d files...%s' "$_c_dim" "$pass_count" "$total_files" "$_c_reset"
      fi
    elif [[ "$line" == *": FAILED" ]]; then
      fail_count=$((fail_count + 1))
      failures+=("${line%%:*}")
    elif [[ "$line" == *"No such file"* || "$line" == *"FAILED open"* ]]; then
      missing_count=$((missing_count + 1))
      failures+=("MISSING: ${line%%:*}")
    fi
  done < <(cd "$snap_path" && "$_ck_cmd" --check "$cksum_name" 2>&1)

  printf '\r  %s                                          %s\n' "$_c_dim" "$_c_reset"

  _header "VERIFICATION RESULT"
  _info "Snapshot"  "$snap_name"
  _info "Passed"    "${_c_green}$pass_count${_c_reset} / $total_files"

  if (( fail_count > 0 )); then
    _info "Corrupted" "${_c_red}$fail_count${_c_reset}"
  fi
  if (( missing_count > 0 )); then
    _info "Missing"   "${_c_yellow}$missing_count${_c_reset}"
  fi

  if (( fail_count == 0 && missing_count == 0 )); then
    _ok "All files intact — backup is healthy"
  else
    _warn "Issues detected"
    if (( ${#failures[@]} > 0 )); then
      echo
      printf '  %sAffected files:%s\n' "$_c_dim" "$_c_reset"
      local shown=0
      for f in "${failures[@]}"; do
        printf '    %s✗%s %s\n' "$_c_red" "$_c_reset" "$f"
        shown=$((shown + 1))
        if (( shown >= 20 )); then
          local remaining=$(( ${#failures[@]} - shown ))
          if (( remaining > 0 )); then
            printf '    %s... and %d more%s\n' "$_c_dim" "$remaining" "$_c_reset"
          fi
          break
        fi
      done
    fi
  fi
}

# ── Restore from snapshot on external drive ──
restore_snapshot(){
  local snap_name="${1:-}"
  local dest
  dest="$(read_destination)" || { echo "No destination configured."; return 1; }
  local snap_dir="$dest/redpill/snapshots"

  if [[ -z "$snap_name" ]]; then
    # Use latest
    if [[ -L "$dest/redpill/latest" && -d "$dest/redpill/latest" ]]; then
      snap_name="$(basename "$(readlink -f "$dest/redpill/latest")")"
    else
      echo "No snapshots found. Run a backup first."
      return 1
    fi
  fi

  local source="$snap_dir/$snap_name"
  [[ -d "$source" ]] || { _err "Snapshot not found: $source"; return 1; }

  _header "RESTORING SNAPSHOT"
  _info "Snapshot"  "$snap_name"
  _info "Source"    "$source"
  echo

  # Restore without --delete (safe: won't remove files not in backup)
  rsync -aHAX --info=progress2 --exclude='backup.log' --exclude='checksums.*' "$source/" "$HOME/"

  _ok "Restore complete from: $snap_name"

  # Fix paths if username/home directory changed since backup
  fix_restored_paths "$source/backup.log"

  # Reapply omarchy theme so the restored theme takes effect in the running session
  if have omarchy-theme-set; then
    local theme_name_file="$HOME/.config/omarchy/current/theme.name"
    if [[ -f "$theme_name_file" ]]; then
      local restored_theme
      restored_theme="$(cat "$theme_name_file")"
      if [[ -n "$restored_theme" ]]; then
        _info "Reapplying theme" "$restored_theme"
        omarchy-theme-set "$restored_theme" >/dev/null 2>&1 || true
        _ok "Theme '$restored_theme' applied to running session"
      fi
    fi
  fi

  prompt_reboot
}

# ── Restore from local tarball (legacy) ──
restore_local(){
  local a="${1:-}"
  if [[ -z "$a" ]]; then
    a="$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.zst "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)"
  fi
  [[ -f "$a" ]] || { echo "No local backups found."; return 1; }
  local tmp
  tmp="$(mktemp -d)"
  tar -xpf "$a" -C "$tmp"
  while IFS= read -r p; do
    local x="${p/#\~/$HOME}"
    [[ -e "$x" ]] || mkdir -p "$(dirname "$x")"
  done < <(read_includes)
  rsync -aHAX --info=NAME2 "$tmp/" "$HOME/"
  rm -rf "$tmp"
  _ok "Restore complete from local backup: $(basename "$a")"

  # Detect old home from symlinks and fix paths if username changed
  local old_home=""
  old_home="$(find "$HOME/.config" -type l -exec readlink {} \; 2>/dev/null \
    | grep -oP '^/home/[^/]+' | grep -vF "$HOME" | head -n1)" || true
  if [[ -n "$old_home" && "$old_home" != "$HOME" ]]; then
    # Create a temporary log-like input for fix_restored_paths
    local tmp_log
    tmp_log="$(mktemp)"
    echo "Home:        $old_home" > "$tmp_log"
    fix_restored_paths "$tmp_log"
    rm -f "$tmp_log"
  fi

  # Reapply omarchy theme so the restored theme takes effect in the running session
  if have omarchy-theme-set; then
    local theme_name_file="$HOME/.config/omarchy/current/theme.name"
    if [[ -f "$theme_name_file" ]]; then
      local restored_theme
      restored_theme="$(cat "$theme_name_file")"
      if [[ -n "$restored_theme" ]]; then
        _info "Reapplying theme" "$restored_theme"
        omarchy-theme-set "$restored_theme" >/dev/null 2>&1 || true
        _ok "Theme '$restored_theme' applied to running session"
      fi
    fi
  fi

  prompt_reboot
}

# ── Auto-detect: scan mounted drives for redpill snapshots ──
auto_detect_destination(){
  scan_drives
  local i
  for i in "${!_scan_dev[@]}"; do
    local mnt="${_scan_mount[$i]}"
    [[ "$mnt" != "(not mounted)" ]] || continue
    if [[ -d "$mnt/redpill/snapshots" ]]; then
      echo "$mnt"
      return 0
    fi
  done
  return 1
}

# ── Unified restore: try external drive first, fall back to local ──
restore(){
  local arg="${1:-}"
  # If given a .tar.zst or .tar.gz file, use local restore
  if [[ -n "$arg" && "$arg" == *.tar.* ]]; then
    restore_local "$arg"
    return
  fi
  # Try configured destination
  if read_destination >/dev/null 2>&1; then
    local dest
    dest="$(read_destination)"
    if [[ -d "$dest/redpill/snapshots" ]]; then
      restore_snapshot "$arg"
      return
    fi
  fi
  # No destination configured (or not mounted) — scan for drives with redpill snapshots
  local detected
  if detected="$(auto_detect_destination)"; then
    _ok "Found redpill snapshots on: $detected"
    echo "$detected" > "$DEST_FILE"
    printf '  %sSaved as backup destination.%s\n' "$_c_dim" "$_c_reset"
    restore_snapshot "$arg"
    return
  fi
  # No auto-detect — offer to set up destination (drive may need mounting)
  _warn "No backup drive found."
  printf '  %sYour drive may need to be mounted. Setting up destination...%s\n' "$_c_dim" "$_c_reset"
  echo
  if set_destination; then
    local dest
    dest="$(read_destination)" || { _err "Destination not set."; return 1; }
    if [[ -d "$dest/redpill/snapshots" ]]; then
      restore_snapshot "$arg"
      return
    fi
  fi
  # Fall back to local tarball
  _warn "No external drive snapshots available. Falling back to local backup."
  restore_local "$arg"
}

# ── Toggle auto-backup on shutdown ──
toggle_autobackup(){
  local svc="redpill-autobackup"
  local svc_file="/etc/systemd/system/${svc}.service"

  if systemctl is-enabled "$svc" &>/dev/null; then
    _header "AUTO-BACKUP ON SHUTDOWN"
    _info "Status" "${_c_green}enabled${_c_reset}"
    echo
    printf '  A full backup runs automatically every shutdown/reboot.\n'
    printf '  %s(Skips silently if drive is unplugged or no first backup done)%s\n' "$_c_dim" "$_c_reset"
    echo
    read -r -p "  Disable auto-backup? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || return 0
    sudo systemctl disable "$svc"
    _ok "Auto-backup on shutdown disabled (takes effect next boot)"
  else
    _header "AUTO-BACKUP ON SHUTDOWN"
    _info "Status" "${_c_dim}disabled${_c_reset}"
    echo
    printf '  When enabled, a full backup runs automatically every time\n'
    printf '  you shut down or reboot (if the drive is plugged in).\n'
    printf '  %sSkips silently if no first backup has been done yet.%s\n' "$_c_dim" "$_c_reset"
    echo
    if [[ ! -f "$svc_file" ]]; then
      _err "Service not installed. Re-run: bash ~/Downloads/Redpill.sh"
      return 1
    fi
    read -r -p "  Enable auto-backup? [Y/n] " confirm
    [[ "${confirm,,}" == "n" ]] && return 0
    sudo systemctl enable --now "$svc"
    _ok "Auto-backup on shutdown enabled"
  fi
}

# ── TUI ──
tui(){
  # On launch: if no destination configured, scan for drives and offer setup
  if ! read_destination >/dev/null 2>&1; then
    scan_drives
    if (( ${#_scan_dev[@]} > 0 )); then
      local drive_summary="${#_scan_dev[@]} drive(s) detected"
      if command -v whiptail >/dev/null; then
        if whiptail --title "$APP_TITLE" --yesno "No backup destination set.\n$drive_summary — set one up now?" 10 50; then
          set_destination || true
        fi
      else
        echo "No backup destination set. $drive_summary."
        read -r -p "Set one up now? [Y/n] " yn
        [[ "${yn,,}" == "n" ]] || set_destination || true
      fi
    fi
  fi

  if command -v whiptail >/dev/null; then
    while true; do
      local choice
      local ab_tag="OFF"
      systemctl is-enabled redpill-autobackup &>/dev/null && ab_tag="ON"
      choice=$(whiptail --title "$APP_TITLE" --menu "Choose" 26 70 14 \
        1 "Backup configs only" \
        2 "Backup user data only" \
        3 "Backup everything" \
        4 "Restore (choose)" \
        5 "List backups" \
        6 "Delete backups" \
        7 "Verify backup" \
        8 "Edit include list" \
        9 "Edit exclude list" \
        10 "Set backup destination" \
        11 "Auto-backup on shutdown [$ab_tag]" \
        12 "Show paths" \
        13 "Exit" \
        3>&1 1>&2 2>&3) || break

      case "$choice" in
        1|2|3)
          if ! read_destination >/dev/null 2>&1; then
            if whiptail --title "$APP_TITLE" --yesno "No backup destination set.\nSet one now?" 10 50; then
              set_destination || continue
            else
              continue
            fi
          fi
          local bk_mode
          case "$choice" in
            1) bk_mode="configs" ;;
            2) bk_mode="data" ;;
            3) bk_mode="all" ;;
          esac
          estimate_backup "$bk_mode" || { _pause; continue; }
          echo
          read -r -p "  Proceed with backup? [Y/n] " confirm
          [[ "${confirm,,}" == "n" ]] && continue
          pre_backup_note
          mk_backup "$bk_mode"
          _pause
          ;;
        4)
          # Collect external snapshots
          local -a all_items=() all_labels=()
          local idx=0

          # Find destination: configured, auto-detect, or prompt to set up
          local dest=""
          if read_destination >/dev/null 2>&1; then
            dest="$(read_destination)"
          elif dest="$(auto_detect_destination)"; then
            echo "$dest" > "$DEST_FILE"
          else
            if whiptail --title "$APP_TITLE" --yesno "No backup drive found.\nSet up a backup destination to find your snapshots?" 10 55; then
              set_destination || true
              read_destination >/dev/null 2>&1 && dest="$(read_destination)"
            fi
          fi

          if [[ -n "$dest" ]]; then
            local snap_dir="$dest/redpill/snapshots"
            if [[ -d "$snap_dir" ]]; then
              while IFS= read -r d; do
                local name smode="" mode_label=""
                name="$(basename "$d")"
                smode="$(_snap_mode "$d")"
                case "$smode" in
                  configs) mode_label="configs" ;; data) mode_label="data" ;; all) mode_label="full" ;; *) mode_label="?" ;;
                esac
                all_items+=("snap:$name")
                idx=$((idx + 1))
                all_labels+=("$idx" "[Drive] $name [$mode_label]")
              done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort -r)
            fi
          fi

          # Collect local tarballs
          while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            idx=$((idx + 1))
            all_items+=("local:$f")
            all_labels+=("$idx" "[Local] $(basename "$f")")
          done < <(ls -1t "$LOCAL_BACKUP_DIR"/*.tar.zst "$LOCAL_BACKUP_DIR"/*.tar.gz 2>/dev/null || true)

          if (( ${#all_items[@]} == 0 )); then
            whiptail --title "$APP_TITLE" --msgbox "No backups found." 8 40
            continue
          fi

          local pick
          pick=$(whiptail --title "$APP_TITLE" --menu "Select backup to restore" 20 100 12 "${all_labels[@]}" 3>&1 1>&2 2>&3) || continue

          local selected="${all_items[$((pick-1))]}"
          local stype="${selected%%:*}" sval="${selected#*:}"

          if [[ "$stype" == "snap" ]]; then
            restore_snapshot "$sval"
          else
            restore_local "$sval"
          fi
          _pause
          ;;
        5)
          _header "EXTERNAL DRIVE SNAPSHOTS"
          list_snapshots 2>/dev/null || printf '  %s(none)%s\n' "$_c_dim" "$_c_reset"
          _header "LOCAL CONFIG BACKUPS"
          local -a local_files=()
          mapfile -t local_files < <(list_local)
          if (( ${#local_files[@]} == 0 )); then
            printf '  %s(none)%s\n' "$_c_dim" "$_c_reset"
          else
            local li=0
            for lf in "${local_files[@]}"; do
              [[ -n "$lf" ]] || continue
              li=$((li + 1))
              local lf_size
              lf_size="$(du -sh "$lf" 2>/dev/null | cut -f1)" || lf_size="?"
              printf '  %s%2d.%s  %s  %s(%s)%s\n' "$_c_dim" "$li" "$_c_reset" "$(basename "$lf")" "$_c_dim" "$lf_size" "$_c_reset"
            done
          fi
          _pause
          ;;
        6) delete_backups || true; _pause ;;
        7) verify_backup || true; _pause ;;
        8) "$(tui_editor)" "$INCLUDES_FILE" ;;
        9) "$(tui_editor)" "$EXCLUDES_FILE" ;;
        10) set_destination || true; _pause ;;
        11) toggle_autobackup || true; _pause ;;
        12)
          local dest_display
          dest_display="$(read_destination 2>/dev/null)" || dest_display="(not set)"
          _header "PATHS & CONFIGURATION"
          _info "Destination"      "$dest_display"
          _info "Local backups"    "$LOCAL_BACKUP_DIR"
          _info "Config dir"       "$CONF_DIR"
          _info "Includes file"    "$INCLUDES_FILE"
          _info "Excludes file"    "$EXCLUDES_FILE"
          _info "Destination file" "$DEST_FILE"
          _pause
          ;;
        13) break ;;
      esac
    done
  else
    # Fallback: no whiptail
    PS3="redpill> "
    select a in "Backup configs only" "Backup user data only" "Backup everything" "Restore (latest)" "List backups" "Delete backups" "Verify backup" "Edit include list" "Edit exclude list" "Set backup destination" "Auto-backup on shutdown" "Show paths" "Quit"; do
      case "$REPLY" in
        1|2|3)
          if ! read_destination >/dev/null 2>&1; then
            echo "No backup destination set."
            set_destination || continue
          fi
          local bk_mode
          case "$REPLY" in
            1) bk_mode="configs" ;;
            2) bk_mode="data" ;;
            3) bk_mode="all" ;;
          esac
          estimate_backup "$bk_mode" || continue
          echo
          read -r -p "  Proceed with backup? [Y/n] " confirm
          [[ "${confirm,,}" == "n" ]] && continue
          pre_backup_note; mk_backup "$bk_mode"
          ;;
        4) restore ;;
        5)
          _header "EXTERNAL DRIVE SNAPSHOTS"
          list_snapshots 2>/dev/null || printf '  %s(none)%s\n' "$_c_dim" "$_c_reset"
          _header "LOCAL CONFIG BACKUPS"
          list_local || printf '  %s(none)%s\n' "$_c_dim" "$_c_reset"
          ;;
        6) delete_backups || true ;;
        7) verify_backup || true ;;
        8) "$(tui_editor)" "$INCLUDES_FILE" ;;
        9) "$(tui_editor)" "$EXCLUDES_FILE" ;;
        10) set_destination || true ;;
        11) toggle_autobackup || true ;;
        12)
          local dest_display
          dest_display="$(read_destination 2>/dev/null)" || dest_display="(not set)"
          _header "PATHS & CONFIGURATION"
          _info "Destination"      "$dest_display"
          _info "Local backups"    "$LOCAL_BACKUP_DIR"
          _info "Config dir"       "$CONF_DIR"
          _info "Includes file"    "$INCLUDES_FILE"
          _info "Excludes file"    "$EXCLUDES_FILE"
          _info "Destination file" "$DEST_FILE"
          ;;
        13) break ;;
        *) continue ;;
      esac
    done
  fi
}

# ── CLI dispatch ──
case "${1:-tui}" in
  tui)           tui ;;
  backup)        estimate_backup "${2:-all}" && mk_backup "${2:-all}" ;;
  estimate)      estimate_backup "${2:-all}" ;;
  config-backup) config_backup "${2:-}" ;;
  list)          list_snapshots 2>/dev/null || true; echo; list_local ;;
  restore)       restore "${2:-}" ;;
  verify)        verify_backup ;;
  includes)      "$(tui_editor)" "$INCLUDES_FILE" ;;
  excludes)      "$(tui_editor)" "$EXCLUDES_FILE" ;;
  autobackup)    mk_backup "${2:-all}" ;;
  destination)   set_destination ;;
  where)
    dest_display="$(read_destination 2>/dev/null)" || dest_display="(not set)"
    _header "PATHS & CONFIGURATION"
    _info "Destination"      "$dest_display"
    _info "Local backups"    "$LOCAL_BACKUP_DIR"
    _info "Config dir"       "$CONF_DIR"
    _info "Includes file"    "$INCLUDES_FILE"
    _info "Excludes file"    "$EXCLUDES_FILE"
    _info "Destination file" "$DEST_FILE"
    ;;
  *) echo "Usage: redpill [tui|backup [configs|data|all]|autobackup [configs|data|all]|estimate [configs|data|all]|config-backup|restore [FILE|SNAP]|verify|list|includes|excludes|destination|where]" ;;
esac
BASH

if ! sudo chmod +x /usr/local/bin/redpill; then
  echo "Error: Failed to make redpill executable" >&2
  exit 1
fi

# 2) bluepill (TTY restore with 5s quote) — tries external drive, falls back to local
sudo tee /usr/local/bin/bluepill >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo
echo 'You take the blue pill, the story ends, you wake up in your bed and believe whatever you want to believe'
sleep 5
exec redpill restore "$@"
BASH

if ! sudo chmod +x /usr/local/bin/bluepill; then
  echo "Error: Failed to make bluepill executable" >&2
  exit 1
fi

# 3) Applications entry — write to BOTH system & user dirs
USER_DESK="$HOME/.local/share/applications/redpill.desktop"
SYS_DESK="/usr/share/applications/redpill.desktop"

mkdir -p "$(dirname "$USER_DESK")"
cat > "$USER_DESK" <<'DESK'
[Desktop Entry]
Name=RED PILL
Comment=Unified backup & restore for Hyprland configs and user data
Exec=alacritty --title "RED PILL" -e redpill
Terminal=false
Type=Application
Categories=System;Utility;
NoDisplay=false
StartupNotify=false
Keywords=hyprland;backup;restore;configs;redpill;bluepill;rsync;
DESK

if ! sudo tee "$SYS_DESK" >/dev/null <<'DESK'; then
[Desktop Entry]
Name=RED PILL
Comment=Unified backup & restore for Hyprland configs and user data
Exec=alacritty --title "RED PILL" -e redpill
Terminal=false
Type=Application
Categories=System;Utility;
NoDisplay=false
StartupNotify=false
Keywords=hyprland;backup;restore;configs;redpill;bluepill;rsync;
DESK
  echo "Warning: Failed to create system desktop entry" >&2
fi

update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# 4) Walker: unhide Applications (sed-only) + add custom command safety net
WCONF="$HOME/.config/walker/config.toml"
mkdir -p "$(dirname "$WCONF")"

if [ ! -f "$WCONF" ]; then
  cat >"$WCONF" <<'TOML'
[builtins.applications]
launch_prefix = "uwsm app -- "
hidden = false

[builtins.custom_commands]
hidden = false

[[builtins.custom_commands.entries]]
label = "RED PILL"
command = "alacritty --title 'RED PILL' -e redpill"
keywords = ["redpill","backup","restore","hyprland"]
icon = ""
TOML
else
  if grep -q '^\[builtins\.applications\]' "$WCONF"; then
    sed -i '/^\[builtins\.applications\]/,/^\[/{s/^\s*hidden\s*=.*/hidden = false/}' "$WCONF"
    if ! sed -n '/^\[builtins\.applications\]/,/^\[/{/^\s*hidden\s*=/p}' "$WCONF" | grep -q .; then
      sed -i '/^\[builtins\.applications\]/a hidden = false' "$WCONF"
    fi
    if ! sed -n '/^\[builtins\.applications\]/,/^\[/{/^\s*launch_prefix\s*=/p}' "$WCONF" | grep -q .; then
      sed -i '/^\[builtins\.applications\]/a launch_prefix = "uwsm app -- "' "$WCONF"
    fi
  else
    cat >>"$WCONF" <<'TOML'

[builtins.applications]
launch_prefix = "uwsm app -- "
hidden = false
TOML
  fi

  if ! grep -q '^\[builtins\.custom_commands\]' "$WCONF"; then
    cat >>"$WCONF" <<'TOML'

[builtins.custom_commands]
hidden = false
TOML
  fi
  if ! grep -q 'label = "RED PILL"' "$WCONF"; then
    cat >>"$WCONF" <<'TOML'

[[builtins.custom_commands.entries]]
label = "RED PILL"
command = "alacritty --title 'RED PILL' -e redpill"
keywords = ["redpill","backup","restore","hyprland"]
icon = ""
TOML
  fi
fi

# 5) Hyprland keybinding: Super+Alt+B → floating RED PILL window
BINDINGS_FILE="$HOME/.config/hypr/bindings.conf"

# Detect preferred terminal with --title support
REDPILL_TERM=""
if command -v ghostty >/dev/null 2>&1; then
  REDPILL_TERM="ghostty --title='RED PILL' -e"
elif command -v kitty >/dev/null 2>&1; then
  REDPILL_TERM="kitty --title='RED PILL' -e"
elif command -v alacritty >/dev/null 2>&1; then
  REDPILL_TERM="alacritty --title='RED PILL' -e"
elif command -v foot >/dev/null 2>&1; then
  REDPILL_TERM="foot --title='RED PILL' --"
fi

if [[ -n "$REDPILL_TERM" && -f "$BINDINGS_FILE" ]]; then
  if ! grep -q "# Red Pill Backup TUI" "$BINDINGS_FILE"; then
    echo "Adding keybinding (Super+Alt+B) to $BINDINGS_FILE"
    {
      echo ""
      echo "# Red Pill Backup TUI"
      echo "windowrule = match:title RED PILL, float on"
      echo "windowrule = match:title RED PILL, size 800 600"
      echo "windowrule = match:title RED PILL, center on"
      echo "windowrule = match:title RED PILL, pin on"
      echo "bindd = SUPER ALT, B, Red Pill Backup, exec, $REDPILL_TERM redpill"
      echo "# End Red Pill Backup TUI"
    } >> "$BINDINGS_FILE"
  fi

  # Apply dynamically so no Hyprland reload needed
  if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors -j &>/dev/null; then
    hyprctl keyword unbind "SUPER ALT, B" >/dev/null 2>&1 || true
    hyprctl keyword windowrule "match:title RED PILL, float on" >/dev/null 2>&1 || true
    hyprctl keyword windowrule "match:title RED PILL, size 800 600" >/dev/null 2>&1 || true
    hyprctl keyword windowrule "match:title RED PILL, center on" >/dev/null 2>&1 || true
    hyprctl keyword windowrule "match:title RED PILL, pin on" >/dev/null 2>&1 || true
    hyprctl keyword bindd "SUPER ALT, B, Red Pill Backup, exec, $REDPILL_TERM redpill" >/dev/null 2>&1 || true
  fi
fi

# 6) Config directory (no custom theming - uses system defaults)
mkdir -p "$HOME/.config/redpill"

# 7) Create RECOVERY.txt guide
cat > "$HOME/.config/redpill/RECOVERY.txt" <<'RECOVERY'
RED PILL - Recovery Guide
==============================

NEW MACHINE RESTORE:
  1. Install omarchy on the new machine
  2. Plug in your backup drive and mount it
  3. Run:  bash /run/media/$USER/<drive>/redpill/restore.sh
  4. Log out and back in (or reboot) to apply configs
  5. Re-install Red Pill:
       bash ~/Downloads/red\ pill\ update\ /Redpill.sh

  The restore script is self-contained — it only needs rsync
  (which ships with omarchy). No install required.

QUICK RESTORE (same machine, TTY):
  1. Press Ctrl+Alt+F2 to switch to TTY2
  2. Login with your username and password
  3. Run: bluepill

  This restores from the latest snapshot on your external drive.
  If no drive is found, it falls back to the latest local config backup.

MANUAL RESTORE:
  List all backups:
    redpill list

  Restore a specific drive snapshot:
    redpill restore 2026-02-08_14-30-00

  Restore a specific local tarball:
    redpill restore /path/to/backup.tar.zst

VERIFY BACKUP INTEGRITY:
    redpill verify

CONFIG-ONLY BACKUP (no external drive needed):
    redpill config-backup

AUTO-BACKUP ON SHUTDOWN:
  A systemd service runs a full backup every time you shut down
  or reboot — but only after your first manual backup is done.
  If the backup drive isn't plugged in, it silently skips.

  Check status:   systemctl status redpill-autobackup
  View last log:  journalctl -u redpill-autobackup -b -1
  Test manually:  sudo systemctl stop redpill-autobackup
  Disable:        sudo systemctl disable redpill-autobackup

SETUP:
  Set backup destination (external drive):
    redpill destination

  Edit what gets backed up:
    redpill includes

  Edit exclusion patterns:
    redpill excludes

PATHS:
  Backup destination:  ~/.config/redpill/destination.conf
  Include list:        ~/.config/redpill/includes.conf
  Exclude patterns:    ~/.config/redpill/excludes.conf
  Local backups:       ~/.local/state/redpill/backups/
  Config dir:          ~/.config/redpill/

SNAPSHOT STRUCTURE (on external drive):
  <destination>/redpill/
  ├── restore.sh                 # standalone restore for new machines
  ├── latest/                    # symlink to most recent snapshot
  └── snapshots/
      ├── 2026-02-08_14-30-00/   # full tree (hardlinked to prev)
      │   ├── checksums.xxh128   # integrity manifest
      │   └── backup.log         # backup report
      └── 2026-02-08_10-00-00/

  Each snapshot is a complete directory tree. Unchanged files are
  hardlinked to the previous snapshot, so they use no extra disk space.
  You can browse any snapshot directly in a file manager.
RECOVERY

# 8) Auto-backup on shutdown — systemd service + wrapper script
# Wrapper: checks preconditions silently, runs full backup if ready
sudo tee /usr/local/bin/redpill-autobackup >/dev/null <<'AUTOBACKUP'
#!/usr/bin/env bash
set -euo pipefail

# Resolve the real user (systemd sets USER/HOME via service env)
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/redpill"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/redpill"
DEST_FILE="$CONF_DIR/destination.conf"
STATUS_FILE="$STATE_DIR/last_autobackup"
LAST_BACKUP_FILE="$STATE_DIR/last_backup"
mkdir -p "$STATE_DIR"

# Write status file and exit
write_status(){
  local status="$1" reason="${2:-}"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "status=$status"
    [[ -n "$reason" ]] && echo "reason=$reason" || true
  } > "$STATUS_FILE"
}

# Forward SIGTERM to entire process group so rsync dies with us
cleanup(){
  write_status error "signal_killed" 2>/dev/null || true
  kill -- -$$ 2>/dev/null || true
  exit 1
}
trap cleanup SIGTERM SIGINT

# Precondition 1: destination configured
if [[ ! -f "$DEST_FILE" ]]; then
  write_status skipped no_destination
  exit 0
fi
DEST="$(head -n1 "$DEST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "$DEST" ]]; then
  write_status skipped no_destination
  exit 0
fi

# Precondition 2: destination is mounted/accessible
if [[ ! -d "$DEST" ]]; then
  write_status skipped drive_not_mounted
  exit 0
fi

# Precondition 3: at least one snapshot exists (first backup was done manually)
SNAP_DIR="$DEST/redpill/snapshots"
if [[ ! -d "$SNAP_DIR" ]]; then
  write_status skipped no_snapshots
  exit 0
fi
SNAP_COUNT="$(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | wc -l)"
if (( SNAP_COUNT == 0 )); then
  write_status skipped no_snapshots
  exit 0
fi

# All preconditions met — run full backup (autobackup skips estimate dry-run + checksums)
echo "redpill-autobackup: starting full backup to $DEST"
export REDPILL_AUTOBACKUP=1
if /usr/local/bin/redpill autobackup all; then
  trap - SIGTERM SIGINT
  write_status success
  date -Iseconds > "$LAST_BACKUP_FILE"
else
  write_status error "backup_failed"
fi
AUTOBACKUP
sudo chmod +x /usr/local/bin/redpill-autobackup

# Systemd service: ExecStop fires on shutdown/reboot
sudo tee /etc/systemd/system/redpill-autobackup.service >/dev/null <<EOF
[Unit]
Description=Red Pill auto-backup on shutdown
Before=umount.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/redpill-autobackup
User=$USER
Group=$(id -gn)
Environment=HOME=$HOME
Environment=XDG_CONFIG_HOME=$HOME/.config
Environment=XDG_STATE_HOME=$HOME/.local/state
Environment=USER=$USER
KillMode=mixed
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
# Don't enable here — user opts in via TUI menu option 11

# 9) Login notification checker — reminds user to plug in backup drive
sudo tee /usr/local/bin/redpill-notify >/dev/null <<'NOTIFY'
#!/usr/bin/env bash
set -euo pipefail

# Wait for notification daemon (mako) to be ready
sleep 5

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/redpill"
LAST_BACKUP_FILE="$STATE_DIR/last_backup"

# If auto-backup isn't enabled, nothing to nag about
systemctl is-enabled redpill-autobackup &>/dev/null || exit 0

# If no last_backup file, this is the first run — remind to do a backup
if [[ ! -f "$LAST_BACKUP_FILE" ]]; then
  notify-send -a "Red Pill" "Red Pill Backup" \
    "No backup on record — plug in your drive and run Red Pill"
  exit 0
fi

# Parse last backup timestamp and check age
last_ts="$(head -n1 "$LAST_BACKUP_FILE" 2>/dev/null)" || exit 0
[[ -n "$last_ts" ]] || exit 0

last_epoch="$(date -d "$last_ts" +%s 2>/dev/null)" || exit 0
now_epoch="$(date +%s)"
age_days=$(( (now_epoch - last_epoch) / 86400 ))

if (( age_days >= 7 )); then
  notify-send -a "Red Pill" "Red Pill Backup" \
    "No backup in ${age_days} days — plug in your drive"
fi
NOTIFY
sudo chmod +x /usr/local/bin/redpill-notify

# Add redpill-notify to Hyprland autostart (once only)
AUTOSTART_FILE="$HOME/.config/hypr/autostart.conf"
if [[ -f "$AUTOSTART_FILE" ]]; then
  if ! grep -q 'redpill-notify' "$AUTOSTART_FILE"; then
    echo "Adding redpill-notify to $AUTOSTART_FILE"
    {
      echo ""
      echo "# Red Pill backup reminder on login"
      echo "exec-once = redpill-notify"
    } >> "$AUTOSTART_FILE"
  fi
fi

# 10) Reindex and restart Walker so the new entry is searchable immediately
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
# Kill walker more safely - only exact process name match
pkill -x walker >/dev/null 2>&1 || true

echo "Installed:"
echo "  - redpill (TUI) at /usr/local/bin/redpill"
echo "  - bluepill (quick restore) at /usr/local/bin/bluepill"
echo "  - Super+Alt+B keybinding (floating window)"
echo "  - Auto-backup on shutdown (enable in menu option 11)"
echo "  - Backup reminder notifications on login"
echo "  - TTY guide at ~/.config/redpill/RECOVERY.txt"
echo ""
echo "Next steps:"
echo "  1. Press Super+Alt+B (or run: redpill)"
echo "  2. Set your backup destination (option 10)"
echo "  3. Run 'Backup configs/data/everything'"
echo "  4. Enable auto-backup on shutdown (option 11 in menu)"
echo ""
echo "Open your launcher (Super + Space) and search: RED PILL"
