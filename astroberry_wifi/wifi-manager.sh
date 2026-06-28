#!/usr/bin/env bash
# =============================================================================
# wifi-manager.sh — WiFi TUI manager for Astroberry (Raspberry Pi 4 / Pi 5)
#
# Astroberry network architecture:
#   wlan0  -> built-in interface, AP mode (hostapd + dhcpcd nohook)
#   wlan1  -> USB dongle, WiFi client for internet access (wpa_supplicant)
#
# Interface language (English / French) is chosen once at startup.
#
# Dependencies: bash, dialog, wpa_supplicant, dhcpcd, hostapd, iptables, iw
# Usage       : sudo bash wifi-manager.sh
# =============================================================================

set -euo pipefail

# --- Constants ----------------------------------------------------------------
readonly SCRIPT_VERSION="1.3"
readonly WPA_CONF_WLAN1="/etc/wpa_supplicant/wpa_supplicant-wlan1.conf"
readonly WPA_CONF_WLAN0="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
readonly DHCPCD_CONF="/etc/dhcpcd.conf"
readonly UDEV_RULES="/etc/udev/rules.d/70-persistent-wifi.rules"
readonly LOG_FILE="/var/log/wifi-manager.log"
readonly LOCK_FILE="/var/run/wifi-manager.lock"

# Default routing metrics (lower = higher priority)
readonly DEFAULT_METRIC_WLAN0="300"   # AP interface, normally no default route
readonly DEFAULT_METRIC_WLAN1="200"   # USB dongle = preferred internet path

# Colors (for messages outside dialog)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

# =============================================================================
# Internationalization (i18n)
#
# All user-facing strings live in two associative arrays (MSG_FR / MSG_EN),
# keyed by a short identifier. UI_LANG (set once at startup via the language
# picker) selects which table t()/tf() read from. Strings that embed runtime
# values are stored as printf templates with %s placeholders and rendered with
# tf(). Code comments and log messages stay in English regardless of UI_LANG.
# =============================================================================

UI_LANG="en"          # "en" or "fr"; set by select_language()
declare -A MSG_FR
declare -A MSG_EN

