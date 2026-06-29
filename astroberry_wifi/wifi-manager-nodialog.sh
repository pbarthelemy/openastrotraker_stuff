#!/usr/bin/env bash
# =============================================================================
# wifi-manager-nodialog.sh — WiFi TUI manager for Astroberry (Pi 4 / Pi 5)
#
# Pure-bash TUI (NO dependency on `dialog`). Needs only bash + the networking
# tools that ship with Astroberry (wpa_supplicant, dhcpcd, hostapd, dnsmasq,
# iptables, iw, ip).
#
#   AP interface     (default wlan0) : built-in chip, AP mode (hostapd)
#   client interface (default wlan1) : USB dongle, WiFi client (wpa_supplicant)
#
# ALL settings can be supplied from a config file (see CONFIGURATION below and
# the documented template wifi-manager.conf.example). Built-in defaults are used
# when no config file is present, so the script also works with zero config.
#
# Usage: sudo bash wifi-manager-nodialog.sh [-c CONFIG_FILE]
# =============================================================================

set -euo pipefail

# --- Fixed constants ----------------------------------------------------------
readonly SCRIPT_VERSION="2.1"

# =============================================================================
# CONFIGURATION (defaults — every variable below can be overridden by the
# config file, which is sourced as bash). See wifi-manager.conf.example.
# =============================================================================

# Interface names
IFACE_AP="wlan0"           # AP / built-in interface (stays in AP mode)
IFACE_CLIENT="wlan1"       # client / USB dongle (used for internet)

# WiFi client behaviour
WIFI_COUNTRY="CA"          # 2-letter ISO country code for the regulatory domain
WPA_DRIVER="nl80211,wext"  # wpa_supplicant -D driver string
CONNECT_TIMEOUT="15"       # seconds to wait for association before giving up

# Routing metrics (lower = higher priority for the default route)
DEFAULT_METRIC_AP="300"
DEFAULT_METRIC_CLIENT="200"

# Internet sharing
ENABLE_NAT="yes"           # yes|no — set up NAT so AP clients reach the internet

# User interface
DEFAULT_LANG="ask"         # ask|en|fr — "ask" shows the startup language picker

# File paths
WPA_CONF_DIR="/etc/wpa_supplicant"
WPA_CONF_CLIENT=""         # leave empty to auto-derive from WPA_CONF_DIR+IFACE_CLIENT
WPA_PID_CLIENT=""          # leave empty to auto-derive
DHCPCD_CONF="/etc/dhcpcd.conf"
UDEV_RULES="/etc/udev/rules.d/70-persistent-wifi.rules"
LOG_FILE="/var/log/wifi-manager.log"
LOCK_FILE="/var/run/wifi-manager.lock"

# Config file location (resolved in parse_args; env var or -c can override)
CONFIG_FILE="${WIFI_MANAGER_CONF:-/etc/wifi-manager.conf}"
EXPLICIT_CONFIG="no"

