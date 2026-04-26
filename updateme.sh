#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=l

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=""
ASSUME_YES=0
ALLOW_REMOVALS=0
AUTO_REBOOT="none"
RUN_AUTOREMOVE=1

ROOT_MIN_MB="${ROOT_MIN_MB:-1024}"
BOOT_MIN_MB="${BOOT_MIN_MB:-256}"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-30}"
LOG_KEEP_COUNT="${LOG_KEEP_COUNT:-20}"

LOG_DIR="${LOG_DIR:-$HOME/updaterpi-logs}"
LOG_FILE="${LOG_DIR}/updaterpi-$(date '+%Y%m%d-%H%M%S').log"

SIM_FILE="$(mktemp)"
PLAN_FILE="$(mktemp)"
REMOVALS_FILE="$(mktemp)"
BOOT_MARKER="$(mktemp)"
BOOT_CHANGED_FILE="$(mktemp)"
NEEDRESTART_FILE="$(mktemp)"

HARD_REBOOT=0
SOFT_REBOOT=0
WARNINGS=()
HARD_REASONS=()
SOFT_REASONS=()

usage() {
    cat <<USAGE
Nutzung:
  ./$SCRIPT_NAME [Optionen]

Optionen:
  --dry-run           Nur simulieren. Es werden keine Pakete installiert.
  --live              Live-Update ohne Modus-Rueckfrage starten.
  --yes               Alias fuer --live.
  --allow-removals    Erlaubt Paketentfernungen durch full-upgrade.
  --reboot            Automatisch nur bei harten Neustartgruenden rebooten.
  --reboot-soft       Automatisch auch bei weichen Neustartgruenden rebooten.
  --no-autoremove     Autoremove ueberspringen.
  --help              Diese Hilfe anzeigen.

Umgebungsvariablen:
  ROOT_MIN_MB=1024    Mindestfreier Speicher auf / in MB.
  BOOT_MIN_MB=256     Mindestfreier Speicher auf /boot/firmware oder /boot in MB.
  LOG_KEEP_DAYS=30    Logs aelter als X Tage loeschen.
  LOG_KEEP_COUNT=20   Maximal X aktuelle Logs behalten.
USAGE
}

die() {
    echo
    echo "FEHLER: $*" >&2
    echo "Logdatei: $LOG_FILE" >&2
    exit 1
}

warn() {
    WARNINGS+=("$*")
    echo "WARNUNG: $*"
}

add_hard_reboot_reason() {
    local reason="$1"
    HARD_REBOOT=1
    HARD_REASONS+=("$reason")
}

add_soft_reboot_reason() {
    local reason="$1"
    SOFT_REBOOT=1
    SOFT_REASONS+=("$reason")
}

cleanup() {
    rm -f "$SIM_FILE" "$PLAN_FILE" "$REMOVALS_FILE" "$BOOT_MARKER" "$BOOT_CHANGED_FILE" "$NEEDRESTART_FILE"
}
trap cleanup EXIT

on_error() {
    local exit_code=$?
    echo
    echo "########################################"
    echo "FEHLER: Das Skript wurde abgebrochen. Exit-Code: $exit_code"
    echo "Logdatei: $LOG_FILE"
    echo "########################################"
    exit "$exit_code"
}
trap on_error ERR

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            --live|--yes)
                DRY_RUN=0
                ASSUME_YES=1
                ;;
            --allow-removals)
                ALLOW_REMOVALS=1
                ;;
            --reboot)
                AUTO_REBOOT="hard"
                ;;
            --reboot-soft)
                AUTO_REBOOT="soft"
                ;;
            --no-autoremove)
                RUN_AUTOREMOVE=0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unbekannte Option: $1" >&2
                usage
                exit 2
                ;;
        esac
        shift
    done
}

rotate_logs() {
    mkdir -p "$LOG_DIR"

    find "$LOG_DIR" -maxdepth 1 -type f -name 'updaterpi-*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true

    local old_logs=()
    mapfile -t old_logs < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'updaterpi-*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | sed -n "$((LOG_KEEP_COUNT + 1)),\$p" \
        | cut -d' ' -f2-
    )

    local file
    for file in "${old_logs[@]:-}"; do
        rm -f -- "$file" || true
    done
}

init_logging() {
    rotate_logs
    exec > >(tee -a "$LOG_FILE") 2>&1
}