# Button labels (set by set_labels once the language is known)
LBL_OK="OK"; LBL_CANCEL="Cancel"; LBL_YES="Yes"; LBL_NO="No"; LBL_QUIT="Quit"

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
MSG_FR[main_header_fmt]="  wlan0 (AP) : %s\n  wlan1 (Net): %s\n"
MSG_FR[mi_wlan0]="Gérer wlan0  (Point d'accès Astroberry)"
MSG_FR[mi_wlan1]="Gérer wlan1  (Dongle WiFi internet)"
MSG_FR[mi_select]="Choisir réseau WiFi…"
MSG_FR[mi_metric]="Priorité des interfaces (metric)"
MSG_FR[mi_udev]="Fixer les noms d'interface (udev)"
MSG_FR[mi_status]="Afficher l'état du réseau"
MSG_FR[mi_quit]="Quitter"
MSG_FR[w0_title]="wlan0 — Point d'accès Astroberry"
MSG_FR[w0_menu_fmt]="État actuel : %s\n\n⚠  Désactiver wlan0 coupe l'AP et toute\nconnexion distante."
MSG_FR[w0_enable]="Activer l'AP (hostapd + dnsmasq)"
MSG_FR[w0_disable]="Désactiver l'AP  [⚠ DÉCONNEXION]"
MSG_FR[back]="Retour"
MSG_FR[w0_enabling]="  Activation de wlan0 (AP)…"
MSG_FR[w0_enabled_ok]="✓ AP Astroberry activé."
MSG_FR[err_see_log_fmt]="✗ Erreur. Voir %s"
MSG_FR[w0_confirm_title]="Confirmation"
MSG_FR[w0_confirm_msg]="Désactiver l'AP wlan0 va couper toutes\nles connexions WiFi vers Astroberry.\n\nContinuer ?"
MSG_FR[w0_disabling]="  Désactivation de wlan0…"
MSG_FR[w0_disabled_msg]="AP désactivé.\n\nReconnectez-vous via SSH/Ethernet ou écran."
MSG_FR[w1_title]="wlan1 — Dongle WiFi (accès Internet)"
MSG_FR[w1_menu_fmt]="État actuel : %s"
MSG_FR[w1_enable]="Activer le dongle wlan1"
MSG_FR[w1_select]="Choisir un réseau WiFi…"
MSG_FR[w1_disable]="Désactiver le dongle wlan1"
MSG_FR[w1_enabling]="  Activation de wlan1…"
MSG_FR[w1_enabled_ok]="✓ Dongle wlan1 activé."
MSG_FR[w1_err_fmt]="✗ Erreur. Dongle branché ? Voir %s"
MSG_FR[w1_disabling]="  Désactivation de wlan1…"
MSG_FR[w1_disabled_ok]="✓ Dongle wlan1 désactivé. NAT retiré."
MSG_FR[scan_title]="Réseaux WiFi disponibles"
MSG_FR[scan_progress]="  Scan des réseaux WiFi en cours…\n  (peut prendre ~5 secondes)"
MSG_FR[scan_prompt]="Choisissez un réseau :"
MSG_FR[scan_box]="Scan"
MSG_FR[scan_none_msg]="Aucun réseau trouvé.\n\nVérifiez que wlan1 est actif et que le dongle\nest branché."
MSG_FR[scan_none2]="Aucun réseau détecté."
MSG_FR[pw_title_fmt]="Connexion : %s"
MSG_FR[pw_prompt]="Mot de passe WiFi :\n(laisser vide si réseau ouvert)"
MSG_FR[conn_progress_fmt]="  Connexion à '%s' en cours…"
MSG_FR[conn_ok_title]="Succès"
MSG_FR[conn_ok_fmt]="✓ Connecté à : %s\n  IP obtenue  : %s\n\nLe NAT est actif — les clients AP ont accès\nà Internet."
MSG_FR[conn_fail_title]="Échec"
MSG_FR[conn_fail_fmt]="✗ Impossible de se connecter à '%s'.\n\nVérifiez le mot de passe ou la disponibilité.\nJournal : %s"
MSG_FR[met_title]="Priorité des interfaces (metric)"
MSG_FR[met_menu_fmt]="Metric configurée (dhcpcd.conf) :\n  wlan0 (AP)  : %s\n  wlan1 (Net) : %s\n\nRoutes actives (kernel) :\n%s\n\nRappel : metric basse = priorité haute.\n"
MSG_FR[met_default]="(défaut)"
MSG_FR[met_live_none]="  (aucune route par défaut active)"
MSG_FR[met_opt1]="wlan1 prioritaire pour internet (recommandé)"
MSG_FR[met_opt2]="Saisir des metrics personnalisées"
MSG_FR[met_opt3]="Réinitialiser (retirer les metrics gérées)"
MSG_FR[met_box]="Metrics"
MSG_FR[met_applied_preset_fmt]="✓ Appliqué :\n  wlan0 → metric %s\n  wlan1 → metric %s\n\nwlan1 (dongle) est maintenant la route\ninternet préférée. dhcpcd a été redémarré."
MSG_FR[met_in_w1_title]="Metric wlan1"
MSG_FR[met_in_w1_prompt]="Metric pour wlan1 (dongle internet) :\n(plus bas = prioritaire, ex: 200)"
MSG_FR[met_in_w0_title]="Metric wlan0"
MSG_FR[met_in_w0_prompt]="Metric pour wlan0 (AP) :\n(ex: 300)"
MSG_FR[met_invalid]="✗ Valeurs invalides (chiffres uniquement)."
MSG_FR[met_applied_custom_fmt]="✓ Appliqué :\n  wlan0 → metric %s\n  wlan1 → metric %s\n\ndhcpcd a été redémarré."
MSG_FR[met_reset_ok]="✓ Metrics gérées retirées de dhcpcd.conf.\nValeurs par défaut de dhcpcd restaurées."
MSG_FR[udev_title]="Fixer les noms d'interface (udev)"
MSG_FR[udev_detected_hdr]="Interfaces détectées :\n\n"
MSG_FR[udev_builtin_fmt]="  Intégrée   : %s  [%s]\n"
MSG_FR[udev_builtin_none]="  Intégrée   : NON DÉTECTÉE\n"
MSG_FR[udev_usb_fmt]="  Dongle USB : %s  [%s]\n"
MSG_FR[udev_usb_none]="  Dongle USB : NON DÉTECTÉ\n"
MSG_FR[udev_box]="Fixer les noms"
MSG_FR[udev_cant_fmt]="%s\nImpossible de continuer : les deux interfaces\n(intégrée + USB) doivent être présentes pour\ncréer une règle de nommage fiable."
MSG_FR[udev_none]="(aucune)"
MSG_FR[udev_confirm_fmt]="%s\nRègle proposée :\n  Intégrée → wlan0  (AP Astroberry)\n  Dongle USB → wlan1 (internet)\n\nRègle existante : %s\n\nÉcrire/écraser la règle udev ?"
MSG_FR[udev_written_fmt]="✓ Règle écrite dans :\n%s\n\nLes noms seront appliqués au PROCHAIN REDÉMARRAGE.\n(Un renommage à chaud n'est pas possible si\nl'interface est déjà active.)\n\nPensez à redémarrer : sudo reboot"
MSG_FR[status_title]="État du réseau"
MSG_FR[status_body_fmt]="Modèle : %s\n\nwlan0 : %s\n        %s\nwlan1 : %s\n        %s\n\n  IP wlan1   : %s\n  Passerelle : %s\n  IP forward : %s\n  NAT (wlan1): %s\n\nRoutes par défaut :\n%s"
MSG_FR[nat_off]="désactivé"
MSG_FR[nat_on_fmt]="ACTIF (%s règle(s))"
MSG_FR[live_none]="(aucune)"
MSG_FR[warn_model_title]="Modèle non validé"
MSG_FR[warn_model_fmt]="⚠  Modèle détecté :\n   %s\n\nCe script est validé pour le Raspberry Pi 4 et\nle Pi 5. La détection de la puce WiFi intégrée\npeut être imprécise sur ce matériel.\n\nLe script continue, mais vérifiez l'écran d'état."
MSG_FR[warn_nodongle_title]="Avertissement"
MSG_FR[warn_nodongle_msg]="⚠  Aucun dongle WiFi USB détecté.\n\nVérifiez qu'il est bien branché. Le script\ncontinuera mais wlan1 sera non fonctionnel."
MSG_FR[cleanup_msg]="wifi-manager fermé."
MSG_FR[summary_hdr]="Adresses MAC / IP (pour réservation DHCP) :"

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
MSG_EN[main_header_fmt]="  wlan0 (AP) : %s\n  wlan1 (Net): %s\n"
MSG_EN[mi_wlan0]="Manage wlan0  (Astroberry access point)"
MSG_EN[mi_wlan1]="Manage wlan1  (WiFi internet dongle)"
MSG_EN[mi_select]="Select WiFi network…"
MSG_EN[mi_metric]="Interface priority (metric)"
MSG_EN[mi_udev]="Pin interface names (udev)"
MSG_EN[mi_status]="Show network status"
MSG_EN[mi_quit]="Quit"
MSG_EN[w0_title]="wlan0 — Astroberry access point"
MSG_EN[w0_menu_fmt]="Current state: %s\n\n⚠  Disabling wlan0 stops the AP and all\nremote connections."
MSG_EN[w0_enable]="Enable AP (hostapd + dnsmasq)"
MSG_EN[w0_disable]="Disable AP  [⚠ DISCONNECT]"
MSG_EN[back]="Back"
MSG_EN[w0_enabling]="  Enabling wlan0 (AP)…"
MSG_EN[w0_enabled_ok]="✓ Astroberry AP enabled."
MSG_EN[err_see_log_fmt]="✗ Error. See %s"
MSG_EN[w0_confirm_title]="Confirmation"
MSG_EN[w0_confirm_msg]="Disabling the wlan0 AP will drop all\nWiFi connections to Astroberry.\n\nContinue?"
MSG_EN[w0_disabling]="  Disabling wlan0…"
MSG_EN[w0_disabled_msg]="AP disabled.\n\nReconnect via SSH/Ethernet or a screen."
MSG_EN[w1_title]="wlan1 — WiFi dongle (Internet access)"
MSG_EN[w1_menu_fmt]="Current state: %s"
MSG_EN[w1_enable]="Enable wlan1 dongle"
MSG_EN[w1_select]="Select a WiFi network…"
MSG_EN[w1_disable]="Disable wlan1 dongle"
MSG_EN[w1_enabling]="  Enabling wlan1…"
MSG_EN[w1_enabled_ok]="✓ wlan1 dongle enabled."
MSG_EN[w1_err_fmt]="✗ Error. Is the dongle plugged in? See %s"
MSG_EN[w1_disabling]="  Disabling wlan1…"
MSG_EN[w1_disabled_ok]="✓ wlan1 dongle disabled. NAT removed."
MSG_EN[scan_title]="Available WiFi networks"
MSG_EN[scan_progress]="  Scanning WiFi networks…\n  (may take ~5 seconds)"
MSG_EN[scan_prompt]="Choose a network:"
MSG_EN[scan_box]="Scan"
MSG_EN[scan_none_msg]="No network found.\n\nCheck that wlan1 is active and the dongle\nis plugged in."
MSG_EN[scan_none2]="No network detected."
MSG_EN[pw_title_fmt]="Connect: %s"
MSG_EN[pw_prompt]="WiFi password:\n(leave empty for an open network)"
MSG_EN[conn_progress_fmt]="  Connecting to '%s'…"
MSG_EN[conn_ok_title]="Success"
MSG_EN[conn_ok_fmt]="✓ Connected to: %s\n  IP obtained : %s\n\nNAT is active — AP clients now have Internet\naccess."
MSG_EN[conn_fail_title]="Failed"
MSG_EN[conn_fail_fmt]="✗ Could not connect to '%s'.\n\nCheck the password or availability.\nLog: %s"
MSG_EN[met_title]="Interface priority (metric)"
MSG_EN[met_menu_fmt]="Configured metric (dhcpcd.conf):\n  wlan0 (AP)  : %s\n  wlan1 (Net) : %s\n\nActive routes (kernel):\n%s\n\nReminder: lower metric = higher priority.\n"
MSG_EN[met_default]="(default)"
MSG_EN[met_live_none]="  (no active default route)"
MSG_EN[met_opt1]="Prioritize wlan1 for internet (recommended)"
MSG_EN[met_opt2]="Enter custom metrics"
MSG_EN[met_opt3]="Reset (remove managed metrics)"
MSG_EN[met_box]="Metrics"
MSG_EN[met_applied_preset_fmt]="✓ Applied:\n  wlan0 → metric %s\n  wlan1 → metric %s\n\nwlan1 (dongle) is now the preferred internet\nroute. dhcpcd has been restarted."
MSG_EN[met_in_w1_title]="Metric wlan1"
MSG_EN[met_in_w1_prompt]="Metric for wlan1 (internet dongle):\n(lower = higher priority, e.g. 200)"
MSG_EN[met_in_w0_title]="Metric wlan0"
MSG_EN[met_in_w0_prompt]="Metric for wlan0 (AP):\n(e.g. 300)"
MSG_EN[met_invalid]="✗ Invalid values (digits only)."
MSG_EN[met_applied_custom_fmt]="✓ Applied:\n  wlan0 → metric %s\n  wlan1 → metric %s\n\ndhcpcd has been restarted."
MSG_EN[met_reset_ok]="✓ Managed metrics removed from dhcpcd.conf.\ndhcpcd defaults restored."
MSG_EN[udev_title]="Pin interface names (udev)"
MSG_EN[udev_detected_hdr]="Detected interfaces:\n\n"
MSG_EN[udev_builtin_fmt]="  Built-in   : %s  [%s]\n"
MSG_EN[udev_builtin_none]="  Built-in   : NOT DETECTED\n"
MSG_EN[udev_usb_fmt]="  USB dongle : %s  [%s]\n"
MSG_EN[udev_usb_none]="  USB dongle : NOT DETECTED\n"
MSG_EN[udev_box]="Pin names"
MSG_EN[udev_cant_fmt]="%s\nCannot continue: both interfaces\n(built-in + USB) must be present to\ncreate a reliable naming rule."
MSG_EN[udev_none]="(none)"
MSG_EN[udev_confirm_fmt]="%s\nProposed rule:\n  Built-in → wlan0  (Astroberry AP)\n  USB dongle → wlan1 (internet)\n\nExisting rule: %s\n\nWrite/overwrite the udev rule?"
MSG_EN[udev_written_fmt]="✓ Rule written to:\n%s\n\nNames will apply on the NEXT REBOOT.\n(Live renaming is not possible while the\ninterface is already active.)\n\nRemember to reboot: sudo reboot"
MSG_EN[status_title]="Network status"
MSG_EN[status_body_fmt]="Model : %s\n\nwlan0 : %s\n        %s\nwlan1 : %s\n        %s\n\n  wlan1 IP   : %s\n  Gateway    : %s\n  IP forward : %s\n  NAT (wlan1): %s\n\nDefault routes:\n%s"
MSG_EN[nat_off]="disabled"
MSG_EN[nat_on_fmt]="ACTIVE (%s rule(s))"
MSG_EN[live_none]="(none)"
MSG_EN[warn_model_title]="Unvalidated model"
MSG_EN[warn_model_fmt]="⚠  Detected model:\n   %s\n\nThis script is validated for the Raspberry Pi 4\nand Pi 5. Built-in WiFi chip detection may be\ninaccurate on this hardware.\n\nThe script continues, but check the status screen."
MSG_EN[warn_nodongle_title]="Warning"
MSG_EN[warn_nodongle_msg]="⚠  No USB WiFi dongle detected.\n\nCheck that it is plugged in. The script will\ncontinue but wlan1 will be non-functional."
MSG_EN[cleanup_msg]="wifi-manager closed."
MSG_EN[summary_hdr]="MAC / IP addresses (for DHCP reservation):"

