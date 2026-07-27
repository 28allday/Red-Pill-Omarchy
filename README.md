# Red Pill - Backup & Restore for Omarchy


## 🎬 Video Demo

[![Watch the video](https://img.youtube.com/vi/yHb9qqGs4dU/0.jpg)](https://youtu.be/yHb9qqGs4dU)

*"You take the red pill, you stay in Hyprland and I show you how deep the rabbit-hole goes..."*

A unified backup and restore system for [Omarchy](https://omarchy.com). Backs up configs and user data to external drives using rsync hardlink snapshots - each backup is a full browseable directory tree, but unchanged files are deduplicated via hardlinks so they use no extra disk space.

## Features

- **Three backup modes**: configs only, user data only, or everything
- **Rsync hardlink snapshots**: space-efficient incremental backups on external drives
- **TUI interface**: whiptail-based menu with full CLI fallback
- **Auto-backup on shutdown**: systemd service runs a full backup every shutdown/reboot
- **Backup verification**: checksum manifests (xxh128 or sha256) with integrity checking
- **New machine restore**: standalone `restore.sh` written to the backup drive - works without Red Pill installed
- **Username migration**: automatically fixes paths when restoring to a different username/home directory
- **Theme restoration**: records the active Omarchy theme in the snapshot and reapplies it after restore
- **Login notifications**: reminds you if no backup in 7+ days
- **Launcher integration**: searchable from the Omarchy launcher (`Super+Space`)
- **Hyprland keybind**: `Super+Alt+B` opens a floating TUI window
- **Omarchy 3 and 4**: detects the Lua config (Omarchy 4 / Quickshell) or the older `.conf` layout and writes whichever the machine actually reads

## Requirements

- **OS**: [Omarchy](https://omarchy.com) 3 or 4 (Arch Linux)
- **Dependencies**: `rsync`, `libnewt` (whiptail), `zstd`, `desktop-file-utils` (all ship with Omarchy)
- **Terminal**: whichever one you use — the TUI is launched through `xdg-terminal-exec`, falling back to ghostty/kitty/alacritty/foot
- **Backup destination**: any external drive (ext4, NTFS, btrfs, exFAT, etc.)

## Quick Start

```bash
git clone https://github.com/28allday/Red-Pill-Omarchy.git
cd Red-Pill-Omarchy
bash Redpill_update.sh
```

Then:
1. Press `Super+Alt+B` (or run `redpill`)
2. Set your backup destination (option 10)
3. Run your first backup
4. Optionally enable auto-backup on shutdown (option 11)

## Usage

### Keybindings

| Action | Keybind |
|--------|---------|
| Open Red Pill TUI | `Super + Alt + B` |
| Search in launcher | `Super + Space` → type "RED PILL" |

### TUI Menu

The interactive menu provides:

| Option | Description |
|--------|-------------|
| 1 | Backup configs only (~/.config, ~/.ssh, ~/.gnupg, etc.) |
| 2 | Backup user data only (Documents, Pictures, Music, etc.) |
| 3 | Backup everything (configs + user data) |
| 4 | Restore (choose from snapshots or local backups) |
| 5 | List all backups (drive snapshots + local tarballs) |
| 6 | Delete backups (multi-select with confirmation) |
| 7 | Verify backup integrity (checksum validation) |
| 8 | Edit include list |
| 9 | Edit exclude list |
| 10 | Set backup destination (drive selection or manual path) |
| 11 | Toggle auto-backup on shutdown |
| 12 | Show paths and configuration |

### CLI Commands

```bash
redpill                          # Open TUI
redpill backup [configs|data|all]  # Run backup
redpill estimate [configs|data|all] # Dry-run estimate
redpill restore [SNAPSHOT|FILE]  # Restore from snapshot or tarball
redpill verify                   # Verify backup checksums
redpill list                     # List all backups
redpill config-backup            # Local config tarball (no drive needed)
redpill includes                 # Edit include list
redpill excludes                 # Edit exclude list
redpill destination              # Set backup destination
redpill where                    # Show all paths
```

### Quick Restore (TTY)

```bash
bluepill
```

Shows the Matrix quote, then restores from the latest snapshot on your external drive (falls back to local backup if no drive found). Works from a TTY if your desktop is broken.

## What Gets Installed

`Redpill_update.sh` installs the following:

### Binaries

| Path | Purpose |
|------|---------|
| `/usr/local/bin/redpill` | Main TUI and CLI backup/restore tool |
| `/usr/local/bin/bluepill` | Quick restore shortcut (TTY-friendly) |
| `/usr/local/bin/redpill-autobackup` | Shutdown auto-backup wrapper |
| `/usr/local/bin/redpill-notify` | Login notification checker |

### Desktop Integration

| Path | Purpose |
|------|---------|
| `~/.local/share/applications/redpill.desktop` | User application menu entry |
| `/usr/share/applications/redpill.desktop` | System application menu entry |
| `~/.config/hypr/bindings.lua` | Hyprland keybind (`Super+Alt+B`) + window rules — Omarchy 4 |
| `~/.config/hypr/autostart.lua` | Login notification autostart — Omarchy 4 |
| `~/.config/hypr/bindings.conf` | Keybind + window rules — Omarchy 3 |
| `~/.config/hypr/autostart.conf` | Login notification autostart — Omarchy 3 |
| `~/.config/walker/config.toml` | Walker custom command entry — Omarchy 3 only |

### Systemd Service

| Path | Purpose |
|------|---------|
| `/etc/systemd/system/redpill-autobackup.service` | Runs full backup on shutdown/reboot |

### Config & State

| Path | Purpose |
|------|---------|
| `~/.config/redpill/includes.conf` | Paths to back up |
| `~/.config/redpill/excludes.conf` | Exclusion patterns |
| `~/.config/redpill/destination.conf` | Backup destination path |
| `~/.config/redpill/RECOVERY.txt` | Recovery guide |
| `~/.local/state/redpill/backups/` | Local config tarballs |
| `~/.local/state/redpill/last_backup` | Timestamp of last backup |

## How It Works

### Backup Process

1. **Estimate** - dry-run rsync calculates total size, changed files, and new data to transfer
2. **Snapshot** - rsync copies files to a timestamped directory, hardlinking unchanged files to the previous snapshot
3. **Checksums** - xxh128 (or sha256) manifest generated in background for integrity verification
4. **Latest symlink** - atomically updated to point to the new snapshot
5. **Standalone restore script** - written to the drive root for new machine recovery

### Snapshot Structure on External Drive

```
<drive>/redpill/
├── restore.sh                     # Standalone restore (no install needed)
├── latest -> snapshots/2026-02-08_14-30-00
└── snapshots/
    ├── 2026-02-08_14-30-00/       # Full directory tree
    │   ├── .config/               # All backed-up files
    │   ├── Documents/
    │   ├── backup.log             # Backup metadata and report
    │   └── checksums.xxh128       # Integrity manifest
    └── 2026-02-07_10-00-00/       # Previous snapshot (hardlinked)
        └── ...
```

Each snapshot is a complete, browseable copy. You can open any snapshot in a file manager and copy files manually if needed.

### Hardlink Deduplication

If a file hasn't changed between backups, rsync creates a hardlink to the previous snapshot's copy instead of duplicating it. This means:
- Each snapshot looks like a full backup
- Only changed/new files consume additional disk space
- Deleting old snapshots is safe - files are only freed when all hardlinks are removed

### Backup Modes

| Mode | What's included |
|------|----------------|
| **configs** | `~/.config`, `~/.bashrc`, `~/.bash_profile`, `~/.ssh`, `~/.gnupg`, `~/.local/share/fonts`, `~/.local/share/applications` |
| **data** | `~/Documents`, `~/Pictures`, `~/Music`, `~/Videos`, `~/Desktop`, `~/Downloads`, `~/Templates` |
| **all** | Everything above combined |

### Default Exclusions

```
.cache/
.local/state/
node_modules/
__pycache__/
.Trash*/
*.tmp
*.swp
.thumbnails/
```

### Auto-Backup on Shutdown

When enabled, a systemd service runs a full backup every time you shut down or reboot:

- Silently skips if no backup destination is configured
- Silently skips if the backup drive isn't mounted
- Silently skips if no first manual backup has been done
- 10-minute timeout to prevent hanging shutdown
- Kills rsync cleanly on SIGTERM

### New Machine Restore

The standalone `restore.sh` on the backup drive works without Red Pill installed:

1. Install Omarchy on the new machine
2. Mount the backup drive
3. Run: `bash /run/media/$USER/<drive>/redpill/restore.sh`
4. Select a snapshot to restore
5. Reboot

The script handles username changes automatically by fixing symlinks and hardcoded paths in config files.

### Login Notifications

`redpill-notify` runs on each Hyprland login and sends a desktop notification if:
- Auto-backup is enabled but no backup has ever been done
- The last backup was more than 7 days ago

## Uninstalling

```bash
bash Redpill_uninstall.sh
```

The uninstaller removes:
- All binaries from `/usr/local/bin/`
- Desktop entries (user + system)
- Hyprland keybinding and window rules (`.lua` and `.conf` layouts)
- Hyprland autostart entry
- Walker custom command entry (Omarchy 3)
- Systemd auto-backup service
- Optionally: config and state directories

Backup snapshots on external drives are **never** touched.

## Troubleshooting

### Backup destination not found

```bash
# Check if drive is mounted
lsblk

# Mount via udisks
udisksctl mount -b /dev/sda1

# Set destination manually
redpill destination
```

### Auto-backup not running

```bash
# Check service status
systemctl status redpill-autobackup

# View last shutdown backup log
journalctl -u redpill-autobackup -b -1

# Ensure it's enabled
sudo systemctl enable redpill-autobackup
```

### Verify backup integrity

```bash
redpill verify
```

Select a snapshot and the tool will check every file against its stored checksum.

### Restore to different username

Both the TUI restore and standalone `restore.sh` automatically detect username changes and fix:
- Absolute symlinks pointing to the old home directory
- Hardcoded paths in config files under `~/.config/`

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [rsync](https://rsync.samba.org/) - The engine behind hardlink snapshot backups

## License

This project is provided as-is for the Omarchy community.
