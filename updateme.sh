#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Raspberry Pi Update Script
#
# Ziel:
# - APT-Updates sicher und nachvollziehbar ausführen
# - zuerst simulieren, dann bewusst live aktualisieren
# - fehlende Hilfsprogramme auf Rückfrage installieren
# - Kernel-, Firmware-, EEPROM- und Boot-Änderungen erkennen
# - harte und weiche Neustartgründe getrennt ausgeben
# - Logs schreiben und alte Logs aufräumen

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=l

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=""
ALLOW_REMOVALS=0
AUTO_REBOOT="none"
RUN_AUTOREMOVE=1
INSTALL_MISSING="prompt"

ROOT_MIN_MB="${ROOT_MIN_MB:-1024}"
BOOT_MIN_MB="${BOOT_MIN_MB:-256}"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-30}"
LOG_KEEP_COUNT="${LOG_KEEP_COUNT:-20}"
LOG_DIR="${LOG_DIR:-$HOME/updaterpi-logs}"
LOG_FILE="${LOG_DIR}/updaterpi-$(date '+%Y%m%d-%H%M%S').log"

SIM_FILE=""
PLAN_FILE=""
REMOVALS_FILE=""
BOOT_MARKER=""
BOOT_CHANGED_FILE=""
NEEDRESTART_FILE=""

HARD_REBOOT=0
SOFT_REBOOT=0
WARNINGS=()
HARD_REASONS=()
SOFT_REASONS=()

