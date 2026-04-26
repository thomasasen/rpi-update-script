# rpi-update-script

Safe update helper for Raspberry Pi OS and other Debian based Raspberry Pi systems.

`updateme.sh` updates the system through APT, simulates changes before installing, checks for risky repository mixes, verifies free disk space, handles missing helper tools on request, detects reboot needs more reliably than `/run/reboot-required` alone, and writes a log for every run.

The script is intentionally conservative. It is meant for small Raspberry Pi servers, headless systems, media servers, NAS helpers, automation nodes and similar setups where a silent broken update is not acceptable.

## Key features

| Feature | What it does |
|---|---|
| Interactive safe start | Starts with a dry run prompt unless a mode is given explicitly. |
| Dry run support | Simulates `apt-get full-upgrade` without installing packages. |
| Safe live update | Runs `apt-get full-upgrade` only when live mode is selected. |
| Package removal guard | Aborts if `full-upgrade` wants to remove packages, unless allowed explicitly. |
| Repository suite check | Warns about mixed APT suites such as `trixie` plus `bookworm`. |
| Disk space check | Verifies free space on `/` and `/boot/firmware` or `/boot`. |
| Missing tool handling | Can install missing required or optional tools after confirmation. |
| Better reboot detection | Checks reboot markers, package plans, boot files, firmware, EEPROM and `needrestart`. |
| Hard and soft reboot reasons | Separates clear reboot cases from service restart cases. |
| Post checks | Runs APT consistency checks, `dpkg --audit`, failed systemd units and journal error checks. |
| Log files | Writes timestamped logs and removes old logs automatically. |
| Optional auto reboot | Can reboot automatically on hard or soft reboot reasons. |

## Why this script exists

A basic reboot check like this is often too weak on Raspberry Pi systems:

```bash
test -f /run/reboot-required
```

Kernel, Raspberry Pi firmware, EEPROM, boot files and initramfs updates may require a reboot even when no clear reboot marker is present.

This script checks several signals instead:

```text
/run/reboot-required
/var/run/reboot-required
planned kernel related package updates
planned firmware package updates
planned raspi-firmware updates
planned rpi-eeprom updates
changed files in /boot or /boot/firmware
needrestart kernel status
needrestart service and process status
```

The result is a more honest reboot recommendation.

## Requirements

Target systems:

```text
Raspberry Pi OS
Debian based Raspberry Pi systems
APT based systems
systemd based systems
```

Required base components:

```text
bash
apt-get
sudo, unless the script runs as root
```

The script also uses common tools such as:

```text
awk
grep
find
sort
tee
df
mktemp
date
basename
cut
sed
systemctl
journalctl
dpkg
hostname
```

If one of these tools is missing, the script can install the corresponding package after asking.

Optional but recommended:

```text
needrestart
```

`needrestart` improves detection of services and processes that still use old libraries after an update.

## Installation

Clone the repository:

```bash
git clone https://github.com/thomasasen/rpi-update-script.git
cd rpi-update-script
chmod +x updateme.sh
```

Run a syntax check before first use:

```bash
bash -n updateme.sh
```

## Usage

### Interactive mode

```bash
./updateme.sh
```

The script asks whether it should run as dry run or live update.

The safe default is dry run.

### Dry run

```bash
./updateme.sh --dry-run
```

This only updates package lists and simulates the upgrade.

No packages are installed.

### Live update

```bash
./updateme.sh --live
```

Runs the real update without asking for the mode.

### Install missing tools on request

Default behavior:

```bash
./updateme.sh
```

If tools are missing, the script asks before installing them.

Install missing tools automatically:

```bash
./updateme.sh --install-missing
```

Never install missing tools automatically:

```bash
./updateme.sh --no-install-missing
```

In non interactive execution, the script does not silently install missing tools unless `--install-missing` is set.

### Live update with automatic reboot on hard reboot reasons

```bash
./updateme.sh --live --reboot
```

This reboots only when a hard reboot reason is detected.

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

### Live update with automatic reboot on soft reboot reasons too

```bash
./updateme.sh --live --reboot-soft
```

This also reboots when soft reboot reasons are detected.

Soft reboot reasons include:

```text
OpenSSL update
libssl update
libc update
OpenSSH update
services or processes still using old libraries
```

### Allow package removals

```bash
./updateme.sh --live --allow-removals
```

By default, the script aborts if `full-upgrade` wants to remove packages.

That is deliberate. Package removals can be valid, but they should not happen unnoticed on a server.

### Skip autoremove

```bash
./updateme.sh --live --no-autoremove
```

Use this if you want to inspect and clean unused packages manually.

## Options