choose_mode() {
    if [[ -n "$DRY_RUN" ]]; then
        return
    fi

    if [[ ! -t 0 ]]; then
        DRY_RUN=1
        echo "Kein interaktives Terminal erkannt. Sicherheitsmodus: Dry-Run."
        echo "Fuer Live-Update explizit mit --live oder --yes starten."
        return
    fi

    echo
    echo "Modus auswaehlen:"
    echo "  1 = Dry-Run. Paketlisten aktualisieren und Upgrade nur simulieren."
    echo "  2 = Live-Update. Pakete wirklich installieren."
    echo
    read -r -p "Zuerst nur simulieren? [J/n]: " answer

    case "${answer,,}" in
        ""|j|ja|y|yes|1|d|dry|dry-run)
            DRY_RUN=1
            ;;
        n|nein|no|2|l|live)
            DRY_RUN=0
            ;;
        *)
            echo "Eingabe nicht erkannt. Sicherheitsmodus: Dry-Run."
            DRY_RUN=1
            ;;
    esac
}

setup_sudo_and_apt() {
    if [[ "$EUID" -eq 0 ]]; then
        SUDO=()
    else
        SUDO=(sudo)
    fi

    APT_GET=("${SUDO[@]}" apt-get
        -o DPkg::Lock::Timeout=300
        -o Dpkg::Options::=--force-confdef
        -o Dpkg::Options::=--force-confold
    )
}

print_header() {
    echo "########################################"
    echo "Raspberry Pi Update Skript"
    echo "Zeitpunkt: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host: $(hostname)"
    echo "User: $(id -un)"
    echo "Kernel aktuell: $(uname -r)"
    echo "Modus: $([[ "$DRY_RUN" -eq 1 ]] && echo 'Dry-Run' || echo 'Live-Update')"
    echo "Auto-Reboot: $AUTO_REBOOT"
    echo "Logdatei: $LOG_FILE"
    echo "########################################"
}

require_sudo() {
    echo
    echo "Pruefe sudo Zugriff..."
    "${SUDO[@]}" -v
}

normalize_suite() {
    local suite="${1,,}"
    suite="${suite%%/*}"

    case "$suite" in
        buster*) echo "buster" ;;
        bullseye*) echo "bullseye" ;;
        bookworm*) echo "bookworm" ;;
        trixie*) echo "trixie" ;;
        forky*) echo "forky" ;;
        sid|unstable) echo "sid" ;;
        stable|testing|oldstable|oldoldstable) echo "$suite" ;;
        *) echo "" ;;
    esac
}

collect_apt_suites() {
    local files=()
    local file

    [[ -f /etc/apt/sources.list ]] && files+=("/etc/apt/sources.list")

    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null || true)
    fi

    for file in "${files[@]:-}"; do
        case "$file" in
            *.list|/etc/apt/sources.list)
                awk -v file="$file" '
                    /^[[:space:]]*#/ {next}
                    {
                        line = $0
                        sub(/[[:space:]]*#.*/, "", line)
                        n = split(line, a, /[[:space:]]+/)
                        idx = 1
                        while (idx <= n && a[idx] == "") idx++
                        if (a[idx] !~ /^deb(-src)?$/) next
                        idx++
                        if (a[idx] ~ /^\[/) {
                            while (idx <= n && a[idx] !~ /\]$/) idx++
                            idx++
                        }
                        if ((idx + 1) <= n && a[idx + 1] != "") print a[idx + 1] "\t" file
                    }
                ' "$file"
                ;;
            *.sources)
                awk -v file="$file" '
                    /^[[:space:]]*#/ {next}
                    /^Suites:[[:space:]]*/ {
                        sub(/^Suites:[[:space:]]*/, "")
                        for (i = 1; i <= NF; i++) print $i "\t" file
                    }
                ' "$file"
                ;;
        esac
    done
}