# Translate a key to a plain string (no placeholder substitution).
# printf '%s' keeps any literal "\n" intact so dialog converts it to a newline.
t() {
    local key="$1"
    if [[ "$UI_LANG" == "fr" ]]; then
        printf '%s' "${MSG_FR[$key]:-$key}"
    else
        printf '%s' "${MSG_EN[$key]:-${MSG_FR[$key]:-$key}}"
    fi
}

# Translate a key and substitute %s placeholders with the given arguments.
# Here printf interprets the template, turning "\n" into real newlines (which
# dialog also renders as line breaks) and filling %s in order.
tf() {
    local key="$1"; shift
    # shellcheck disable=SC2059
    printf "$(t "$key")" "$@"
}

# Set the dialog button labels for the chosen language
set_labels() {
    if [[ "$UI_LANG" == "fr" ]]; then
        LBL_OK="OK"; LBL_CANCEL="Annuler"; LBL_YES="Oui"; LBL_NO="Non"; LBL_QUIT="Quitter"
    else
        LBL_OK="OK"; LBL_CANCEL="Cancel"; LBL_YES="Yes"; LBL_NO="No"; LBL_QUIT="Quit"
    fi
}

# =============================================================================
# Utilities
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
}

# Pre-flight errors are shown bilingually because they can fire before the
# language picker has run.
die() {
    echo -e "${RED}$*${NC}" >&2
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Must be run as root (sudo). / Doit être exécuté en tant que root (sudo)."
}