# ANSI colors as real escape characters
C_RESET=$'\033[0m'
C_HDR=$'\033[1;32m'
C_TITLE=$'\033[1;37m'
C_BLUE=$'\033[1;34m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_DIM=$'\033[0;90m'
C_RED=$'\033[0;31m'

# =============================================================================
# Internationalization (i18n)
# =============================================================================

UI_LANG="en"
declare -A MSG_FR
declare -A MSG_EN

# ---- French table -----------------------------------------------------------
MSG_FR[st_ap_active]="AP actif"
MSG_FR[st_absent]="absent"
MSG_FR[st_unknown]="inconnu"
MSG_FR[st_connected_fmt]="Connecté → %s (%s)"
MSG_FR[st_active_notconn_fmt]="Actif (non connecté — état: %s)"
MSG_FR[st_inactive_fmt]="inactif (%s)"
MSG_FR[if_usb_fmt]="Dongle USB  (MAC %s)"
MSG_FR[if_builtin_fmt]="Intégrée    (MAC %s)"
MSG_FR[if_absent]="(absente)"
MSG_FR[if_unknown_fmt]="Inconnue    (MAC %s)"
MSG_FR[main_title]="Menu principal"
MSG_FR[mi_ap]="Gérer %s  (Point d'accès Astroberry)"
MSG_FR[mi_client]="Gérer %s  (Dongle WiFi internet)"
MSG_FR[mi_select]="Choisir réseau WiFi…"
MSG_FR[mi_metric]="Priorité des interfaces (metric)"
MSG_FR[mi_udev]="Fixer les noms d'interface (udev)"
MSG_FR[mi_status]="Afficher l'état du réseau"
MSG_FR[mi_quit]="Quitter"
MSG_FR[ap_title]="%s — Point d'accès Astroberry"
MSG_FR[ap_menu_fmt]="État actuel : %s\n\n⚠  Désactiver %s coupe l'AP et toute connexion distante."
MSG_FR[ap_enable]="Activer l'AP (hostapd + dnsmasq)"
MSG_FR[ap_disable]="Désactiver l'AP  [⚠ DÉCONNEXION]"
MSG_FR[back]="Retour"
MSG_FR[ap_enabling]="Activation de %s (AP)…"
MSG_FR[ap_enabled_ok]="✓ AP Astroberry activé."
MSG_FR[err_see_log_fmt]="✗ Erreur. Voir %s"
MSG_FR[ap_confirm_title]="Confirmation"
MSG_FR[ap_confirm_msg]="Désactiver l'AP %s va couper toutes les connexions WiFi vers Astroberry.\n\nContinuer ?"
MSG_FR[ap_disabling]="Désactivation de %s…"
MSG_FR[ap_disabled_msg]="AP désactivé.\n\nReconnectez-vous via SSH/Ethernet ou écran."
MSG_FR[cl_title]="%s — Dongle WiFi (accès Internet)"
MSG_FR[cl_menu_fmt]="État actuel : %s"
MSG_FR[cl_enable]="Activer le dongle %s"
MSG_FR[cl_select]="Choisir un réseau WiFi…"
MSG_FR[cl_disable]="Désactiver le dongle %s"
MSG_FR[cl_enabling]="Activation de %s…"
MSG_FR[cl_enabled_ok]="✓ Dongle activé."
MSG_FR[cl_err_fmt]="✗ Erreur. Dongle branché ? Voir %s"
MSG_FR[cl_disabling]="Désactivation de %s…"
MSG_FR[cl_disabled_ok]="✓ Dongle désactivé. NAT retiré."
MSG_FR[scan_title]="Réseaux WiFi disponibles"
MSG_FR[scan_progress]="Scan des réseaux WiFi en cours… (peut prendre ~5 secondes)"
MSG_FR[scan_prompt]="Choisissez un réseau :"
MSG_FR[scan_box]="Scan"
MSG_FR[scan_none_msg]="Aucun réseau trouvé.\n\nVérifiez que le dongle est actif et branché."
MSG_FR[scan_none2]="Aucun réseau détecté."
MSG_FR[pw_title_fmt]="Connexion : %s"
MSG_FR[pw_prompt]="Mot de passe WiFi (laisser vide si réseau ouvert) :"
MSG_FR[conn_progress_fmt]="Connexion à '%s' en cours…"
MSG_FR[conn_ok_title]="Succès"
MSG_FR[conn_ok_fmt]="✓ Connecté à : %s\n  IP obtenue  : %s\n\nLe NAT est actif — les clients AP ont accès à Internet."
MSG_FR[conn_fail_title]="Échec"
MSG_FR[conn_fail_fmt]="✗ Impossible de se connecter à '%s'.\n\nVérifiez le mot de passe ou la disponibilité.\nJournal : %s"
MSG_FR[met_title]="Priorité des interfaces (metric)"
MSG_FR[met_menu_fmt]="Metric configurée (dhcpcd.conf) :\n  %s (AP)  : %s\n  %s (Net) : %s\n\nRoutes actives (kernel) :\n%s\n\nRappel : metric basse = priorité haute."
MSG_FR[met_default]="(défaut)"
MSG_FR[met_live_none]="  (aucune route par défaut active)"
MSG_FR[met_opt1]="Dongle prioritaire pour internet (recommandé)"
MSG_FR[met_opt2]="Saisir des metrics personnalisées"
MSG_FR[met_opt3]="Réinitialiser (retirer les metrics gérées)"
MSG_FR[met_box]="Metrics"
MSG_FR[met_applied_preset_fmt]="✓ Appliqué :\n  %s → metric %s\n  %s → metric %s\n\nLe dongle est maintenant la route internet préférée. dhcpcd a été redémarré."
MSG_FR[met_in_cl_title]="Metric pour %s (dongle internet) — plus bas = prioritaire"
MSG_FR[met_in_ap_title]="Metric pour %s (AP)"
MSG_FR[met_invalid]="✗ Valeurs invalides (chiffres uniquement)."
MSG_FR[met_applied_custom_fmt]="✓ Appliqué :\n  %s → metric %s\n  %s → metric %s\n\ndhcpcd a été redémarré."
MSG_FR[met_reset_ok]="✓ Metrics gérées retirées de dhcpcd.conf.\nValeurs par défaut de dhcpcd restaurées."
MSG_FR[udev_title]="Fixer les noms d'interface (udev)"
MSG_FR[udev_detected_hdr]="Interfaces détectées :\n\n"
MSG_FR[udev_builtin_fmt]="  Intégrée   : %s  [%s]\n"
MSG_FR[udev_builtin_none]="  Intégrée   : NON DÉTECTÉE\n"
MSG_FR[udev_usb_fmt]="  Dongle USB : %s  [%s]\n"
MSG_FR[udev_usb_none]="  Dongle USB : NON DÉTECTÉ\n"
MSG_FR[udev_box]="Fixer les noms"
MSG_FR[udev_cant_fmt]="%s\nImpossible de continuer : les deux interfaces (intégrée + USB) doivent être présentes pour créer une règle fiable."
MSG_FR[udev_none]="(aucune)"
MSG_FR[udev_confirm_fmt]="%s\nRègle proposée :\n  Intégrée → %s  (AP Astroberry)\n  Dongle USB → %s (internet)\n\nRègle existante : %s\n\nÉcrire/écraser la règle udev ?"
MSG_FR[udev_written_fmt]="✓ Règle écrite dans :\n%s\n\nLes noms seront appliqués au PROCHAIN REDÉMARRAGE.\n(Un renommage à chaud n'est pas possible si l'interface est déjà active.)\n\nPensez à redémarrer : sudo reboot"
MSG_FR[status_title]="État du réseau"
MSG_FR[lbl_model]="Modèle"
MSG_FR[lbl_ip]="IP"
MSG_FR[lbl_gw]="Passerelle"
MSG_FR[lbl_fwd]="IP forward"
MSG_FR[lbl_nat]="NAT"
MSG_FR[lbl_routes]="Routes par défaut :"
MSG_FR[nat_off]="désactivé"
MSG_FR[nat_disabled_cfg]="désactivé (config)"
MSG_FR[nat_on_fmt]="ACTIF (%s règle(s))"
MSG_FR[live_none]="(aucune)"
MSG_FR[warn_model_title]="Modèle non validé"
MSG_FR[warn_model_fmt]="⚠  Modèle détecté : %s\n\nValidé pour Pi 4 et Pi 5. La détection de la puce WiFi intégrée peut être imprécise ici.\nLe script continue, mais vérifiez l'écran d'état."
MSG_FR[warn_nodongle_title]="Avertissement"
MSG_FR[warn_nodongle_fmt]="⚠  Aucune interface client (%s) détectée.\n\nVérifiez que le dongle est branché. Le script continuera mais le client sera non fonctionnel."
MSG_FR[cleanup_msg]="wifi-manager fermé."
MSG_FR[summary_hdr]="Adresses MAC / IP (pour réservation DHCP) :"
MSG_FR[prompt_choice]="Votre choix : "
MSG_FR[prompt_enter]="Appuyez sur Entrée pour continuer…"
MSG_FR[prompt_yesno]="[o/N] : "
MSG_FR[prompt_value_fmt]="Valeur [%s] : "

# ---- English table ----------------------------------------------------------
MSG_EN[st_ap_active]="AP active"
MSG_EN[st_absent]="absent"
MSG_EN[st_unknown]="unknown"
MSG_EN[st_connected_fmt]="Connected → %s (%s)"
MSG_EN[st_active_notconn_fmt]="Active (not connected — state: %s)"
MSG_EN[st_inactive_fmt]="inactive (%s)"
MSG_EN[if_usb_fmt]="USB dongle  (MAC %s)"
MSG_EN[if_builtin_fmt]="Built-in    (MAC %s)"
MSG_EN[if_absent]="(absent)"
MSG_EN[if_unknown_fmt]="Unknown     (MAC %s)"
MSG_EN[main_title]="Main menu"
MSG_EN[mi_ap]="Manage %s  (Astroberry access point)"
MSG_EN[mi_client]="Manage %s  (WiFi internet dongle)"
MSG_EN[mi_select]="Select WiFi network…"
MSG_EN[mi_metric]="Interface priority (metric)"
MSG_EN[mi_udev]="Pin interface names (udev)"
MSG_EN[mi_status]="Show network status"
MSG_EN[mi_quit]="Quit"
MSG_EN[ap_title]="%s — Astroberry access point"
MSG_EN[ap_menu_fmt]="Current state: %s\n\n⚠  Disabling %s stops the AP and all remote connections."
MSG_EN[ap_enable]="Enable AP (hostapd + dnsmasq)"
MSG_EN[ap_disable]="Disable AP  [⚠ DISCONNECT]"
MSG_EN[back]="Back"
MSG_EN[ap_enabling]="Enabling %s (AP)…"
MSG_EN[ap_enabled_ok]="✓ Astroberry AP enabled."
MSG_EN[err_see_log_fmt]="✗ Error. See %s"
MSG_EN[ap_confirm_title]="Confirmation"
MSG_EN[ap_confirm_msg]="Disabling the %s AP will drop all WiFi connections to Astroberry.\n\nContinue?"
MSG_EN[ap_disabling]="Disabling %s…"
MSG_EN[ap_disabled_msg]="AP disabled.\n\nReconnect via SSH/Ethernet or a screen."
MSG_EN[cl_title]="%s — WiFi dongle (Internet access)"
MSG_EN[cl_menu_fmt]="Current state: %s"
MSG_EN[cl_enable]="Enable %s dongle"
MSG_EN[cl_select]="Select a WiFi network…"
MSG_EN[cl_disable]="Disable %s dongle"
MSG_EN[cl_enabling]="Enabling %s…"
MSG_EN[cl_enabled_ok]="✓ Dongle enabled."
MSG_EN[cl_err_fmt]="✗ Error. Is the dongle plugged in? See %s"
MSG_EN[cl_disabling]="Disabling %s…"
MSG_EN[cl_disabled_ok]="✓ Dongle disabled. NAT removed."
MSG_EN[scan_title]="Available WiFi networks"
MSG_EN[scan_progress]="Scanning WiFi networks… (may take ~5 seconds)"
MSG_EN[scan_prompt]="Choose a network:"
MSG_EN[scan_box]="Scan"
MSG_EN[scan_none_msg]="No network found.\n\nCheck that the dongle is active and plugged in."
MSG_EN[scan_none2]="No network detected."
MSG_EN[pw_title_fmt]="Connect: %s"
MSG_EN[pw_prompt]="WiFi password (leave empty for an open network):"
MSG_EN[conn_progress_fmt]="Connecting to '%s'…"
MSG_EN[conn_ok_title]="Success"
MSG_EN[conn_ok_fmt]="✓ Connected to: %s\n  IP obtained : %s\n\nNAT is active — AP clients now have Internet access."
MSG_EN[conn_fail_title]="Failed"
MSG_EN[conn_fail_fmt]="✗ Could not connect to '%s'.\n\nCheck the password or availability.\nLog: %s"
MSG_EN[met_title]="Interface priority (metric)"
MSG_EN[met_menu_fmt]="Configured metric (dhcpcd.conf):\n  %s (AP)  : %s\n  %s (Net) : %s\n\nActive routes (kernel):\n%s\n\nReminder: lower metric = higher priority."
MSG_EN[met_default]="(default)"
MSG_EN[met_live_none]="  (no active default route)"
MSG_EN[met_opt1]="Prioritize the dongle for internet (recommended)"
MSG_EN[met_opt2]="Enter custom metrics"
MSG_EN[met_opt3]="Reset (remove managed metrics)"
MSG_EN[met_box]="Metrics"
MSG_EN[met_applied_preset_fmt]="✓ Applied:\n  %s → metric %s\n  %s → metric %s\n\nThe dongle is now the preferred internet route. dhcpcd has been restarted."
MSG_EN[met_in_cl_title]="Metric for %s (internet dongle) — lower = higher priority"
MSG_EN[met_in_ap_title]="Metric for %s (AP)"
MSG_EN[met_invalid]="✗ Invalid values (digits only)."
MSG_EN[met_applied_custom_fmt]="✓ Applied:\n  %s → metric %s\n  %s → metric %s\n\ndhcpcd has been restarted."
MSG_EN[met_reset_ok]="✓ Managed metrics removed from dhcpcd.conf.\ndhcpcd defaults restored."
MSG_EN[udev_title]="Pin interface names (udev)"
MSG_EN[udev_detected_hdr]="Detected interfaces:\n\n"
MSG_EN[udev_builtin_fmt]="  Built-in   : %s  [%s]\n"
MSG_EN[udev_builtin_none]="  Built-in   : NOT DETECTED\n"
MSG_EN[udev_usb_fmt]="  USB dongle : %s  [%s]\n"
MSG_EN[udev_usb_none]="  USB dongle : NOT DETECTED\n"
MSG_EN[udev_box]="Pin names"
MSG_EN[udev_cant_fmt]="%s\nCannot continue: both interfaces (built-in + USB) must be present to create a reliable rule."
MSG_EN[udev_none]="(none)"
MSG_EN[udev_confirm_fmt]="%s\nProposed rule:\n  Built-in → %s  (Astroberry AP)\n  USB dongle → %s (internet)\n\nExisting rule: %s\n\nWrite/overwrite the udev rule?"
MSG_EN[udev_written_fmt]="✓ Rule written to:\n%s\n\nNames will apply on the NEXT REBOOT.\n(Live renaming is not possible while the interface is already active.)\n\nRemember to reboot: sudo reboot"
MSG_EN[status_title]="Network status"
MSG_EN[lbl_model]="Model"
MSG_EN[lbl_ip]="IP"
MSG_EN[lbl_gw]="Gateway"
MSG_EN[lbl_fwd]="IP forward"
MSG_EN[lbl_nat]="NAT"
MSG_EN[lbl_routes]="Default routes:"
MSG_EN[nat_off]="disabled"
MSG_EN[nat_disabled_cfg]="disabled (config)"
MSG_EN[nat_on_fmt]="ACTIVE (%s rule(s))"
MSG_EN[live_none]="(none)"
MSG_EN[warn_model_title]="Unvalidated model"
MSG_EN[warn_model_fmt]="⚠  Detected model: %s\n\nValidated for Pi 4 and Pi 5. Built-in WiFi chip detection may be inaccurate here.\nThe script continues, but check the status screen."
MSG_EN[warn_nodongle_title]="Warning"
MSG_EN[warn_nodongle_fmt]="⚠  No client interface (%s) detected.\n\nCheck that the dongle is plugged in. The script will continue but the client will be non-functional."
MSG_EN[cleanup_msg]="wifi-manager closed."
MSG_EN[summary_hdr]="MAC / IP addresses (for DHCP reservation):"
MSG_EN[prompt_choice]="Your choice: "
MSG_EN[prompt_enter]="Press Enter to continue…"
MSG_EN[prompt_yesno]="[y/N]: "
MSG_EN[prompt_value_fmt]="Value [%s]: "

t() {
    local key="$1"
    if [[ "$UI_LANG" == "fr" ]]; then
        printf '%s' "${MSG_FR[$key]:-$key}"
    else
        printf '%s' "${MSG_EN[$key]:-${MSG_FR[$key]:-$key}}"
    fi
}

tf() {
    local key="$1"; shift
    # shellcheck disable=SC2059
    printf "$(t "$key")" "$@"
}

# =============================================================================
# Utilities
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
}

