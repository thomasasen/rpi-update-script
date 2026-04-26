# updaterpi.sh

Safe Raspberry Pi update script for Debian based Raspberry Pi systems.

`updaterpi.sh` updates your system with `apt-get full-upgrade`, checks for risky repository mixes, verifies free disk space, detects reboot requirements more reliably than `/run/reboot-required` alone, and writes a clear log for every run.

The script is built for small Raspberry Pi servers, headless systems, NAS helpers, media servers, automation nodes and similar setups.

## Features

- Interactive dry run by default
- Real update mode with `--live`
- Uses `apt-get full-upgrade`, which is the right update path for Raspberry Pi OS
- Simulates upgrades before installing anything
- Aborts by default if `full-upgrade` wants to remove packages
- Detects mixed APT suites such as `trixie` plus `bookworm`
- Checks free disk space on `/` and `/boot/firmware` or `/boot`
- Detects hard and soft reboot reasons separately
- Checks for changed boot, kernel, initramfs, firmware and EEPROM files
- Uses `needrestart` if installed
- Runs post checks after the update
- Writes timestamped log files
- Cleans up old logs automatically
- Supports optional automatic reboot

## Why this script exists

A simple reboot check like this is not enough:

```bash
test -f /run/reboot-required
```

On Raspberry Pi systems, kernel, firmware, EEPROM, boot files or initramfs updates may not always result in a clear reboot marker.

This script checks several signals:

```text
/run/reboot-required
/var/run/reboot-required
updated kernel packages
updated firmware packages
updated raspi-firmware
updated rpi-eeprom
changed files in /boot or /boot/firmware
needrestart kernel status
needrestart service status
```

That makes the reboot recommendation more accurate.

## Requirements

Target environment:

```text
Raspberry Pi OS
Debian based Raspberry Pi systems
APT based systems
systemd based systems
```

Required tools:

```text
bash
sudo
apt-get
awk
grep
find
sort
tee
systemctl
journalctl
df
dpkg
```

Optional but recommended:

```bash
sudo apt-get install needrestart
```

`needrestart` helps detect services and processes that still use old libraries after an update.

## Installation

Clone the repository:

```bash
git clone https://github.com/<your-user>/<your-repo>.git
cd <your-repo>
chmod +x updaterpi.sh
```

Or copy the script manually and make it executable:

```bash
chmod +x updaterpi.sh
```

## Usage

### Interactive mode

```bash
./updaterpi.sh
```

The script asks at the beginning whether it should run only a dry run or perform the real update.

Default answer is dry run.

### Dry run

```bash
./updaterpi.sh --dry-run
```

This mode only simulates the upgrade.

No packages are installed.

### Live update

```bash
./updaterpi.sh --live
```

Runs the real update without asking for the mode.

### Live update with reboot on hard reboot reasons

```bash
./updaterpi.sh --live --reboot
```

The system only reboots automatically if a hard reboot reason is detected.

Hard reboot reasons include:

```text
kernel update
raspi-firmware update
rpi-eeprom update
initramfs update
boot file changes
firmware package updates
needrestart reports an outdated running kernel
```

### Live update with reboot on soft reboot reasons too

```bash
./updaterpi.sh --live --reboot-soft
```

This also reboots when soft reboot reasons are detected.

Soft reboot reasons include:

```text
OpenSSL update
libssl update
libc update
OpenSSH update
services still using old libraries
```

### Allow package removals

```bash
./updaterpi.sh --live --allow-removals
```

By default, the script aborts if `full-upgrade` wants to remove packages.

This is intentional.

Package removals can be correct, but they should never happen silently on a server.

### Skip autoremove

```bash
./updaterpi.sh --live --no-autoremove
```

Use this if you want to clean unused packages manually later.

## Options

| Option | Description |
|---|---|
| `--dry-run` | Only simulate the upgrade. No package changes. |
| `--live` | Run the real update without asking. |
| `--yes` | Alias for `--live`. |
| `--allow-removals` | Allow package removals during `full-upgrade`. |
| `--reboot` | Reboot automatically only on hard reboot reasons. |
| `--reboot-soft` | Reboot automatically on hard or soft reboot reasons. |
| `--no-autoremove` | Skip `apt-get autoremove`. |
| `--help` | Show help. |

