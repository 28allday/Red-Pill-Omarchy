#!/usr/bin/env bash
set -euo pipefail

# ===== RED PILL — Uninstaller =====
# Reverses everything done by Redpill_update.sh

_c_green=$'\033[38;2;158;206;106m'
_c_red=$'\033[38;2;247;118;142m'
_c_yellow=$'\033[38;2;224;175;104m'
_c_dim=$'\033[2m'
_c_bold=$'\033[1m'
_c_reset=$'\033[0m'

_hr(){
  printf '%s────────────────────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
}

_ok(){
  printf '  %s✓%s %s\n' "$_c_green" "$_c_reset" "$1"
}

_skip(){
  printf '  %s-%s %s %s(not found)%s\n' "$_c_dim" "$_c_reset" "$1" "$_c_dim" "$_c_reset"
}

_warn(){
  printf '  %s⚠%s %s\n' "$_c_yellow" "$_c_reset" "$1"
}

echo
_hr
printf '  %s%sRED PILL — Uninstaller%s\n' "$_c_bold" "$_c_red" "$_c_reset"
_hr
echo
printf '  This will remove all Red Pill components:\n'
printf '    - /usr/local/bin/redpill, bluepill, redpill-autobackup, redpill-notify\n'
printf '    - Desktop entries (user + system)\n'
printf '    - Hyprland keybinding (Super+Alt+B) and window rules\n'
printf '    - Hyprland autostart entry (redpill-notify)\n'
printf '    - Walker custom command entry\n'
printf '    - Systemd auto-backup service\n'
echo
printf '  %sYour backup data (snapshots on external drives) will NOT be touched.%s\n' "$_c_dim" "$_c_reset"
echo

read -r -p "  Proceed with uninstall? [y/N] " confirm || confirm=""
[[ "${confirm,,}" == "y" ]] || { echo "  Cancelled."; exit 0; }

echo

# 1) Disable and remove systemd service
SVC="redpill-autobackup"
SVC_FILE="/etc/systemd/system/${SVC}.service"
if systemctl is-enabled "$SVC" &>/dev/null; then
  sudo systemctl disable "$SVC" 2>/dev/null || true
  _ok "Disabled systemd service: $SVC"
fi
if systemctl is-active "$SVC" &>/dev/null; then
  sudo systemctl stop "$SVC" 2>/dev/null || true
fi
if [[ -f "$SVC_FILE" ]]; then
  sudo rm -f "$SVC_FILE"
  sudo systemctl daemon-reload
  _ok "Removed $SVC_FILE"
else
  _skip "$SVC_FILE"
fi

# 2) Remove binaries from /usr/local/bin
for bin in redpill bluepill redpill-autobackup redpill-notify; do
  if [[ -f "/usr/local/bin/$bin" ]]; then
    sudo rm -f "/usr/local/bin/$bin"
    _ok "Removed /usr/local/bin/$bin"
  else
    _skip "/usr/local/bin/$bin"
  fi
done

# 3) Remove desktop entries
USER_DESK="$HOME/.local/share/applications/redpill.desktop"
SYS_DESK="/usr/share/applications/redpill.desktop"

if [[ -f "$USER_DESK" ]]; then
  rm -f "$USER_DESK"
  _ok "Removed $USER_DESK"
else
  _skip "$USER_DESK"
fi

if [[ -f "$SYS_DESK" ]]; then
  sudo rm -f "$SYS_DESK"
  _ok "Removed $SYS_DESK"
else
  _skip "$SYS_DESK"
fi

update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# 4) Remove Hyprland keybinding block.
# Omarchy 4 keeps bindings in bindings.lua, Omarchy 3 in bindings.conf — an
# upgraded machine can have both, so clean whichever carries our marker.
_removed_bind=0
_removed_lua=0
for BINDINGS_FILE in "$HOME/.config/hypr/bindings.lua" "$HOME/.config/hypr/bindings.conf"; do
  [[ -f "$BINDINGS_FILE" ]] || continue
  grep -q 'Red Pill Backup TUI' "$BINDINGS_FILE" || continue
  [[ "$BINDINGS_FILE" == *.lua ]] && _removed_lua=1
  # Remove the block between the start and end markers (inclusive), in either
  # comment syntax
  sed -i '/^[-#]* *Red Pill Backup TUI/,/^[-#]* *End Red Pill Backup TUI/d' "$BINDINGS_FILE"
  # Clean up any resulting double blank lines
  sed -i '/^$/N;/^\n$/d' "$BINDINGS_FILE"
  _ok "Removed Red Pill keybinding and window rules from $BINDINGS_FILE"
  _removed_bind=1