die() {
    printf '%s\n' "${C_RED}$*${C_RESET}" >&2
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Must be run as root (sudo). / Doit être exécuté en tant que root (sudo)."
}

# =============================================================================
# Configuration loading
# =============================================================================

print_help() {
    cat <<EOF
wifi-manager-nodialog.sh v${SCRIPT_VERSION}

Pure-bash WiFi manager for Astroberry (no dialog dependency).

Usage:
  sudo bash wifi-manager-nodialog.sh [options]

Options:
  -c, --config FILE   Use FILE as the configuration file.
                      Default: \$WIFI_MANAGER_CONF or /etc/wifi-manager.conf
  -h, --help          Show this help and exit.

All settings (interface names, metrics, country code, NAT, default language,
file paths, timeouts) can be set in the config file. See the documented
template 'wifi-manager.conf.example'. When no config file exists, built-in
defaults are used.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [[ $# -ge 2 ]] || die "Option $1 requires a path argument."
                CONFIG_FILE="$2"; EXPLICIT_CONFIG="yes"; shift 2 ;;
            -h|--help)
                print_help; exit 0 ;;
            *)
                printf '%s\n' "Unknown option: $1" >&2
                print_help >&2
                exit 2 ;;
        esac
    done
}

# Source the config file as bash, with basic safety checks. Because the file is
# sourced (so it can set any variable), we refuse to load it unless it is owned
# by root and not writable by group/other — this prevents an unprivileged user
# from injecting code that would run with root privileges.
load_config() {
    local f="$CONFIG_FILE"
    if [[ ! -f "$f" ]]; then
        if [[ "$EXPLICIT_CONFIG" == "yes" ]]; then
            die "Config file not found: $f"
        fi
        log "No config file at $f; using built-in defaults."
        return 0
    fi
    local owner
    owner=$(stat -c '%u' "$f" 2>/dev/null || echo "")
    [[ "$owner" == "0" ]] || die "Config $f must be owned by root (chown root:root $f)."
    if find "$f" -maxdepth 0 -perm /022 2>/dev/null | grep -q .; then
        die "Config $f is group/other-writable; refusing to load (chmod 600 or 644 $f)."
    fi
    # shellcheck disable=SC1090
    source "$f"
    log "Loaded config from $f"
}