## Environment variables

You can override safety thresholds with environment variables.

| Variable | Default | Description |
|---|---:|---|
| `ROOT_MIN_MB` | `1024` | Minimum free space on `/` in MB. |
| `BOOT_MIN_MB` | `256` | Minimum free space on `/boot/firmware` or `/boot` in MB. |
| `LOG_KEEP_DAYS` | `30` | Delete logs older than this number of days. |
| `LOG_KEEP_COUNT` | `20` | Keep at most this number of recent log files. |
| `LOG_DIR` | `$HOME/updaterpi-logs` | Directory for log files. |

Example:

```bash
ROOT_MIN_MB=2048 BOOT_MIN_MB=512 ./updaterpi.sh --live
```

## Reboot logic

The script separates reboot reasons into two groups.

### Hard reboot reasons

A hard reboot reason means a reboot is the right action.

Examples:

```text
kernel packages changed
raspi-firmware changed
rpi-eeprom changed
initramfs changed
boot files changed
firmware packages changed
needrestart reports a stale kernel
```

Recommended action:

```bash
sudo reboot
```

### Soft reboot reasons

A soft reboot reason means that a full reboot is clean and simple, but selected service restarts may also be enough.

Examples:

```text
libssl update
openssl update
libc update
openssh update
services using old libraries
```

Recommended action:

```bash
sudo reboot
```

Or inspect `needrestart` output and restart affected services manually.

## Repository mix warning

The script checks the configured APT suites.

Example warning:

```text
trixie
bookworm
```

A mixed setup can be valid, but it can also cause dependency problems.

If the script warns about mixed suites, inspect your sources:

```bash
grep -R "^deb " /etc/apt/sources.list /etc/apt/sources.list.d/
```

Also check `.sources` files:

```bash
grep -R "^Suites:" /etc/apt/sources.list.d/
```

## Logs

Every run writes a log file.

Default location:

```text
~/updaterpi-logs/
```

Example:

```text
~/updaterpi-logs/updaterpi-20260426-143012.log
```

Old logs are cleaned automatically based on:

```text
LOG_KEEP_DAYS
LOG_KEEP_COUNT
```

## Safety behavior

The script is intentionally conservative.

It will abort in these cases:

```text
not enough disk space
APT simulation detects package removals without --allow-removals
apt-get check fails
unexpected command failure
```

If the script runs without an interactive terminal and no mode is given, it defaults to dry run.

That prevents accidental unattended live upgrades.

## Recommended workflow

For manual use:

```bash
./updaterpi.sh --dry-run
./updaterpi.sh --live
```

For manual use with reboot only when clearly needed:

```bash
./updaterpi.sh --live --reboot
```

For cron or systemd timers, start with dry run until the logs look clean:

```bash
./updaterpi.sh --dry-run
```

Then switch deliberately to live mode:

```bash
./updaterpi.sh --live
```

## Do not use rpi-update for normal updates

This script does not use `rpi-update`.

Normal Raspberry Pi OS maintenance should use APT packages.

`rpi-update` installs newer test firmware and kernel versions and is not meant as a standard update path.

## Example output

```text
Raspberry Pi Update Skript
Host: midgard
Kernel aktuell: 6.12.75+rpt-rpi-v8
Modus: Live-Update

Pruefe APT Repository Suiten...
Pruefe freien Speicher...
APT Paketlisten werden aktualisiert...
Simuliere full-upgrade...
Full Upgrade startet...
Autoclean abgeschlossen.
needrestart Pruefung...
Post-Checks...

Neustartbewertung

HARTER NEUSTARTGRUND erkannt:
* Boot-, Kernel-, Device-Tree-, Initramfs- oder EEPROM-Dateien wurden waehrend des Updates geaendert.

Empfehlung: sudo reboot
```

## Disclaimer

Use this script at your own risk.

It is built to be cautious, but it still performs system updates. Always keep backups for important systems.