| Option | Description |
|---|---|
| `--dry-run` | Simulate the update. No package changes. |
| `--live` | Run the real update without asking for the mode. |
| `--yes` | Alias for `--live`. |
| `--allow-removals` | Allow package removals during `full-upgrade`. |
| `--reboot` | Reboot automatically only on hard reboot reasons. |
| `--reboot-soft` | Reboot automatically on hard or soft reboot reasons. |
| `--no-autoremove` | Skip `apt-get autoremove`. |
| `--install-missing` | Install missing required and optional helper tools automatically. |
| `--no-install-missing` | Do not install missing tools. Required missing tools cause an abort. |
| `--help` | Show help. |

## Environment variables

| Variable | Default | Description |
|---|---:|---|
| `ROOT_MIN_MB` | `1024` | Minimum free space on `/` in MB. |
| `BOOT_MIN_MB` | `256` | Minimum free space on `/boot/firmware` or `/boot` in MB. |
| `LOG_KEEP_DAYS` | `30` | Delete logs older than this number of days. |
| `LOG_KEEP_COUNT` | `20` | Keep at most this number of recent log files. |
| `LOG_DIR` | `$HOME/updaterpi-logs` | Directory for log files. |

Example:

```bash
ROOT_MIN_MB=2048 BOOT_MIN_MB=512 ./updateme.sh --live
```

## Reboot logic

The script separates reboot reasons into two groups.

### Hard reboot reasons

A hard reboot reason means a reboot is the correct action.

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

A soft reboot reason means a reboot is clean and simple, but selected service restarts may be enough.

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

Alternative:

```bash
sudo needrestart
```

Then inspect and restart affected services manually.

## Repository mix warning

The script checks configured APT suites.

Example warning:

```text
trixie
bookworm
```

A mixed setup can be intentional, but it can also cause dependency problems.

Inspect classic `.list` files:

```bash
grep -R "^deb " /etc/apt/sources.list /etc/apt/sources.list.d/
```

Inspect modern `.sources` files:

```bash
grep -R "^Suites:" /etc/apt/sources.list.d/
```

## Logs

Every run writes a timestamped log.

Default location:

```text
~/updaterpi-logs/
```

Example:

```text
~/updaterpi-logs/updaterpi-20260426-143012.log
```

Old logs are cleaned automatically according to:

```text
LOG_KEEP_DAYS
LOG_KEEP_COUNT
```

## Safety behavior

The script is conservative by design.

It aborts in these cases:

```text
not enough disk space
APT simulation detects package removals without --allow-removals
required tools are missing and installation was declined
apt-get check fails
unexpected command failure
```

If the script runs without an interactive terminal and no mode is given, it defaults to dry run.

That prevents accidental unattended live updates.

## Recommended workflow

For first use:

```bash
./updateme.sh --dry-run
```

If the output looks clean:

```bash
./updateme.sh --live
```

For routine manual maintenance:

```bash
./updateme.sh --live --reboot
```

For systems where you want to decide every reboot yourself:

```bash
./updateme.sh --live
```

For scheduled execution, start with dry run until the logs are clean:

```bash
./updateme.sh --dry-run
```

Then switch deliberately to live mode:

```bash
./updateme.sh --live
```

## Do not use rpi-update for normal updates

This script does not use `rpi-update`.

Normal Raspberry Pi OS maintenance should use APT packages.

`rpi-update` installs newer test firmware and kernel versions. It is not the normal update path for stable systems.

## Example output

```text
Raspberry Pi Update Skript
Host: midgard
Kernel aktuell: 6.12.75+rpt-rpi-v8
Modus: Live-Update
Auto-Reboot: hard
Fehlende Tools installieren: prompt

Pruefe benoetigte Tools...
Pruefe optionale Tools...
Pruefe APT Repository Suiten...
Pruefe freien Speicher...
APT Paketlisten werden aktualisiert...
Simuliere full-upgrade...
Full Upgrade startet...
needrestart Pruefung...
Post-Checks...

Neustartbewertung

HARTER NEUSTARTGRUND erkannt:
* Boot-, Kernel-, Device-Tree-, Initramfs- oder EEPROM-Dateien wurden waehrend des Updates geaendert.

Empfehlung: sudo reboot
```

## Important note for maintainers

The file `updateme.sh` must be a plain shell script and should start with:

```bash
#!/usr/bin/env bash
```

It must not contain Python wrapper code such as:

```python
from pathlib import Path
script = r'''...
```

If that text appears in `updateme.sh`, replace the file with the plain shell script content before using it.

## Disclaimer

Use this script at your own risk.

It is built to be cautious, but it still performs system updates. Keep backups for important systems.