usage() {
    cat <<USAGE
Nutzung:
  ./$SCRIPT_NAME [Optionen]

Ohne Optionen startet eine interaktive Auswahl mit nummerierten Optionen und Presets.

Optionen:
  --dry-run              Nur simulieren. Es werden keine Pakete installiert.
  --live                 Live-Update ohne Modus-Rückfrage starten.
  --yes                  Alias für --live.
  --allow-removals       Erlaubt Paketentfernungen durch full-upgrade.
  --reboot               Automatisch nur bei harten Neustartgründen rebooten.
  --reboot-soft          Automatisch auch bei weichen Neustartgründen rebooten.
  --no-autoremove        Autoremove überspringen.
  --install-missing      Fehlende Tools automatisch installieren.
  --no-install-missing   Fehlende Tools nicht installieren, sondern abbrechen oder überspringen.
  --help                 Diese Hilfe anzeigen.

Umgebungsvariablen:
  ROOT_MIN_MB=1024       Mindestfreier Speicher auf / in MB.
  BOOT_MIN_MB=256        Mindestfreier Speicher auf /boot/firmware oder /boot in MB.
  LOG_KEEP_DAYS=30       Logs älter als X Tage löschen.
  LOG_KEEP_COUNT=20      Maximal X aktuelle Logs behalten.
  LOG_DIR=...            Verzeichnis für Logdateien.
USAGE
}
show_interactive_option_menu() {
    if [[ ! -t 0 ]]; then
        DRY_RUN=1
        echo "Keine Optionen und kein interaktives Terminal erkannt. Sicherheitsmodus: Dry-Run."
        echo "Für Live-Update explizit mit --live oder --yes starten."
        return
    fi

    echo
    echo "Keine Optionen angegeben."
    echo "Wähle ein Preset per Buchstabe oder einzelne Optionen per kommagetrennter Nummernliste."
    echo
    echo "Presets:"
    echo "  A = Analyse: Dry-Run, keine Installation, kein Neustart."
    echo "  B = Standard: Live-Update, fehlende Tools nur auf Rückfrage, kein automatischer Neustart."
    echo "  C = Wartung: Live-Update, fehlende Tools nur auf Rückfrage, automatischer Neustart bei harten Gründen."
    echo "  D = Automatisch: Live-Update, fehlende Tools automatisch installieren, automatischer Neustart bei harten Gründen."
    echo "  E = Kontrolliert: Live-Update, fehlende Tools nicht installieren, Autoremove überspringen, kein automatischer Neustart."
    echo
    echo "Einzeloptionen:"
    echo "  1 = Dry-Run: nur simulieren, keine Pakete installieren."
    echo "  2 = Live-Update: Pakete wirklich installieren."
    echo "  3 = Paketentfernungen durch full-upgrade erlauben."
    echo "  4 = Automatisch rebooten, wenn harte Neustartgründe erkannt werden."
    echo "  5 = Automatisch auch bei weichen Neustartgründen rebooten."
    echo "  6 = Autoremove überspringen."
    echo "  7 = Fehlende Tools automatisch installieren."
    echo "  8 = Fehlende Tools nicht installieren."
    echo "  0 = Abbrechen."
    echo
    echo "Beispiele:"
    echo "  A"
    echo "  B"
    echo "  2,4,7"
    echo "  2,3,4,7"
    echo
    read -r -p "Auswahl [A]: " selection

    selection="${selection:-A}"
    selection="${selection//[[:space:]]/}"
    selection="${selection,,}"

    local entries=()
    local entry
    IFS=',' read -r -a entries <<< "$selection"

    for entry in "${entries[@]}"; do
        case "$entry" in
            a)
                DRY_RUN=1
                ALLOW_REMOVALS=0
                AUTO_REBOOT="none"
                RUN_AUTOREMOVE=1
                INSTALL_MISSING="no"
                ;;
            b)
                DRY_RUN=0
                ALLOW_REMOVALS=0
                AUTO_REBOOT="none"
                RUN_AUTOREMOVE=1
                INSTALL_MISSING="prompt"
                ;;
            c)
                DRY_RUN=0
                ALLOW_REMOVALS=0
                AUTO_REBOOT="hard"
                RUN_AUTOREMOVE=1
                INSTALL_MISSING="prompt"
                ;;
            d)
                DRY_RUN=0
                ALLOW_REMOVALS=0
                AUTO_REBOOT="hard"
                RUN_AUTOREMOVE=1
                INSTALL_MISSING="yes"
                ;;
            e)
                DRY_RUN=0
                ALLOW_REMOVALS=0
                AUTO_REBOOT="none"
                RUN_AUTOREMOVE=0
                INSTALL_MISSING="no"
                ;;
            0|q|quit|exit|abbrechen)
                echo "Abgebrochen."
                exit 0
                ;;
            1)
                DRY_RUN=1
                ;;
            2)
                DRY_RUN=0
                ;;
            3)
                ALLOW_REMOVALS=1
                ;;
            4)
                AUTO_REBOOT="hard"
                ;;
            5)
                AUTO_REBOOT="soft"
                ;;
            6)
                RUN_AUTOREMOVE=0
                ;;
            7)
                INSTALL_MISSING="yes"
                ;;
            8)
                INSTALL_MISSING="no"
                ;;
            "")
                ;;
            *)
                die "Ungültige Auswahl: '$entry'"
                ;;
        esac
    done

    if [[ -z "$DRY_RUN" ]]; then
        DRY_RUN=1
        echo "Kein Modus gewählt. Sicherheitsmodus: Dry-Run."
    fi

    echo
    echo "Gewählte Einstellungen:"
    echo "  Modus: $([[ "$DRY_RUN" -eq 1 ]] && echo 'Dry-Run' || echo 'Live-Update')"
    echo "  Paketentfernungen erlauben: $([[ "$ALLOW_REMOVALS" -eq 1 ]] && echo 'ja' || echo 'nein')"
    echo "  Auto-Reboot: $AUTO_REBOOT"
    echo "  Autoremove: $([[ "$RUN_AUTOREMOVE" -eq 1 ]] && echo 'aktiv' || echo 'übersprungen')"
    echo "  Fehlende Tools installieren: $INSTALL_MISSING"
}