require_dialog() {
    command -v dialog &>/dev/null || \
        die "'dialog' is not installed / n'est pas installé. Run: sudo apt install dialog"
}

# Print MAC and IPv4 address of both WiFi interfaces to STDOUT.
# Intended for the user to copy into their router's DHCP reservation table.
# The header is localized; the table itself stays neutral/technical.
print_iface_summary() {
    local iface mac ip
    echo ""
    echo "$(t summary_hdr)"
    printf '  %-7s  %-17s  %s\n' "Iface" "MAC" "IPv4"
    for iface in wlan0 wlan1; do
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
    rm -f "$LOCK_FILE"
    clear
    echo -e "${GREEN}$(t cleanup_msg)${NC}"
    # Emit MAC/IP of both interfaces so the user can set DHCP reservations
    print_iface_summary
}

# Ensure only one instance runs at a time
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
# Raspberry Pi model detection
#
# We read the Device Tree model string, which is the authoritative source
# (e.g. "Raspberry Pi 4 Model B Rev 1.4", "Raspberry Pi 5 Model B Rev 1.0").
# /proc/cpuinfo "Model" is used as a fallback. The detected generation
# (PI_GEN = "4", "5", "other", or "unknown") drives built-in WiFi bus
# detection, since the on-board chip is wired to a different bus on the Pi 5.
# =============================================================================

PI_MODEL="unknown"     # full model string
PI_GEN="unknown"       # "4", "5", "other", or "unknown"

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
#
# USB dongles always sit on the USB bus on every Pi, so a "/usb" segment in the
# /sys device path reliably means "dongle". For the built-in chip the bus
# differs by model:
#   Pi 4 -> SDIO/mmc bus  (path contains "mmc"/"sdio")
#   Pi 5 -> platform bus  (path contains neither mmc nor sdio)
# To stay robust across both, we use the rule "not USB but wired to the board
# => built-in", since a Pi has exactly one soldered WiFi chip. The mmc/sdio
# check is kept only as an explicit, logged confirmation for the Pi 4.
# =============================================================================

# Return the bus type of an interface: "usb", "builtin", "absent", or "unknown"
get_iface_bus() {
    local iface="$1"
    local devpath
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

# Return MAC address of an interface
get_iface_mac() {
    local iface="$1"
    cat "/sys/class/net/$iface/address" 2>/dev/null || echo ""
}

# Localized, human-readable label describing what an interface physically is
describe_iface() {
    local iface="$1"
    local bus mac
    bus=$(get_iface_bus "$iface")
    mac=$(get_iface_mac "$iface")
    case "$bus" in
        usb)     tf if_usb_fmt "$mac" ;;
        builtin) tf if_builtin_fmt "$mac" ;;
        absent)  t if_absent ;;
        *)       tf if_unknown_fmt "$mac" ;;
    esac
}

# Find the interface name currently bound to the built-in chip (or empty)
find_builtin_iface() {
    local i
    for i in /sys/class/net/wlan*; do
        [[ -e "$i" ]] || continue
        local name; name=$(basename "$i")
        [[ "$(get_iface_bus "$name")" == "builtin" ]] && { echo "$name"; return; }
    done
    echo ""
}

# Find the interface name currently bound to a USB dongle (or empty)
find_usb_iface() {
    local i
    for i in /sys/class/net/wlan*; do
        [[ -e "$i" ]] || continue
        local name; name=$(basename "$i")
        [[ "$(get_iface_bus "$name")" == "usb" ]] && { echo "$name"; return; }
    done
    echo ""
}

# =============================================================================
# Network functions — wlan0 (Astroberry AP)
# =============================================================================