check_repo_mix() {
    echo
    echo "Pruefe APT Repository Suiten..."

    local os_codename=""
    if [[ -r /etc/os-release ]]; then
        source /etc/os-release || true
        os_codename="${VERSION_CODENAME:-}"
    fi

    declare -A base_suites=()
    declare -A raw_suites=()
    local suite source_file base

    while IFS=$'\t' read -r suite source_file; do
        [[ -n "${suite:-}" ]] || continue
        raw_suites["$suite"]="$source_file"
        base="$(normalize_suite "$suite")"
        [[ -n "$base" ]] && base_suites["$base"]=1
    done < <(collect_apt_suites)

    if [[ "${#raw_suites[@]}" -eq 0 ]]; then
        warn "Keine aktiven APT Quellen erkannt oder Quellen konnten nicht gelesen werden."
        return
    fi

    echo "Erkannte Suites:"
    for suite in "${!raw_suites[@]}"; do
        echo "  $suite  (${raw_suites[$suite]})"
    done | sort

    if [[ "${#base_suites[@]}" -gt 1 ]]; then
        warn "Mehrere Debian/Raspberry-Pi Basis-Suites erkannt: $(printf '%s ' "${!base_suites[@]}")"
        warn "Das kann gewollt sein, ist aber ein Risiko fuer Abhaengigkeiten. Bei dir waere z. B. trixie plus bookworm auffaellig."
    fi

    if [[ -n "$os_codename" ]]; then
        for base in "${!base_suites[@]}"; do
            case "$base" in
                stable|testing|oldstable|oldoldstable|sid)
                    ;;
                "$os_codename")
                    ;;
                *)
                    warn "APT Suite '$base' passt nicht zu VERSION_CODENAME='$os_codename'. Bitte Quellen pruefen."
                    ;;
            esac
        done
    fi
}

check_free_space_path() {
    local path="$1"
    local min_mb="$2"
    local label="$3"

    [[ -d "$path" ]] || return 0

    local avail_mb inode_avail
    avail_mb="$(df -Pm "$path" | awk 'NR == 2 {print $4}')"
    inode_avail="$(df -Pi "$path" | awk 'NR == 2 {print $4}')"

    echo "$label: ${avail_mb} MB frei. Minimum: ${min_mb} MB."

    if [[ "$avail_mb" =~ ^[0-9]+$ ]] && (( avail_mb < min_mb )); then
        die "Zu wenig freier Speicher auf $path. Frei: ${avail_mb} MB, benoetigt mindestens: ${min_mb} MB."
    fi

    if [[ "$inode_avail" =~ ^[0-9]+$ ]] && (( inode_avail < 1000 )); then
        die "Zu wenige freie Inodes auf $path. Frei: $inode_avail, benoetigt mindestens: 1000."
    fi
}

check_free_space() {
    echo
    echo "Pruefe freien Speicher..."
    check_free_space_path "/" "$ROOT_MIN_MB" "Root-Dateisystem"

    if [[ -d /boot/firmware ]]; then
        check_free_space_path "/boot/firmware" "$BOOT_MIN_MB" "Boot-Firmware-Dateisystem"
    elif [[ -d /boot ]]; then
        check_free_space_path "/boot" "$BOOT_MIN_MB" "Boot-Dateisystem"
    else
        warn "Weder /boot/firmware noch /boot als Verzeichnis gefunden."
    fi
}

apt_update() {
    echo
    echo "APT Paketlisten werden aktualisiert..."
    "${APT_GET[@]}" update
}

simulate_full_upgrade() {
    echo
    echo "Simuliere full-upgrade..."
    : > "$SIM_FILE"
    : > "$PLAN_FILE"
    : > "$REMOVALS_FILE"

    "${APT_GET[@]}" -s full-upgrade | tee "$SIM_FILE"

    awk '/^Inst / {print $2}' "$SIM_FILE" | sort -u > "$PLAN_FILE"
    awk '/^Remv / {print $2}' "$SIM_FILE" | sort -u > "$REMOVALS_FILE"

    echo
    if [[ -s "$PLAN_FILE" ]]; then
        echo "Geplante Paketupdates:"
        cat "$PLAN_FILE"
    else
        echo "Keine Paketupdates geplant."
    fi

    if [[ -s "$REMOVALS_FILE" ]]; then
        echo
        warn "full-upgrade wuerde Pakete entfernen:"
        cat "$REMOVALS_FILE"

        if [[ "$DRY_RUN" -eq 0 && "$ALLOW_REMOVALS" -ne 1 ]]; then
            die "Abbruch: Paketentfernungen erkannt. Falls bewusst gewollt, erneut mit --allow-removals starten."
        fi
    fi
}