die() {
    echo
    echo "FEHLER: $*" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "Logdatei: $LOG_FILE" >&2
    fi
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
    [[ -n "${SIM_FILE:-}" ]] && rm -f "$SIM_FILE"
    [[ -n "${PLAN_FILE:-}" ]] && rm -f "$PLAN_FILE"
    [[ -n "${REMOVALS_FILE:-}" ]] && rm -f "$REMOVALS_FILE"
    [[ -n "${BOOT_MARKER:-}" ]] && rm -f "$BOOT_MARKER"
    [[ -n "${BOOT_CHANGED_FILE:-}" ]] && rm -f "$BOOT_CHANGED_FILE"
    [[ -n "${NEEDRESTART_FILE:-}" ]] && rm -f "$NEEDRESTART_FILE"
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
            --install-missing)
                INSTALL_MISSING="yes"
                ;;
            --no-install-missing)
                INSTALL_MISSING="no"
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

ask_yes_no() {
    local prompt="$1"
    local default_answer="${2:-no}"
    local answer=""
    local suffix="[j/N]"

    if [[ "$default_answer" == "yes" ]]; then
        suffix="[J/n]"
    fi

    if [[ ! -t 0 ]]; then
        [[ "$default_answer" == "yes" ]]
        return
    fi

    read -r -p "$prompt $suffix: " answer
    answer="${answer,,}"

    if [[ -z "$answer" ]]; then
        [[ "$default_answer" == "yes" ]]
        return
    fi

    case "$answer" in
        j|ja|y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

setup_sudo_and_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get wurde nicht gefunden. Dieses Skript ist für APT-basierte Systeme gedacht."
    fi

    if [[ "$EUID" -eq 0 ]]; then
        SUDO=()
    else
        if ! command -v sudo >/dev/null 2>&1; then
            die "sudo wurde nicht gefunden und das Skript läuft nicht als root. Bitte sudo installieren oder als root starten."
        fi
        SUDO=(sudo)
    fi

    APT_GET=("${SUDO[@]}" apt-get
        -o DPkg::Lock::Timeout=300
        -o Dpkg::Options::=--force-confdef
        -o Dpkg::Options::=--force-confold
    )
}

unique_packages() {
    local pkg
    local seen=" "
    for pkg in "$@"; do
        [[ -n "$pkg" ]] || continue
        if [[ "$seen" != *" $pkg "* ]]; then
            printf '%s\n' "$pkg"
            seen+="$pkg "
        fi
    done
}

install_packages() {
    local reason="$1"
    shift

    local packages=()
    mapfile -t packages < <(unique_packages "$@")

    [[ "${#packages[@]}" -gt 0 ]] || return 0

    echo
    echo "$reason"
    echo "Zu installierende Pakete: ${packages[*]}"

    "${APT_GET[@]}" update
    "${APT_GET[@]}" install -y "${packages[@]}"
}

handle_missing_packages() {
    local kind="$1"
    local reason="$2"
    shift 2

    local packages=("$@")
    [[ "${#packages[@]}" -gt 0 ]] || return 0

    case "$INSTALL_MISSING" in
        yes)
            install_packages "$reason" "${packages[@]}"
            ;;
        no)
            if [[ "$kind" == "required" ]]; then
                die "Erforderliche Tools fehlen. Fehlende Pakete: ${packages[*]}"
            fi
            echo "Optionale Pakete fehlen und werden nicht installiert: ${packages[*]}"
            ;;
        prompt)
            if ask_yes_no "$reason Jetzt installieren?" "no"; then
                install_packages "$reason" "${packages[@]}"
            else
                if [[ "$kind" == "required" ]]; then
                    die "Erforderliche Tools fehlen und wurden nicht installiert. Fehlende Pakete: ${packages[*]}"
                fi
                echo "Optionale Pakete wurden nicht installiert: ${packages[*]}"
            fi
            ;;
    esac
}