get_wlan0_status() {
    if systemctl is-active --quiet hostapd 2>/dev/null; then
        t st_ap_active
    elif ip link show wlan0 &>/dev/null; then
        cat /sys/class/net/wlan0/operstate 2>/dev/null || t st_unknown
    else
        t st_absent
    fi
}

enable_wlan0_ap() {
    log "Enabling wlan0 (AP / hostapd)"
    ip link set wlan0 up 2>/dev/null || true
    systemctl start hostapd  && log "hostapd started"
    systemctl start dnsmasq  2>/dev/null && log "dnsmasq started" || true
    systemctl restart dhcpcd && log "dhcpcd restarted"
    return 0
}

disable_wlan0_ap() {
    # WARNING: this kills the Astroberry AP -> clients lose their connection!
    log "Disabling wlan0 (AP / hostapd)"
    systemctl stop hostapd  && log "hostapd stopped"
    systemctl stop dnsmasq  2>/dev/null && log "dnsmasq stopped" || true
    ip link set wlan0 down  2>/dev/null && log "wlan0 down" || true
    return 0
}

# =============================================================================
# Network functions — wlan1 (dongle, WiFi client)
# =============================================================================

get_wlan1_status() {
    if ! ip link show wlan1 &>/dev/null; then
        t st_absent
        return
    fi
    local state
    state=$(cat /sys/class/net/wlan1/operstate 2>/dev/null || echo "unknown")

    if [[ "$state" == "up" ]]; then
        local wpa_state
        wpa_state=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "N/A")
        if [[ "$wpa_state" == "COMPLETED" ]]; then
            local ssid ip
            ssid=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^ssid=' | cut -d= -f2 || echo "?")
            ip=$(ip -4 addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
            tf st_connected_fmt "$ssid" "$ip"
        else
            tf st_active_notconn_fmt "$wpa_state"
        fi
    else
        tf st_inactive_fmt "$state"
    fi
}

# Create/initialize the wpa_supplicant file for wlan1 if missing
init_wpa_conf_wlan1() {
    if [[ ! -f "$WPA_CONF_WLAN1" ]]; then
        log "Creating $WPA_CONF_WLAN1"
        cat > "$WPA_CONF_WLAN1" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=CA

EOF
        chmod 600 "$WPA_CONF_WLAN1"
    fi
}

# Start wpa_supplicant on wlan1 only (never touches wlan0)
enable_wlan1() {
    log "Enabling wlan1 dongle"
    init_wpa_conf_wlan1

    ip link set wlan1 up 2>/dev/null || { log "Cannot bring up wlan1"; return 1; }

    # Kill any existing wpa_supplicant instance bound to wlan1
    pkill -f "wpa_supplicant.*wlan1" 2>/dev/null || true
    sleep 0.5

    # Launch wpa_supplicant in background for wlan1 ONLY
    wpa_supplicant -B -Dnl80211,wext \
        -i wlan1 \
        -c "$WPA_CONF_WLAN1" \
        -P /var/run/wpa_supplicant_wlan1.pid \
        && log "wpa_supplicant started on wlan1" \
        || { log "wpa_supplicant failed on wlan1"; return 1; }

    # Request an IP via dhcpcd on wlan1
    dhcpcd wlan1 2>/dev/null && log "dhcpcd on wlan1 OK" || true

    enable_nat
    return 0
}

disable_wlan1() {
    log "Disabling wlan1 dongle"

    dhcpcd -k wlan1 2>/dev/null && log "dhcpcd wlan1 released" || true

    if [[ -f /var/run/wpa_supplicant_wlan1.pid ]]; then
        kill "$(cat /var/run/wpa_supplicant_wlan1.pid)" 2>/dev/null || true
        rm -f /var/run/wpa_supplicant_wlan1.pid
    fi
    pkill -f "wpa_supplicant.*wlan1" 2>/dev/null || true

    ip link set wlan1 down 2>/dev/null && log "wlan1 down" || true

    disable_nat
    return 0
}

# =============================================================================
# NAT: internet sharing wlan1 -> wlan0 (AP clients)
# =============================================================================

enable_nat() {
    log "Enabling NAT wlan1 -> wlan0"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
    iptables -t nat -C POSTROUTING -o wlan1 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
    iptables -C FORWARD -i wlan1 -o wlan0 -m state \
        --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i wlan1 -o wlan0 -m state \
           --state RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -i wlan0 -o wlan1 -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT
    log "NAT enabled"
}

disable_nat() {
    log "Disabling NAT"
    iptables -t nat -D POSTROUTING -o wlan1 -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i wlan1 -o wlan0 -m state \
        --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i wlan0 -o wlan1 -j ACCEPT 2>/dev/null || true
    echo 0 > /proc/sys/net/ipv4/ip_forward
    log "NAT disabled"
}

# =============================================================================
# Routing metric management
#
# dhcpcd assigns a "metric" to each interface's default route. The lower the
# metric, the higher the priority. We want the USB dongle (wlan1) to win as the
# internet path, so it gets a lower metric than wlan0. Metrics are written as
# per-interface stanzas in dhcpcd.conf and applied on the next dhcpcd cycle.
# =============================================================================

# Read the currently configured metric for an interface from dhcpcd.conf (or "")
get_configured_metric() {
    local iface="$1"
    awk -v ifc="$iface" '
        $1=="interface" && $2==ifc { found=1; next }
        found && $1=="interface" { found=0 }
        found && $1=="metric" { print $2; exit }
    ' "$DHCPCD_CONF" 2>/dev/null || echo ""
}

# Show the live metrics currently applied in the kernel routing table
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