# Validate config values; abort with a clear message on anything malformed.
validate_config() {
    [[ "$IFACE_AP" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid IFACE_AP: '$IFACE_AP'"
    [[ "$IFACE_CLIENT" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid IFACE_CLIENT: '$IFACE_CLIENT'"
    [[ "$IFACE_AP" != "$IFACE_CLIENT" ]] || die "IFACE_AP and IFACE_CLIENT must differ."
    [[ "$DEFAULT_METRIC_AP" =~ ^[0-9]+$ ]] || die "DEFAULT_METRIC_AP must be a number."
    [[ "$DEFAULT_METRIC_CLIENT" =~ ^[0-9]+$ ]] || die "DEFAULT_METRIC_CLIENT must be a number."
    [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ && "$CONNECT_TIMEOUT" -ge 1 ]] || die "CONNECT_TIMEOUT must be a positive integer."
    [[ "$WIFI_COUNTRY" =~ ^[A-Za-z]{2}$ ]] || die "WIFI_COUNTRY must be a 2-letter ISO code."
    case "$DEFAULT_LANG" in ask|en|fr) ;; *) die "DEFAULT_LANG must be ask, en, or fr." ;; esac
    case "$ENABLE_NAT" in yes|no) ;; *) die "ENABLE_NAT must be yes or no." ;; esac
}

# Fill in any paths left empty, deriving them from the (possibly overridden)
# interface names and directories.
derive_paths() {
    [[ -n "$WPA_CONF_CLIENT" ]] || WPA_CONF_CLIENT="${WPA_CONF_DIR%/}/wpa_supplicant-${IFACE_CLIENT}.conf"
    [[ -n "$WPA_PID_CLIENT"  ]] || WPA_PID_CLIENT="/var/run/wpa_supplicant_${IFACE_CLIENT}.pid"
}

print_iface_summary() {
    local iface mac ip
    echo ""
    echo "$(t summary_hdr)"
    printf '  %-7s  %-17s  %s\n' "Iface" "MAC" "IPv4"
    for iface in "$IFACE_AP" "$IFACE_CLIENT"; do
        if [[ -e "/sys/class/net/$iface" ]]; then
            mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "??:??:??:??:??:??")
            ip=$(ip -4 addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
            [[ -z "$ip" ]] && ip="-"
            printf '  %-7s  %-17s  %s\n' "$iface" "$mac" "$ip"
        else
            printf '  %-7s  %-17s  %s\n' "$iface" "(absent)" "-"
        fi
    done
    echo ""
}

cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    printf '\033[2J\033[H'
    printf '%s\n' "${C_GREEN}$(t cleanup_msg)${C_RESET}"
    print_iface_summary
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        kill -0 "$pid" 2>/dev/null && \
            die "Already running / Déjà en cours (PID $pid)."
    fi
    echo $$ > "$LOCK_FILE"
}

# =============================================================================
# Pure-bash UI helpers
# =============================================================================

ui_clear() { printf '\033[2J\033[H'; }

ui_sep() {
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
}

ui_header() {
    ui_clear
    printf '%s\n' "${C_HDR}WiFi Manager — Astroberry v${SCRIPT_VERSION} — Pi ${PI_GEN}${C_RESET}"
    ui_sep
}

ui_title() {
    printf '%s\n\n' "${C_TITLE}$1${C_RESET}"
}

ui_body() {
    printf '%b\n' "$1"
}

ui_pause() {
    echo
    read -rp "$(t prompt_enter) " _ || true
}

ui_msg() {
    ui_header
    ui_title "$1"
    ui_body "$2"
    ui_pause
}

ui_info() {
    ui_header
    ui_body "$1"
    echo
}

ui_yesno() {
    local title="$1" body="$2" ans=""
    ui_header
    ui_title "$title"
    ui_body "$body"
    echo
    read -rp "$(t prompt_yesno)" ans || true
    case "$ans" in
        [yYoO]*) return 0 ;;
        *)       return 1 ;;
    esac
}

colorize_status() {
    local s="$1"
    case "$s" in
        *active*|*actif*|*Connect*|*Connecté*) printf '%s%s%s' "$C_GREEN" "$s" "$C_RESET" ;;
        *absent*|*inactif*|*inactive*)         printf '%s%s%s' "$C_DIM"   "$s" "$C_RESET" ;;
        *)                                     printf '%s' "$s" ;;
    esac
}

# =============================================================================
# Raspberry Pi model detection
# =============================================================================

PI_MODEL="unknown"
PI_GEN="unknown"