detect_reboot_from_plan() {
    [[ -s "$PLAN_FILE" ]] || return 0

    if grep -Eiq '^(linux-image|linux-headers|raspberrypi-kernel|raspberrypi-bootloader|raspi-firmware|rpi-eeprom|initramfs-tools)$' "$PLAN_FILE"; then
        add_hard_reboot_reason "Kernel, Bootdateien, Initramfs, Raspberry Pi Firmware oder EEPROM Paket ist im Upgrade-Plan enthalten."
    fi

    if grep -Eiq '^firmware-' "$PLAN_FILE"; then
        add_hard_reboot_reason "Firmwarepakete sind im Upgrade-Plan enthalten. Geladene Firmware wird meist erst nach Neustart sauber ersetzt."
    fi

    if grep -Eiq '^(libc6|libssl[0-9].*|libssl3t64|openssl|openssl-provider.*|openssh-server|openssh-client|openssh-sftp-server|ssh)$' "$PLAN_FILE"; then
        add_soft_reboot_reason "Zentrale Bibliotheken oder SSH/OpenSSL Pakete sind im Upgrade-Plan enthalten. Dienste koennen danach alte Bibliotheken nutzen."
    fi
}

run_live_upgrade() {
    echo
    echo "Setze Boot-Zeitmarker fuer spaetere Aenderungspruefung..."
    touch "$BOOT_MARKER"

    echo
    echo "Full Upgrade startet..."
    "${APT_GET[@]}" full-upgrade -y
    echo "Full Upgrade abgeschlossen."

    if [[ "$RUN_AUTOREMOVE" -eq 1 ]]; then
        echo
        echo "Autoremove Simulation:"
        "${APT_GET[@]}" -s autoremove || true

        echo
        echo "Autoremove startet..."
        "${APT_GET[@]}" autoremove -y
        echo "Autoremove abgeschlossen."
    else
        echo
        echo "Autoremove wurde per --no-autoremove uebersprungen."
    fi

    echo
    echo "Autoclean startet..."
    "${APT_GET[@]}" autoclean -y
    echo "Autoclean abgeschlossen."
}

detect_standard_reboot_marker() {
    if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
        add_hard_reboot_reason "Systemmarker /run/reboot-required oder /var/run/reboot-required wurde gesetzt."
    fi
}

detect_boot_file_changes() {
    : > "$BOOT_CHANGED_FILE"

    local dir
    for dir in /boot/firmware /boot /lib/firmware/raspberrypi/bootloader; do
        [[ -d "$dir" ]] || continue

        find "$dir" -xdev -type f \
            \( -name 'kernel*.img' \
            -o -name 'vmlinuz*' \
            -o -name 'initrd.img*' \
            -o -name 'initramfs*' \
            -o -name '*.dtb' \
            -o -name '*.dtbo' \
            -o -name 'pieeprom*.bin' \) \
            -newer "$BOOT_MARKER" -print >> "$BOOT_CHANGED_FILE" 2>/dev/null || true
    done

    sort -u "$BOOT_CHANGED_FILE" -o "$BOOT_CHANGED_FILE" 2>/dev/null || true

    if [[ -s "$BOOT_CHANGED_FILE" ]]; then
        add_hard_reboot_reason "Boot-, Kernel-, Device-Tree-, Initramfs- oder EEPROM-Dateien wurden waehrend des Updates geaendert."
        echo
        echo "Geaenderte Boot-nahe Dateien:"
        cat "$BOOT_CHANGED_FILE"
    fi
}

run_needrestart_check() {
    echo
    echo "needrestart Pruefung..."

    if ! command -v needrestart >/dev/null 2>&1; then
        echo "needrestart ist nicht installiert. Optional installieren mit:"
        echo "sudo apt-get install needrestart"
        return 0
    fi

    : > "$NEEDRESTART_FILE"
    "${SUDO[@]}" needrestart -b -r l | tee "$NEEDRESTART_FILE" || true

    if grep -Eiq '^NEEDRESTART-KSTA:[[:space:]]*[23]' "$NEEDRESTART_FILE"; then
        add_hard_reboot_reason "needrestart meldet einen abweichenden oder veralteten laufenden Kernel."
    fi

    if grep -Eiq '^(NEEDRESTART-SVC:|NEEDRESTART-PROC:)' "$NEEDRESTART_FILE"; then
        add_soft_reboot_reason "needrestart meldet laufende Dienste oder Prozesse mit alten Bibliotheken."
    fi
}