# Set (or replace) the metric stanza for an interface in dhcpcd.conf
set_interface_metric() {
    local iface="$1"
    local metric="$2"
    log "Setting metric $metric for $iface in $DHCPCD_CONF"

    # Backup once per run
    [[ -f "${DHCPCD_CONF}.wifimgr.bak" ]] || cp "$DHCPCD_CONF" "${DHCPCD_CONF}.wifimgr.bak"

    # Managed blocks are delimited by markers so we never clobber user content.
    local marker_start="# >>> wifi-manager metric: ${iface} >>>"
    local marker_end="# <<< wifi-manager metric: ${iface} <<<"

    # Strip previous managed block (if any) using sed range delete
    sed -i "/${marker_start}/,/${marker_end}/d" "$DHCPCD_CONF"

    # Append the new managed block
    {
        echo ""
        echo "$marker_start"
        echo "interface ${iface}"
        echo "metric ${metric}"
        echo "$marker_end"
    } >> "$DHCPCD_CONF"

    log "Metric block written for $iface"
}

# =============================================================================
# Persistent interface naming (udev rules by MAC)
#
# Risk addressed: if the USB dongle is plugged in at boot, the kernel may name
# it wlan0 and the built-in chip wlan1 — swapping the AP and client roles. We
# pin names to MAC addresses with a udev rule so the built-in chip is ALWAYS
# wlan0 (AP) and the dongle is ALWAYS wlan1 (client), regardless of boot timing.
# =============================================================================

# Write the udev rule pinning builtin->wlan0 and usb->wlan1
write_udev_rules() {
    local builtin_mac="$1"
    local usb_mac="$2"

    log "Writing udev naming rules (builtin=$builtin_mac usb=$usb_mac)"
    cat > "$UDEV_RULES" <<EOF
# Generated by wifi-manager.sh — persistent WiFi interface names
# Built-in Pi WiFi chip -> wlan0 (Astroberry AP)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${builtin_mac}", NAME="wlan0"
# USB WiFi dongle -> wlan1 (internet client)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${usb_mac}", NAME="wlan1"
EOF
    chmod 644 "$UDEV_RULES"
    log "udev rules written to $UDEV_RULES"
}

# =============================================================================
# TUI — dialog screens
# =============================================================================

# Run model detection so PI_GEN/PI_MODEL are available for the (neutral) backtitle
detect_pi_model

BACKTITLE="WiFi Manager — Astroberry v${SCRIPT_VERSION} — Pi ${PI_GEN}"

msg_box() {
    dialog --backtitle "$BACKTITLE" --title "$1" --ok-label "$LBL_OK" \
           --msgbox "$2" 12 64
}

info_box() {
    dialog --backtitle "$BACKTITLE" --infobox "$1" 5 50
}

# ---- Screen: language selection (startup only) ------------------------------
select_language() {
    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "Language / Langue" \
                    --no-cancel \
                    --menu "Select interface language / Choisissez la langue :" \
                    11 50 2 \
                    "en" "English" \
                    "fr" "Français" \
                    3>&1 1>&2 2>&3) || choice="en"
    UI_LANG="$choice"
    set_labels
    log "UI language set to: $UI_LANG"
}

# ---- Screen: persistent interface naming (udev) -----------------------------
screen_fix_names() {
    local builtin_if usb_if builtin_mac usb_mac
    builtin_if=$(find_builtin_iface)
    usb_if=$(find_usb_iface)
    builtin_mac=$(get_iface_mac "$builtin_if")
    usb_mac=$(get_iface_mac "$usb_if")

    local detected
    detected="$(t udev_detected_hdr)"
    if [[ -n "$builtin_if" ]]; then
        detected+="$(tf udev_builtin_fmt "$builtin_if" "$builtin_mac")"
    else
        detected+="$(t udev_builtin_none)"
    fi
    if [[ -n "$usb_if" ]]; then
        detected+="$(tf udev_usb_fmt "$usb_if" "$usb_mac")"
    else
        detected+="$(t udev_usb_none)"
    fi

    if [[ -z "$builtin_mac" || -z "$usb_mac" ]]; then
        msg_box "$(t udev_box)" "$(tf udev_cant_fmt "$detected")"
        return
    fi

    local existing
    existing="$(t udev_none)"
    [[ -f "$UDEV_RULES" ]] && existing="$UDEV_RULES"

    dialog --backtitle "$BACKTITLE" \
           --title "$(t udev_title)" \
           --yes-label "$LBL_YES" --no-label "$LBL_NO" \
           --yesno "$(tf udev_confirm_fmt "$detected" "$existing")" \
           20 66 || return

    write_udev_rules "$builtin_mac" "$usb_mac"
    udevadm control --reload-rules 2>/dev/null || true

    msg_box "$(t udev_box)" "$(tf udev_written_fmt "$UDEV_RULES")"
}