detect_pi_model() {
    local model=""
    if [[ -r /proc/device-tree/model ]]; then
        model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    fi
    if [[ -z "$model" && -r /proc/cpuinfo ]]; then
        model=$(grep -m1 -i '^Model' /proc/cpuinfo | cut -d: -f2- | xargs || echo "")
    fi
    PI_MODEL="${model:-unknown}"
    case "$PI_MODEL" in
        *"Raspberry Pi 5"*) PI_GEN="5" ;;
        *"Raspberry Pi 4"*) PI_GEN="4" ;;
        *"Raspberry Pi"*)   PI_GEN="other" ;;
        *)                  PI_GEN="unknown" ;;
    esac
    log "Detected model: '$PI_MODEL' (generation=$PI_GEN)"
}

# =============================================================================
# Interface identification (built-in vs USB)
# =============================================================================

get_iface_bus() {
    local iface="$1" devpath
    [[ -e "/sys/class/net/$iface" ]] || { echo "absent"; return; }
    devpath=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")
    if [[ "$devpath" == *"/usb"* ]]; then
        echo "usb"
    elif [[ "$devpath" == *"mmc"* || "$devpath" == *"sdio"* ]]; then
        echo "builtin"
    elif [[ -n "$devpath" ]]; then
        echo "builtin"
    else
        echo "unknown"
    fi
}

get_iface_mac() {
    local iface="$1"
    cat "/sys/class/net/$iface/address" 2>/dev/null || echo ""
}

describe_iface() {
    local iface="$1" bus mac
    bus=$(get_iface_bus "$iface")
    mac=$(get_iface_mac "$iface")
    case "$bus" in
        usb)     tf if_usb_fmt "$mac" ;;
        builtin) tf if_builtin_fmt "$mac" ;;
        absent)  t if_absent ;;
        *)       tf if_unknown_fmt "$mac" ;;
    esac
}