done

if (( _removed_bind )); then
  # Remove live Hyprland bindings if running. The Lua parser rejects
  # `hyprctl keyword`, so reload the config there instead.
  if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors -j &>/dev/null; then
    if (( _removed_lua )); then
      hyprctl reload >/dev/null 2>&1 || true
    else
      hyprctl keyword unbind "SUPER ALT, B" >/dev/null 2>&1 || true
    fi
    _ok "Removed live Hyprland keybinding"
  fi
else
  _skip "Hyprland keybinding (not found in bindings.lua or bindings.conf)"
fi

# 5) Remove redpill-notify from Hyprland autostart (both flavours)
_removed_autostart=0
for AUTOSTART_FILE in "$HOME/.config/hypr/autostart.lua" "$HOME/.config/hypr/autostart.conf"; do
  [[ -f "$AUTOSTART_FILE" ]] || continue
  grep -q 'redpill-notify' "$AUTOSTART_FILE" || continue
  sed -i '/Red Pill backup reminder on login/d' "$AUTOSTART_FILE"
  sed -i '/End Red Pill backup reminder/d' "$AUTOSTART_FILE"
  sed -i '/redpill-notify/d' "$AUTOSTART_FILE"
  # Clean up any resulting double blank lines
  sed -i '/^$/N;/^\n$/d' "$AUTOSTART_FILE"
  _ok "Removed redpill-notify from $AUTOSTART_FILE"
  _removed_autostart=1
done
(( _removed_autostart )) || _skip "redpill-notify in Hyprland autostart"

# 6) Remove Walker custom command entry for RED PILL (Omarchy 3 only)
WCONF="$HOME/.config/walker/config.toml"
if [[ -f "$WCONF" ]] && grep -q 'label = "RED PILL"' "$WCONF"; then
  # Remove the [[builtins.custom_commands.entries]] block for RED PILL
  if python3 -c "
import re, sys
wconf = sys.argv[1]
with open(wconf, 'r') as f:
    content = f.read()
content = re.sub(
    r'\n*\[\[builtins\.custom_commands\.entries\]\]\s*\n'
    r'label = \"RED PILL\"\s*\n'
    r'command = .*redpill.*\n'
    r'keywords = .*\n'
    r'icon = .*\n?',
    '', content)
with open(wconf, 'w') as f:
    f.write(content)
" "$WCONF" 2>/dev/null && ! grep -q 'label = "RED PILL"' "$WCONF"; then
    _ok "Removed RED PILL entry from Walker config"
  else
    # Fallback: use sed to remove the lines
    sed -i '/\[\[builtins\.custom_commands\.entries\]\]/{
      N;N;N;N
      /RED PILL/d
    }' "$WCONF"
    _ok "Removed RED PILL entry from Walker config (sed fallback)"
  fi
else
  _skip "RED PILL in Walker config"
fi

# 7) Kill walker to refresh (Omarchy 3 only — Omarchy 4 has no Walker)
command -v walker >/dev/null 2>&1 && pkill -x walker >/dev/null 2>&1 || true

# 8) Ask about config and state directories
echo
_hr
echo
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/redpill"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/redpill"

printf '  %sOptional cleanup:%s\n' "$_c_bold" "$_c_reset"
printf '    Config: %s\n' "$CONF_DIR"
printf '      (includes.conf, excludes.conf, destination.conf, RECOVERY.txt)\n'
printf '    State:  %s\n' "$STATE_DIR"
printf '      (local backup tarballs, last_backup timestamp)\n'
echo

read -r -p "  Remove config and state directories? [y/N] " rm_data || rm_data=""
if [[ "${rm_data,,}" == "y" ]]; then
  if [[ -d "$CONF_DIR" ]]; then
    rm -rf "$CONF_DIR"
    _ok "Removed $CONF_DIR"
  else
    _skip "$CONF_DIR"
  fi
  if [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
    _ok "Removed $STATE_DIR"
  else
    _skip "$STATE_DIR"
  fi
else
  printf '  %sKept config and state directories.%s\n' "$_c_dim" "$_c_reset"
fi

echo
_hr
printf '  %s%sRed Pill has been uninstalled.%s\n' "$_c_bold" "$_c_green" "$_c_reset"
printf '  %sBackup snapshots on external drives were not modified.%s\n' "$_c_dim" "$_c_reset"
_hr
echo