# ---- Screen: routing metric management --------------------------------------
screen_metrics() {
    local m0_cfg m1_cfg
    m0_cfg=$(get_configured_metric "wlan0"); m0_cfg=${m0_cfg:-"$(t met_default)"}
    m1_cfg=$(get_configured_metric "wlan1"); m1_cfg=${m1_cfg:-"$(t met_default)"}

    local live
    live=$(get_live_metrics)
    [[ -z "$live" ]] && live="$(t met_live_none)"

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "$(t met_title)" \
                    --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                    --menu "$(tf met_menu_fmt "$m0_cfg" "$m1_cfg" "$live")" \
                    20 66 4 \
                    "1" "$(t met_opt1)" \
                    "2" "$(t met_opt2)" \
                    "3" "$(t met_opt3)" \
                    "4" "$(t back)" \
                    3>&1 1>&2 2>&3) || return

    case "$choice" in
        1)
            set_interface_metric "wlan0" "$DEFAULT_METRIC_WLAN0"
            set_interface_metric "wlan1" "$DEFAULT_METRIC_WLAN1"
            systemctl restart dhcpcd 2>/dev/null || true
            msg_box "$(t met_box)" "$(tf met_applied_preset_fmt "$DEFAULT_METRIC_WLAN0" "$DEFAULT_METRIC_WLAN1")"
            ;;
        2)
            local new_m1 new_m0
            new_m1=$(dialog --backtitle "$BACKTITLE" --title "$(t met_in_w1_title)" \
                     --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                     --inputbox "$(t met_in_w1_prompt)" \
                     10 50 "$DEFAULT_METRIC_WLAN1" 3>&1 1>&2 2>&3) || return
            new_m0=$(dialog --backtitle "$BACKTITLE" --title "$(t met_in_w0_title)" \
                     --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                     --inputbox "$(t met_in_w0_prompt)" \
                     10 50 "$DEFAULT_METRIC_WLAN0" 3>&1 1>&2 2>&3) || return

            if ! [[ "$new_m1" =~ ^[0-9]+$ && "$new_m0" =~ ^[0-9]+$ ]]; then
                msg_box "$(t met_box)" "$(t met_invalid)"
                return
            fi
            set_interface_metric "wlan1" "$new_m1"
            set_interface_metric "wlan0" "$new_m0"
            systemctl restart dhcpcd 2>/dev/null || true
            msg_box "$(t met_box)" "$(tf met_applied_custom_fmt "$new_m0" "$new_m1")"
            ;;
        3)
            sed -i "/# >>> wifi-manager metric: wlan0 >>>/,/# <<< wifi-manager metric: wlan0 <<</d" "$DHCPCD_CONF"
            sed -i "/# >>> wifi-manager metric: wlan1 >>>/,/# <<< wifi-manager metric: wlan1 <<</d" "$DHCPCD_CONF"
            systemctl restart dhcpcd 2>/dev/null || true
            log "Managed metric blocks removed"
            msg_box "$(t met_box)" "$(t met_reset_ok)"
            ;;
        4) return ;;
    esac
}

# ---- WiFi scan --------------------------------------------------------------
scan_networks() {
    log "Scanning WiFi networks on wlan1"
    ip link set wlan1 up 2>/dev/null || true
    sleep 1

    local results=""
    if command -v iw &>/dev/null; then
        results=$(iw dev wlan1 scan 2>/dev/null \
            | awk '
                /^BSS [0-9a-f:]{17}/ { signal="?"; ssid="" }
                /signal:/ { signal=$2" "$3 }
                /SSID:/ && $2!="" { ssid=substr($0, index($0,$2)); print ssid "|" signal }
            ' \
            | sort -t'|' -k2 -rn | head -20 || true)
    fi

    if [[ -z "$results" ]]; then
        wpa_cli -i wlan1 scan 2>/dev/null || true
        sleep 2
        results=$(wpa_cli -i wlan1 scan_results 2>/dev/null \
            | tail -n +2 \
            | awk '{ ssid=""; for(i=5;i<=NF;i++) ssid=ssid (i>5?" ":"") $i;
                     if(ssid!="") print ssid "|" $3 " dBm" }' \
            | head -20 || true)
    fi
    echo "$results"
}

connect_network() {
    local ssid="$1"
    local password="$2"

    log "Connecting to network: $ssid"
    init_wpa_conf_wlan1

    if ! pgrep -f "wpa_supplicant.*wlan1" &>/dev/null; then
        enable_wlan1
        sleep 1
    fi

    local net_id
    net_id=$(wpa_cli -i wlan1 add_network 2>/dev/null | tail -1)
    if [[ -z "$net_id" || "$net_id" == "FAIL" ]]; then
        enable_wlan1
        sleep 2
        net_id=$(wpa_cli -i wlan1 add_network 2>/dev/null | tail -1)
    fi
    [[ "$net_id" =~ ^[0-9]+$ ]] || { log "Cannot add network"; return 1; }

    wpa_cli -i wlan1 set_network "$net_id" ssid "\"$ssid\"" >/dev/null 2>&1
    wpa_cli -i wlan1 set_network "$net_id" scan_ssid 1      >/dev/null 2>&1
    if [[ -n "$password" ]]; then
        wpa_cli -i wlan1 set_network "$net_id" psk "\"$password\"" >/dev/null 2>&1
    else
        wpa_cli -i wlan1 set_network "$net_id" key_mgmt NONE >/dev/null 2>&1
    fi
    wpa_cli -i wlan1 enable_network "$net_id" >/dev/null 2>&1
    wpa_cli -i wlan1 save_config              >/dev/null 2>&1
    wpa_cli -i wlan1 select_network "$net_id" >/dev/null 2>&1

    local i
    for i in $(seq 1 15); do
        local state
        state=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "")
        [[ "$state" == "COMPLETED" ]] && break
        sleep 1
    done

    dhcpcd wlan1 2>/dev/null || true
    enable_nat

    local final_state
    final_state=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "?")
    log "wlan1 final state: $final_state"
    [[ "$final_state" == "COMPLETED" ]]
}