post_checks() {
    echo
    echo "Post-Checks..."

    echo
    echo "APT Konsistenzpruefung:"
    "${APT_GET[@]}" check

    echo
    echo "dpkg Audit:"
    local dpkg_audit
    dpkg_audit="$(dpkg --audit || true)"
    if [[ -n "$dpkg_audit" ]]; then
        warn "dpkg --audit meldet Auffaelligkeiten:"
        echo "$dpkg_audit"
    else
        echo "Keine dpkg Audit Auffaelligkeiten."
    fi

    echo
    echo "systemd fehlgeschlagene Units:"
    systemctl --failed --no-pager || true

    echo
    echo "SSH Status:"
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl is-active ssh.service || warn "ssh.service ist nicht aktiv. Falls der Pi headless per SSH genutzt wird, pruefen."
        systemctl is-enabled ssh.service || true
    else
        echo "ssh.service nicht gefunden."
    fi

    echo
    echo "Aktuelle Fehler aus diesem Boot, Prioritaet err..alert, letzte 80 Zeilen:"
    journalctl -b -p err..alert -n 80 --no-pager || true

    echo
    echo "Kernel aktuell nach Update-Lauf: $(uname -r)"

    echo
    echo "Raspberry Pi EEPROM Status:"
    if command -v rpi-eeprom-update >/dev/null 2>&1; then
        "${SUDO[@]}" rpi-eeprom-update || true
    else
        echo "rpi-eeprom-update ist nicht installiert oder nicht im PATH."
    fi
}

print_reboot_summary() {
    echo
    echo "########################################"
    echo "Neustartbewertung"
    echo "########################################"

    if [[ "$HARD_REBOOT" -eq 1 ]]; then
        echo
        echo "HARTER NEUSTARTGRUND erkannt:"
        local reason
        for reason in "${HARD_REASONS[@]}"; do
            echo "* $reason"
        done
    fi

    if [[ "$SOFT_REBOOT" -eq 1 ]]; then
        echo
        echo "WEICHER NEUSTARTGRUND erkannt:"
        local reason
        for reason in "${SOFT_REASONS[@]}"; do
            echo "* $reason"
        done
        echo
        echo "Weich heisst: Ein kompletter Neustart ist sauber und einfach, aber eventuell reicht auch ein Dienstneustart."
    fi

    if [[ -f /run/reboot-required.pkgs ]]; then
        echo
        echo "Pakete aus /run/reboot-required.pkgs:"
        cat /run/reboot-required.pkgs
    elif [[ -f /var/run/reboot-required.pkgs ]]; then
        echo
        echo "Pakete aus /var/run/reboot-required.pkgs:"
        cat /var/run/reboot-required.pkgs
    fi

    if [[ "$HARD_REBOOT" -eq 0 && "$SOFT_REBOOT" -eq 0 ]]; then
        echo
        echo "Kein Neustartbedarf erkannt."
    elif [[ "$HARD_REBOOT" -eq 1 ]]; then
        echo
        echo "Empfehlung: sudo reboot"
    else
        echo
        echo "Empfehlung: needrestart Ausgabe pruefen oder sauberheitshalber sudo reboot ausfuehren."
    fi
}

maybe_auto_reboot() {
    [[ "$DRY_RUN" -eq 0 ]] || return 0

    case "$AUTO_REBOOT" in
        hard)
            if [[ "$HARD_REBOOT" -eq 1 ]]; then
                echo
                echo "Auto-Reboot aktiv: harter Neustartgrund erkannt. System startet jetzt neu."
                "${SUDO[@]}" reboot
            fi
            ;;
        soft)
            if [[ "$HARD_REBOOT" -eq 1 || "$SOFT_REBOOT" -eq 1 ]]; then
                echo
                echo "Auto-Reboot-Soft aktiv: Neustartgrund erkannt. System startet jetzt neu."
                "${SUDO[@]}" reboot
            fi
            ;;
        none)
            ;;
    esac
}

print_warning_summary() {
    if [[ "${#WARNINGS[@]}" -eq 0 ]]; then
        return
    fi

    echo
    echo "########################################"
    echo "Warnungen"
    echo "########################################"
    local item
    for item in "${WARNINGS[@]}"; do
        echo "* $item"
    done
}

main() {
    parse_args "$@"
    init_logging
    choose_mode
    setup_sudo_and_apt
    print_header
    require_sudo
    check_repo_mix
    check_free_space
    apt_update
    simulate_full_upgrade
    detect_reboot_from_plan

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo
        echo "Dry-Run abgeschlossen. Es wurden keine Pakete installiert."
        print_reboot_summary
        print_warning_summary
        echo
        echo "Logdatei: $LOG_FILE"
        exit 0
    fi

    run_live_upgrade
    detect_standard_reboot_marker
    detect_boot_file_changes
    run_needrestart_check
    post_checks
    print_reboot_summary
    print_warning_summary

    echo
    echo "Update abgeschlossen."
    echo "Logdatei: $LOG_FILE"

    maybe_auto_reboot
}

main "$@"