ensure_required_tools() {
    echo
    echo "Prüfe benötigte Tools..."

    local required=(
        "awk:mawk"
        "grep:grep"
        "find:findutils"
        "sort:coreutils"
        "tee:coreutils"
        "df:coreutils"
        "mktemp:coreutils"
        "date:coreutils"
        "basename:coreutils"
        "cut:coreutils"
        "sed:sed"
        "systemctl:systemd"
        "journalctl:systemd"
        "dpkg:dpkg"
        "hostname:hostname"
    )

    local missing_cmds=()
    local missing_pkgs=()
    local item cmd pkg

    for item in "${required[@]}"; do
        cmd="${item%%:*}"
        pkg="${item#*:}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ "${#missing_cmds[@]}" -eq 0 ]]; then
        echo "Alle benötigten Tools sind vorhanden."
        return 0
    fi

    echo "Fehlende erforderliche Tools: ${missing_cmds[*]}"
    mapfile -t missing_pkgs < <(unique_packages "${missing_pkgs[@]}")
    handle_missing_packages "required" "Fehlende erforderliche Tools können per APT installiert werden." "${missing_pkgs[@]}"

    local still_missing=()
    for item in "${required[@]}"; do
        cmd="${item%%:*}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            still_missing+=("$cmd")
        fi
    done

    if [[ "${#still_missing[@]}" -gt 0 ]]; then
        die "Einige erforderliche Tools fehlen weiterhin: ${still_missing[*]}"
    fi

    echo "Fehlende erforderliche Tools wurden installiert."
}

ensure_optional_tools() {
    echo
    echo "Prüfe optionale Tools..."

    local optional_pkgs=()

    if ! command -v needrestart >/dev/null 2>&1; then
        echo "Optionales Tool fehlt: needrestart"
        optional_pkgs+=("needrestart")
    fi

    if [[ "${#optional_pkgs[@]}" -gt 0 ]]; then
        handle_missing_packages "optional" "Optionale, empfohlene Tools fehlen. Sie verbessern die Neustart- und Dienstpruefung." "${optional_pkgs[@]}"
    else
        echo "Optionale Tools sind vorhanden."
    fi
}

create_temp_files() {
    SIM_FILE="$(mktemp)"
    PLAN_FILE="$(mktemp)"
    REMOVALS_FILE="$(mktemp)"
    BOOT_MARKER="$(mktemp)"
    BOOT_CHANGED_FILE="$(mktemp)"
    NEEDRESTART_FILE="$(mktemp)"
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
        echo "Für Live-Update explizit mit --live oder --yes starten."
        return
    fi

    echo
    echo "Modus auswählen:"
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

print_header() {
    echo "########################################"
    echo "Raspberry Pi Update Skript"
    echo "Zeitpunkt: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host: $(hostname)"
    echo "User: $(id -un)"
    echo "Kernel aktuell: $(uname -r)"
    echo "Modus: $([[ "$DRY_RUN" -eq 1 ]] && echo 'Dry-Run' || echo 'Live-Update')"
    echo "Auto-Reboot: $AUTO_REBOOT"
    echo "Fehlende Tools installieren: $INSTALL_MISSING"
    echo "Logdatei: $LOG_FILE"
    echo "########################################"
}

require_sudo() {
    echo
    echo "Prüfe sudo Zugriff..."

    if [[ "$EUID" -eq 0 ]]; then
        echo "Skript läuft bereits als root."
        return 0
    fi

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
    echo "Prüfe APT Repository Suiten..."

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
        warn "Das kann gewollt sein, ist aber ein Risiko für Abhängigkeiten. Bei dir wäre z. B. trixie plus bookworm auffällig."
    fi

    if [[ -n "$os_codename" ]]; then
        for base in "${!base_suites[@]}"; do
            case "$base" in
                stable|testing|oldstable|oldoldstable|sid)
                    ;;
                "$os_codename")
                    ;;
                *)
                    warn "APT Suite '$base' passt nicht zu VERSION_CODENAME='$os_codename'. Bitte Quellen prüfen."
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

    local avail_mb fs_type inode_avail
    avail_mb="$(df -Pm "$path" | awk 'NR == 2 {print $4}')"
    fs_type="$(df -PT "$path" | awk 'NR == 2 {print $2}')"

    echo "$label: ${avail_mb} MB frei. Minimum: ${min_mb} MB. Dateisystem: ${fs_type:-unbekannt}."

    if [[ "$avail_mb" =~ ^[0-9]+$ ]] && (( avail_mb < min_mb )); then
        die "Zu wenig freier Speicher auf $path. Frei: ${avail_mb} MB, benötigt mindestens: ${min_mb} MB."
    fi

    # FAT, exFAT, NTFS und ähnliche Dateisysteme haben keine klassischen Unix-Inodes.
    # Besonders /boot/firmware ist auf Raspberry Pi OS häufig vfat. Dort meldet df -i
    # je nach System 0 freie Inodes. Das ist kein echter Fehler und darf das Update
    # nicht blockieren.
    case "${fs_type,,}" in
        vfat|fat|msdos|exfat|ntfs|fuseblk)
            echo "$label: Inode-Prüfung für Dateisystem '$fs_type' übersprungen."
            ;;
        *)
            inode_avail="$(df -Pi "$path" | awk 'NR == 2 {print $4}')"

            if [[ "$inode_avail" =~ ^[0-9]+$ ]] && (( inode_avail < 1000 )); then
                die "Zu wenige freie Inodes auf $path. Frei: $inode_avail, benötigt mindestens: 1000."
            fi

            echo "$label: ${inode_avail:-unbekannt} freie Inodes."
            ;;
    esac
}