screen_select_network() {
    info_box "$(t scan_progress)"
    local raw
    raw=$(scan_networks)

    if [[ -z "$raw" ]]; then
        msg_box "$(t scan_box)" "$(t scan_none_msg)"
        return 1
    fi

    local menu_items=()
    local i=1
    declare -A ssid_map
    while IFS='|' read -r ssid signal; do
        ssid=$(echo "$ssid" | xargs)
        [[ -z "$ssid" ]] && continue
        menu_items+=("$i" "${ssid}  [${signal}]")
        ssid_map[$i]="$ssid"
        ((i++))
    done <<< "$raw"

    [[ ${#menu_items[@]} -eq 0 ]] && { msg_box "$(t scan_box)" "$(t scan_none2)"; return 1; }

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "$(t scan_title)" \
                    --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                    --menu "$(t scan_prompt)" 20 65 12 \
                    "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

    local selected_ssid="${ssid_map[$choice]}"
    [[ -z "$selected_ssid" ]] && return 1

    local password
    password=$(dialog --backtitle "$BACKTITLE" \
                      --title "$(tf pw_title_fmt "$selected_ssid")" --insecure \
                      --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                      --passwordbox "$(t pw_prompt)" \
                      10 55 3>&1 1>&2 2>&3) || return 1

    info_box "$(tf conn_progress_fmt "$selected_ssid")"
    if connect_network "$selected_ssid" "$password"; then
        local ip; ip=$(ip -4 addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
        msg_box "$(t conn_ok_title)" "$(tf conn_ok_fmt "$selected_ssid" "$ip")"
    else
        msg_box "$(t conn_fail_title)" "$(tf conn_fail_fmt "$selected_ssid" "$LOG_FILE")"
    fi
}

# ---- Screen: wlan0 management (AP) ------------------------------------------
screen_wlan0() {
    local status; status=$(get_wlan0_status)
    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "$(t w0_title)" \
                    --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                    --menu "$(tf w0_menu_fmt "$status")" \
                    14 65 3 \
                    "1" "$(t w0_enable)" \
                    "2" "$(t w0_disable)" \
                    "3" "$(t back)" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) info_box "$(t w0_enabling)"
           enable_wlan0_ap && msg_box "wlan0" "$(t w0_enabled_ok)" \
                           || msg_box "wlan0" "$(tf err_see_log_fmt "$LOG_FILE")" ;;
        2) dialog --backtitle "$BACKTITLE" --title "$(t w0_confirm_title)" \
               --yes-label "$LBL_YES" --no-label "$LBL_NO" \
               --yesno "$(t w0_confirm_msg)" 10 55 || return
           info_box "$(t w0_disabling)"
           disable_wlan0_ap
           msg_box "wlan0" "$(t w0_disabled_msg)" ;;
        3) return ;;
    esac
}

# ---- Screen: wlan1 management (dongle) --------------------------------------
screen_wlan1() {
    local status; status=$(get_wlan1_status)
    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "$(t w1_title)" \
                    --ok-label "$LBL_OK" --cancel-label "$LBL_CANCEL" \
                    --menu "$(tf w1_menu_fmt "$status")" \
                    14 65 4 \
                    "1" "$(t w1_enable)" \
                    "2" "$(t w1_select)" \
                    "3" "$(t w1_disable)" \
                    "4" "$(t back)" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) info_box "$(t w1_enabling)"
           enable_wlan1 && msg_box "wlan1" "$(t w1_enabled_ok)" \
                        || msg_box "wlan1" "$(tf w1_err_fmt "$LOG_FILE")" ;;
        2) screen_select_network ;;
        3) info_box "$(t w1_disabling)"
           disable_wlan1
           msg_box "wlan1" "$(t w1_disabled_ok)" ;;
        4) return ;;
    esac
}

# ---- Screen: network status -------------------------------------------------
screen_status() {
    local wlan0_st wlan1_st fwd nat_st ip1 gw
    wlan0_st=$(get_wlan0_status)
    wlan1_st=$(get_wlan1_status)
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
    nat_st=$(iptables -t nat -n -L POSTROUTING 2>/dev/null | grep -c "MASQUERADE" || echo 0)
    ip1=$(ip -4 addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
    gw=$(ip route show default dev wlan1 2>/dev/null | awk '{print $3}' || echo "N/A")

    local nat_label
    if [[ "$nat_st" -gt 0 ]]; then
        nat_label="$(tf nat_on_fmt "$nat_st")"
    else
        nat_label="$(t nat_off)"
    fi

    local w0_desc w1_desc
    w0_desc=$(describe_iface "wlan0")
    w1_desc=$(describe_iface "wlan1")

    local live; live=$(get_live_metrics); [[ -z "$live" ]] && live="$(t live_none)"

    msg_box "$(t status_title)" \
        "$(tf status_body_fmt "$PI_MODEL" "$w0_desc" "$wlan0_st" "$w1_desc" "$wlan1_st" "$ip1" "$gw" "$fwd" "$nat_label" "$live")"
}

# ---- Main menu --------------------------------------------------------------
main_menu() {
    while true; do
        local w0_st w1_st
        w0_st=$(get_wlan0_status)
        w1_st=$(get_wlan1_status)

        local choice
        choice=$(dialog --backtitle "$BACKTITLE" \
                        --title "$(t main_title)" \
                        --ok-label "$LBL_OK" --cancel-label "$LBL_QUIT" \
                        --menu "$(tf main_header_fmt "$w0_st" "$w1_st")" \
                        18 66 7 \
                        "1" "$(t mi_wlan0)" \
                        "2" "$(t mi_wlan1)" \
                        "3" "$(t mi_select)" \
                        "4" "$(t mi_metric)" \
                        "5" "$(t mi_udev)" \
                        "6" "$(t mi_status)" \
                        "7" "$(t mi_quit)" \
                        3>&1 1>&2 2>&3) || break

        case "$choice" in
            1) screen_wlan0 ;;
            2) screen_wlan1 ;;
            3) screen_select_network ;;
            4) screen_metrics ;;
            5) screen_fix_names ;;
            6) screen_status ;;
            7) break ;;
        esac
    done
}

# =============================================================================
# Entry point
# =============================================================================

require_root
require_dialog
check_lock
trap cleanup EXIT

# Language picker first, so every subsequent screen is localized
select_language

log "=== wifi-manager started (PID $$) — model: $PI_MODEL (gen $PI_GEN), lang: $UI_LANG ==="

# Warn if running on a Pi generation this script was not validated against
if [[ "$PI_GEN" != "4" && "$PI_GEN" != "5" ]]; then
    dialog --backtitle "$BACKTITLE" --title "$(t warn_model_title)" \
           --ok-label "$LBL_OK" \
           --msgbox "$(tf warn_model_fmt "$PI_MODEL")" 12 64 || true
fi

# Warn if the USB dongle interface is missing
if [[ -z "$(find_usb_iface)" ]]; then
    dialog --backtitle "$BACKTITLE" --title "$(t warn_nodongle_title)" \
           --ok-label "$LBL_OK" \
           --msgbox "$(t warn_nodongle_msg)" 10 62 || true
fi

main_menu