# List all wireless-capable interfaces (works even if renamed away from wlanN)
_wifi_ifaces() {
    local d name
    for d in /sys/class/net/*; do
        [[ -e "$d" ]] || continue
        name=$(basename "$d")
        [[ -e "$d/wireless" || -e "$d/phy80211" ]] && echo "$name"
    done
}

find_builtin_iface() {
    local name
    while read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$(get_iface_bus "$name")" == "builtin" ]] && { echo "$name"; return; }
    done < <(_wifi_ifaces)
    echo ""
}

find_usb_iface() {
    local name
    while read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$(get_iface_bus "$name")" == "usb" ]] && { echo "$name"; return; }
    done < <(_wifi_ifaces)
    echo ""
}

# =============================================================================
# Network functions — AP interface
# =============================================================================

get_ap_status() {
    if systemctl is-active --quiet hostapd 2>/dev/null; then
        t st_ap_active
    elif ip link show "$IFACE_AP" &>/dev/null; then
        cat "/sys/class/net/$IFACE_AP/operstate" 2>/dev/null || t st_unknown
    else
        t st_absent
    fi
}

enable_ap() {
    log "Enabling $IFACE_AP (AP / hostapd)"
    ip link set "$IFACE_AP" up 2>/dev/null || true
    systemctl start hostapd  && log "hostapd started"
    systemctl start dnsmasq  2>/dev/null && log "dnsmasq started" || true
    systemctl restart dhcpcd && log "dhcpcd restarted"
    return 0
}

disable_ap() {
    log "Disabling $IFACE_AP (AP / hostapd)"
    systemctl stop hostapd  && log "hostapd stopped"
    systemctl stop dnsmasq  2>/dev/null && log "dnsmasq stopped" || true
    ip link set "$IFACE_AP" down 2>/dev/null && log "$IFACE_AP down" || true
    return 0
}

# =============================================================================
# Network functions — client interface
# =============================================================================

get_client_status() {
    if ! ip link show "$IFACE_CLIENT" &>/dev/null; then
        t st_absent
        return
    fi
    local state
    state=$(cat "/sys/class/net/$IFACE_CLIENT/operstate" 2>/dev/null || echo "unknown")
    if [[ "$state" == "up" ]]; then
        local wpa_state
        wpa_state=$(wpa_cli -i "$IFACE_CLIENT" status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "N/A")
        if [[ "$wpa_state" == "COMPLETED" ]]; then
            local ssid ip
            ssid=$(wpa_cli -i "$IFACE_CLIENT" status 2>/dev/null | grep '^ssid=' | cut -d= -f2 || echo "?")
            ip=$(ip -4 addr show "$IFACE_CLIENT" 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
            tf st_connected_fmt "$ssid" "$ip"
        else
            tf st_active_notconn_fmt "$wpa_state"
        fi
    else
        tf st_inactive_fmt "$state"
    fi
}

init_wpa_conf_client() {
    if [[ ! -f "$WPA_CONF_CLIENT" ]]; then
        log "Creating $WPA_CONF_CLIENT"
        mkdir -p "$(dirname "$WPA_CONF_CLIENT")"
        cat > "$WPA_CONF_CLIENT" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

EOF
        chmod 600 "$WPA_CONF_CLIENT"
    fi
}

enable_client() {
    log "Enabling client interface $IFACE_CLIENT"
    init_wpa_conf_client
    ip link set "$IFACE_CLIENT" up 2>/dev/null || { log "Cannot bring up $IFACE_CLIENT"; return 1; }
    pkill -f "wpa_supplicant.*$IFACE_CLIENT" 2>/dev/null || true
    sleep 0.5
    wpa_supplicant -B -D "$WPA_DRIVER" \
        -i "$IFACE_CLIENT" \
        -c "$WPA_CONF_CLIENT" \
        -P "$WPA_PID_CLIENT" \
        && log "wpa_supplicant started on $IFACE_CLIENT" \
        || { log "wpa_supplicant failed on $IFACE_CLIENT"; return 1; }
    dhcpcd "$IFACE_CLIENT" 2>/dev/null && log "dhcpcd on $IFACE_CLIENT OK" || true
    enable_nat
    return 0
}

disable_client() {
    log "Disabling client interface $IFACE_CLIENT"
    dhcpcd -k "$IFACE_CLIENT" 2>/dev/null && log "dhcpcd $IFACE_CLIENT released" || true
    if [[ -f "$WPA_PID_CLIENT" ]]; then
        kill "$(cat "$WPA_PID_CLIENT")" 2>/dev/null || true
        rm -f "$WPA_PID_CLIENT"
    fi
    pkill -f "wpa_supplicant.*$IFACE_CLIENT" 2>/dev/null || true
    ip link set "$IFACE_CLIENT" down 2>/dev/null && log "$IFACE_CLIENT down" || true
    disable_nat
    return 0
}

# =============================================================================
# NAT (client -> AP clients)
# =============================================================================

enable_nat() {
    if [[ "$ENABLE_NAT" != "yes" ]]; then
        log "NAT disabled by config; skipping"
        return 0
    fi
    log "Enabling NAT $IFACE_CLIENT -> $IFACE_AP"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
    iptables -t nat -C POSTROUTING -o "$IFACE_CLIENT" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o "$IFACE_CLIENT" -j MASQUERADE
    iptables -C FORWARD -i "$IFACE_CLIENT" -o "$IFACE_AP" -m state \
        --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i "$IFACE_CLIENT" -o "$IFACE_AP" -m state \
           --state RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -i "$IFACE_AP" -o "$IFACE_CLIENT" -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i "$IFACE_AP" -o "$IFACE_CLIENT" -j ACCEPT
    log "NAT enabled"
}

disable_nat() {
    log "Disabling NAT"
    iptables -t nat -D POSTROUTING -o "$IFACE_CLIENT" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$IFACE_CLIENT" -o "$IFACE_AP" -m state \
        --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$IFACE_AP" -o "$IFACE_CLIENT" -j ACCEPT 2>/dev/null || true
    echo 0 > /proc/sys/net/ipv4/ip_forward
    log "NAT disabled"
}

# =============================================================================
# Routing metric management
# =============================================================================

get_configured_metric() {
    local iface="$1"
    awk -v ifc="$iface" '
        $1=="interface" && $2==ifc { found=1; next }
        found && $1=="interface" { found=0 }
        found && $1=="metric" { print $2; exit }
    ' "$DHCPCD_CONF" 2>/dev/null || echo ""
}

get_live_metrics() {
    ip route show default 2>/dev/null \
        | awk '{
            ifc="?"; m="?"
            for(i=1;i<=NF;i++){
                if($i=="dev") ifc=$(i+1)
                if($i=="metric") m=$(i+1)
            }
            print "  " ifc " -> metric " m
        }'
}

set_interface_metric() {
    local iface="$1" metric="$2"
    log "Setting metric $metric for $iface in $DHCPCD_CONF"
    [[ -f "${DHCPCD_CONF}.wifimgr.bak" ]] || cp "$DHCPCD_CONF" "${DHCPCD_CONF}.wifimgr.bak"
    local marker_start="# >>> wifi-manager metric: ${iface} >>>"
    local marker_end="# <<< wifi-manager metric: ${iface} <<<"
    sed -i "/${marker_start}/,/${marker_end}/d" "$DHCPCD_CONF"
    {
        echo ""
        echo "$marker_start"
        echo "interface ${iface}"
        echo "metric ${metric}"
        echo "$marker_end"
    } >> "$DHCPCD_CONF"
    log "Metric block written for $iface"
}

remove_managed_metric() {
    local iface="$1"
    sed -i "/# >>> wifi-manager metric: ${iface} >>>/,/# <<< wifi-manager metric: ${iface} <<</d" "$DHCPCD_CONF"
}

# =============================================================================
# Persistent interface naming (udev)
# =============================================================================

write_udev_rules() {
    local builtin_mac="$1" usb_mac="$2"
    log "Writing udev naming rules (builtin=$builtin_mac -> $IFACE_AP, usb=$usb_mac -> $IFACE_CLIENT)"
    cat > "$UDEV_RULES" <<EOF
# Generated by wifi-manager — persistent WiFi interface names
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${builtin_mac}", NAME="${IFACE_AP}"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${usb_mac}", NAME="${IFACE_CLIENT}"
EOF
    chmod 644 "$UDEV_RULES"
    log "udev rules written to $UDEV_RULES"
}

# =============================================================================
# WiFi scan / connect
# =============================================================================

scan_networks() {
    log "Scanning WiFi networks on $IFACE_CLIENT"
    ip link set "$IFACE_CLIENT" up 2>/dev/null || true
    sleep 1
    local results=""
    if command -v iw &>/dev/null; then
        results=$(iw dev "$IFACE_CLIENT" scan 2>/dev/null \
            | awk '
                /^BSS [0-9a-f:]{17}/ { signal="?"; ssid="" }
                /signal:/ { signal=$2" "$3 }
                /SSID:/ && $2!="" { ssid=substr($0, index($0,$2)); print ssid "|" signal }
            ' \
            | sort -t'|' -k2 -rn | head -20 || true)
    fi
    if [[ -z "$results" ]]; then
        wpa_cli -i "$IFACE_CLIENT" scan 2>/dev/null || true
        sleep 2
        results=$(wpa_cli -i "$IFACE_CLIENT" scan_results 2>/dev/null \
            | tail -n +2 \
            | awk '{ ssid=""; for(i=5;i<=NF;i++) ssid=ssid (i>5?" ":"") $i;
                     if(ssid!="") print ssid "|" $3 " dBm" }' \
            | head -20 || true)
    fi
    echo "$results"
}

connect_network() {
    local ssid="$1" password="$2"
    log "Connecting to network: $ssid"
    init_wpa_conf_client
    if ! pgrep -f "wpa_supplicant.*$IFACE_CLIENT" &>/dev/null; then
        enable_client
        sleep 1
    fi
    local net_id
    net_id=$(wpa_cli -i "$IFACE_CLIENT" add_network 2>/dev/null | tail -1)
    if [[ -z "$net_id" || "$net_id" == "FAIL" ]]; then
        enable_client
        sleep 2
        net_id=$(wpa_cli -i "$IFACE_CLIENT" add_network 2>/dev/null | tail -1)
    fi
    [[ "$net_id" =~ ^[0-9]+$ ]] || { log "Cannot add network"; return 1; }
    wpa_cli -i "$IFACE_CLIENT" set_network "$net_id" ssid "\"$ssid\"" >/dev/null 2>&1
    wpa_cli -i "$IFACE_CLIENT" set_network "$net_id" scan_ssid 1      >/dev/null 2>&1
    if [[ -n "$password" ]]; then
        wpa_cli -i "$IFACE_CLIENT" set_network "$net_id" psk "\"$password\"" >/dev/null 2>&1
    else
        wpa_cli -i "$IFACE_CLIENT" set_network "$net_id" key_mgmt NONE >/dev/null 2>&1
    fi
    wpa_cli -i "$IFACE_CLIENT" enable_network "$net_id" >/dev/null 2>&1
    wpa_cli -i "$IFACE_CLIENT" save_config              >/dev/null 2>&1
    wpa_cli -i "$IFACE_CLIENT" select_network "$net_id" >/dev/null 2>&1
    local i state
    for i in $(seq 1 "$CONNECT_TIMEOUT"); do
        state=$(wpa_cli -i "$IFACE_CLIENT" status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "")
        [[ "$state" == "COMPLETED" ]] && break
        sleep 1
    done
    dhcpcd "$IFACE_CLIENT" 2>/dev/null || true
    enable_nat
    local final_state
    final_state=$(wpa_cli -i "$IFACE_CLIENT" status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "?")
    log "$IFACE_CLIENT final state: $final_state"
    [[ "$final_state" == "COMPLETED" ]]
}

# =============================================================================
# Screens
# =============================================================================

select_language() {
    ui_clear
    printf '%s\n' "${C_HDR}WiFi Manager — Astroberry v${SCRIPT_VERSION}${C_RESET}"
    ui_sep
    echo "Select interface language / Choisissez la langue :"
    echo
    echo "  1) English"
    echo "  2) Français"
    echo
    local choice=""
    read -rp "  > " choice || true
    case "$choice" in
        2) UI_LANG="fr" ;;
        *) UI_LANG="en" ;;
    esac
    log "UI language set to: $UI_LANG"
}

screen_ap() {
    local status; status=$(get_ap_status)
    ui_header
    ui_title "$(tf ap_title "$IFACE_AP")"
    ui_body "$(tf ap_menu_fmt "$status" "$IFACE_AP")"
    echo
    printf '  1) %s\n' "$(t ap_enable)"
    printf '  2) %s\n' "$(t ap_disable)"
    printf '  3) %s\n' "$(t back)"
    echo
    local choice=""
    read -rp "$(t prompt_choice)" choice || true
    case "$choice" in
        1) ui_info "$(tf ap_enabling "$IFACE_AP")"
           if enable_ap; then ui_msg "$IFACE_AP" "$(t ap_enabled_ok)"
           else ui_msg "$IFACE_AP" "$(tf err_see_log_fmt "$LOG_FILE")"; fi ;;
        2) if ui_yesno "$(t ap_confirm_title)" "$(tf ap_confirm_msg "$IFACE_AP")"; then
               ui_info "$(tf ap_disabling "$IFACE_AP")"
               disable_ap
               ui_msg "$IFACE_AP" "$(t ap_disabled_msg)"
           fi ;;
        *) return 0 ;;
    esac
}

screen_client() {
    local status; status=$(get_client_status)
    ui_header
    ui_title "$(tf cl_title "$IFACE_CLIENT")"
    ui_body "$(tf cl_menu_fmt "$status")"
    echo
    printf '  1) %s\n' "$(tf cl_enable "$IFACE_CLIENT")"
    printf '  2) %s\n' "$(t cl_select)"
    printf '  3) %s\n' "$(tf cl_disable "$IFACE_CLIENT")"
    printf '  4) %s\n' "$(t back)"
    echo
    local choice=""
    read -rp "$(t prompt_choice)" choice || true
    case "$choice" in
        1) ui_info "$(tf cl_enabling "$IFACE_CLIENT")"
           if enable_client; then ui_msg "$IFACE_CLIENT" "$(t cl_enabled_ok)"
           else ui_msg "$IFACE_CLIENT" "$(tf cl_err_fmt "$LOG_FILE")"; fi ;;
        2) screen_select_network || true ;;
        3) ui_info "$(tf cl_disabling "$IFACE_CLIENT")"
           disable_client
           ui_msg "$IFACE_CLIENT" "$(t cl_disabled_ok)" ;;
        *) return 0 ;;
    esac
}

screen_select_network() {
    ui_info "$(t scan_progress)"
    local raw; raw=$(scan_networks)
    if [[ -z "$raw" ]]; then
        ui_msg "$(t scan_box)" "$(t scan_none_msg)"
        return 1
    fi
    ui_header
    ui_title "$(t scan_title)"
    ui_body "$(t scan_prompt)"
    echo
    local -a ssids=()
    local i=1 ssid signal
    while IFS='|' read -r ssid signal; do
        ssid=$(echo "$ssid" | xargs)
        [[ -z "$ssid" ]] && continue
        ssids[i]="$ssid"
        printf '  %2d) %-24s %s\n' "$i" "$ssid" "[$signal]"
        i=$((i+1))
    done <<< "$raw"
    if [[ ${#ssids[@]} -eq 0 ]]; then
        ui_msg "$(t scan_box)" "$(t scan_none2)"
        return 1
    fi
    echo
    local choice=""
    read -rp "$(t prompt_choice)" choice || true
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    local selected_ssid="${ssids[$choice]:-}"
    [[ -z "$selected_ssid" ]] && return 1

    ui_header
    ui_title "$(tf pw_title_fmt "$selected_ssid")"
    ui_body "$(t pw_prompt)"
    local password=""
    read -rs password || true
    echo

    ui_info "$(tf conn_progress_fmt "$selected_ssid")"
    if connect_network "$selected_ssid" "$password"; then
        local ip; ip=$(ip -4 addr show "$IFACE_CLIENT" 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
        ui_msg "$(t conn_ok_title)" "$(tf conn_ok_fmt "$selected_ssid" "$ip")"
    else
        ui_msg "$(t conn_fail_title)" "$(tf conn_fail_fmt "$selected_ssid" "$LOG_FILE")"
    fi
}

screen_metrics() {
    local m0_cfg m1_cfg live
    m0_cfg=$(get_configured_metric "$IFACE_AP");     m0_cfg=${m0_cfg:-"$(t met_default)"}
    m1_cfg=$(get_configured_metric "$IFACE_CLIENT"); m1_cfg=${m1_cfg:-"$(t met_default)"}
    live=$(get_live_metrics); [[ -z "$live" ]] && live="$(t met_live_none)"
    ui_header
    ui_title "$(t met_title)"
    ui_body "$(tf met_menu_fmt "$IFACE_AP" "$m0_cfg" "$IFACE_CLIENT" "$m1_cfg" "$live")"
    echo
    printf '  1) %s\n' "$(t met_opt1)"
    printf '  2) %s\n' "$(t met_opt2)"
    printf '  3) %s\n' "$(t met_opt3)"
    printf '  4) %s\n' "$(t back)"
    echo
    local choice=""
    read -rp "$(t prompt_choice)" choice || true
    case "$choice" in
        1) set_interface_metric "$IFACE_AP" "$DEFAULT_METRIC_AP"
           set_interface_metric "$IFACE_CLIENT" "$DEFAULT_METRIC_CLIENT"
           systemctl restart dhcpcd 2>/dev/null || true
           ui_msg "$(t met_box)" "$(tf met_applied_preset_fmt "$IFACE_AP" "$DEFAULT_METRIC_AP" "$IFACE_CLIENT" "$DEFAULT_METRIC_CLIENT")" ;;
        2) local new_m1="" new_m0=""
           ui_header; ui_title "$(tf met_in_cl_title "$IFACE_CLIENT")"
           read -rp "$(tf prompt_value_fmt "$DEFAULT_METRIC_CLIENT")" new_m1 || true
           new_m1=${new_m1:-$DEFAULT_METRIC_CLIENT}
           ui_header; ui_title "$(tf met_in_ap_title "$IFACE_AP")"
           read -rp "$(tf prompt_value_fmt "$DEFAULT_METRIC_AP")" new_m0 || true
           new_m0=${new_m0:-$DEFAULT_METRIC_AP}
           if ! [[ "$new_m1" =~ ^[0-9]+$ && "$new_m0" =~ ^[0-9]+$ ]]; then
               ui_msg "$(t met_box)" "$(t met_invalid)"; return 0; fi
           set_interface_metric "$IFACE_CLIENT" "$new_m1"
           set_interface_metric "$IFACE_AP" "$new_m0"
           systemctl restart dhcpcd 2>/dev/null || true
           ui_msg "$(t met_box)" "$(tf met_applied_custom_fmt "$IFACE_AP" "$new_m0" "$IFACE_CLIENT" "$new_m1")" ;;
        3) remove_managed_metric "$IFACE_AP"
           remove_managed_metric "$IFACE_CLIENT"
           systemctl restart dhcpcd 2>/dev/null || true
           log "Managed metric blocks removed"
           ui_msg "$(t met_box)" "$(t met_reset_ok)" ;;
        *) return 0 ;;
    esac
}

screen_fix_names() {
    local builtin_if usb_if builtin_mac usb_mac
    builtin_if=$(find_builtin_iface)
    usb_if=$(find_usb_iface)
    builtin_mac=$(get_iface_mac "$builtin_if")
    usb_mac=$(get_iface_mac "$usb_if")

    local detected
    detected="$(t udev_detected_hdr)"
    if [[ -n "$builtin_if" ]]; then detected+="$(tf udev_builtin_fmt "$builtin_if" "$builtin_mac")"
    else detected+="$(t udev_builtin_none)"; fi
    if [[ -n "$usb_if" ]]; then detected+="$(tf udev_usb_fmt "$usb_if" "$usb_mac")"
    else detected+="$(t udev_usb_none)"; fi

    if [[ -z "$builtin_mac" || -z "$usb_mac" ]]; then
        ui_msg "$(t udev_box)" "$(tf udev_cant_fmt "$detected")"
        return 0
    fi

    local existing; existing="$(t udev_none)"
    [[ -f "$UDEV_RULES" ]] && existing="$UDEV_RULES"

    if ui_yesno "$(t udev_title)" "$(tf udev_confirm_fmt "$detected" "$IFACE_AP" "$IFACE_CLIENT" "$existing")"; then
        write_udev_rules "$builtin_mac" "$usb_mac"
        udevadm control --reload-rules 2>/dev/null || true
        ui_msg "$(t udev_box)" "$(tf udev_written_fmt "$UDEV_RULES")"
    fi
}

screen_status() {
    local ap_st cl_st fwd nat_st ip1 gw nat_label ap_desc cl_desc live
    ap_st=$(get_ap_status)
    cl_st=$(get_client_status)
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
    nat_st=$(iptables -t nat -n -L POSTROUTING 2>/dev/null | grep -c "MASQUERADE" || echo 0)
    ip1=$(ip -4 addr show "$IFACE_CLIENT" 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
    gw=$(ip route show default dev "$IFACE_CLIENT" 2>/dev/null | awk '{print $3}' || echo "N/A")
    if [[ "$ENABLE_NAT" != "yes" ]]; then
        nat_label="$(t nat_disabled_cfg)"
    elif [[ "$nat_st" -gt 0 ]]; then
        nat_label="$(tf nat_on_fmt "$nat_st")"
    else
        nat_label="$(t nat_off)"
    fi
    ap_desc=$(describe_iface "$IFACE_AP")
    cl_desc=$(describe_iface "$IFACE_CLIENT")
    live=$(get_live_metrics); [[ -z "$live" ]] && live="$(t live_none)"

    local nl=$'\n' body=""
    body+="$(t lbl_model) : ${PI_MODEL}${nl}${nl}"
    body+="${IFACE_AP} : ${ap_desc}${nl}        ${ap_st}${nl}"
    body+="${IFACE_CLIENT} : ${cl_desc}${nl}        ${cl_st}${nl}${nl}"
    body+="  ${IFACE_CLIENT} $(t lbl_ip)   : ${ip1}${nl}"
    body+="  $(t lbl_gw)    : ${gw}${nl}"
    body+="  $(t lbl_fwd) : ${fwd}${nl}"
    body+="  $(t lbl_nat) (${IFACE_CLIENT}): ${nat_label}${nl}${nl}"
    body+="$(t lbl_routes)${nl}${live}"

    ui_header
    ui_title "$(t status_title)"
    printf '%s\n' "$body"
    ui_pause
}

main_menu() {
    while true; do
        local ap_st cl_st
        ap_st=$(get_ap_status)
        cl_st=$(get_client_status)
        ui_header
        ui_title "$(t main_title)"
        printf '  %s (AP) : %s\n' "$IFACE_AP" "$(colorize_status "$ap_st")"
        printf '  %s (Net): %s\n' "$IFACE_CLIENT" "$(colorize_status "$cl_st")"
        echo
        printf '  1) %s\n' "$(tf mi_ap "$IFACE_AP")"
        printf '  2) %s\n' "$(tf mi_client "$IFACE_CLIENT")"
        printf '  3) %s\n' "$(t mi_select)"
        printf '  4) %s\n' "$(t mi_metric)"
        printf '  5) %s\n' "$(t mi_udev)"
        printf '  6) %s\n' "$(t mi_status)"
        printf '  7) %s\n' "$(t mi_quit)"
        echo
        local choice=""
        read -rp "$(t prompt_choice)" choice || true
        case "$choice" in
            1) screen_ap            || true ;;
            2) screen_client        || true ;;
            3) screen_select_network || true ;;
            4) screen_metrics       || true ;;
            5) screen_fix_names     || true ;;
            6) screen_status        || true ;;
            7) break ;;
            *) ;;
        esac
    done
}

# =============================================================================
# Entry point
# =============================================================================

parse_args "$@"
require_root
load_config
validate_config
derive_paths
check_lock
trap cleanup EXIT
detect_pi_model

if [[ "$DEFAULT_LANG" == "ask" ]]; then
    select_language
else
    UI_LANG="$DEFAULT_LANG"
fi

log "=== wifi-manager (no-dialog) started (PID $$) — model: $PI_MODEL (gen $PI_GEN), lang: $UI_LANG, ap: $IFACE_AP, client: $IFACE_CLIENT ==="

if [[ "$PI_GEN" != "4" && "$PI_GEN" != "5" ]]; then
    ui_msg "$(t warn_model_title)" "$(tf warn_model_fmt "$PI_MODEL")"
fi

if [[ -z "$(find_usb_iface)" && ! -e "/sys/class/net/$IFACE_CLIENT" ]]; then
    ui_msg "$(t warn_nodongle_title)" "$(tf warn_nodongle_fmt "$IFACE_CLIENT")"
fi

main_menu