check_free_space() {
    echo
    echo "Prüfe freien Speicher..."
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
        warn "full-upgrade würde Pakete entfernen:"
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
        add_soft_reboot_reason "Zentrale Bibliotheken oder SSH/OpenSSL Pakete sind im Upgrade-Plan enthalten. Dienste können danach alte Bibliotheken nutzen."
    fi
}

run_live_upgrade() {
    echo
    echo "Setze Boot-Zeitmarker für spätere Änderungsprüfung..."
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
        echo "Autoremove wurde per --no-autoremove übersprungen."
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
        add_hard_reboot_reason "Boot-, Kernel-, Device-Tree-, Initramfs- oder EEPROM-Dateien wurden während des Updates geändert."
        echo
        echo "Geänderte Boot-nahe Dateien:"
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
        warn "dpkg --audit meldet Auffälligkeiten:"
        echo "$dpkg_audit"
    else
        echo "Keine dpkg Audit Auffälligkeiten."
    fi

    echo
    echo "systemd fehlgeschlagene Units:"
    systemctl --failed --no-pager || true

    echo
    echo "SSH Status:"
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl is-active ssh.service || warn "ssh.service ist nicht aktiv. Falls der Pi headless per SSH genutzt wird, prüfen."
        systemctl is-enabled ssh.service || true
    else
        echo "ssh.service nicht gefunden."
    fi

    echo
    echo "Aktuelle Fehler aus diesem Boot, Priorität err..alert, letzte 80 Zeilen:"
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
        echo "Weich heißt: Ein kompletter Neustart ist sauber und einfach, aber eventuell reicht auch ein Dienstneustart."
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
        echo "Empfehlung: needrestart Ausgabe prüfen oder sauberheitshalber sudo reboot ausführen."
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
    local arg_count="$#"

    parse_args "$@"

    if [[ "$arg_count" -eq 0 ]]; then
        show_interactive_option_menu
    fi

    setup_sudo_and_apt
    require_sudo
    ensure_required_tools
    ensure_optional_tools
    create_temp_files
    init_logging
    choose_mode
    print_header
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
