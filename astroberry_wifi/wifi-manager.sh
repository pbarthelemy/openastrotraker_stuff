#!/usr/bin/env bash
# =============================================================================
# wifi-manager.sh — WiFi TUI manager for Astroberry (Raspberry Pi 4)
#
# Astroberry network architecture:
#   wlan0  -> built-in interface, AP mode (hostapd + dhcpcd nohook)
#   wlan1  -> USB dongle, WiFi client for internet access (wpa_supplicant)
#
# Dependencies: bash, dialog, wpa_supplicant, dhcpcd, hostapd, iptables, iw
# Usage       : sudo bash wifi-manager.sh
# =============================================================================

set -euo pipefail

# --- Constants ----------------------------------------------------------------
readonly SCRIPT_VERSION="1.2"
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
# Utilities
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
}

die() {
    echo -e "${RED}ERREUR: $*${NC}" >&2
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en tant que root (sudo)."
}

require_dialog() {
    command -v dialog &>/dev/null || die "'dialog' n'est pas installé. Lancez : sudo apt install dialog"
}

cleanup() {
    rm -f "$LOCK_FILE"
    clear
    echo -e "${GREEN}wifi-manager fermé.${NC}"
}

# Ensure only one instance runs at a time
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        kill -0 "$pid" 2>/dev/null && die "Une instance est déjà en cours (PID $pid)."
    fi
    echo $$ > "$LOCK_FILE"
}

# =============================================================================
# Raspberry Pi model detection
#
# We read the Device Tree model string, which is the authoritative source
# (e.g. "Raspberry Pi 4 Model B Rev 1.4", "Raspberry Pi 5 Model B Rev 1.0").
# /proc/cpuinfo "Revision" is used as a fallback. The detected generation
# (PI_GEN = "4", "5", or "unknown") drives built-in WiFi bus detection, since
# the on-board chip is wired to a different bus on the Pi 5 than on the Pi 4.
# =============================================================================

PI_MODEL="inconnu"     # full model string
PI_GEN="unknown"       # "4", "5", or "unknown"

detect_pi_model() {
    local model=""
    # Device Tree model string (NUL-terminated, hence the tr)
    if [[ -r /proc/device-tree/model ]]; then
        model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    fi
    # Fallback to cpuinfo if device-tree is unavailable
    if [[ -z "$model" && -r /proc/cpuinfo ]]; then
        model=$(grep -m1 -i '^Model' /proc/cpuinfo | cut -d: -f2- | xargs || echo "")
    fi

    PI_MODEL="${model:-inconnu}"

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

# Return the bus type of an interface: "usb", "builtin", or "unknown"
get_iface_bus() {
    local iface="$1"
    local devpath
    [[ -e "/sys/class/net/$iface" ]] || { echo "absent"; return; }
    devpath=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")

    if [[ "$devpath" == *"/usb"* ]]; then
        echo "usb"
    elif [[ "$devpath" == *"mmc"* || "$devpath" == *"sdio"* ]]; then
        # Classic Pi 4 path (SDIO-attached Cypress chip)
        echo "builtin"
    elif [[ -n "$devpath" ]]; then
        # Wired to the board but not on USB: built-in chip on the Pi 5
        # (platform bus) or any other non-USB on-board adapter.
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

# Human-readable label describing what an interface physically is
describe_iface() {
    local iface="$1"
    local bus mac
    bus=$(get_iface_bus "$iface")
    mac=$(get_iface_mac "$iface")
    case "$bus" in
        usb)     echo "Dongle USB  (MAC $mac)" ;;
        builtin) echo "Intégrée    (MAC $mac)" ;;
        absent)  echo "(absente)" ;;
        *)       echo "Inconnue    (MAC $mac)" ;;
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
        echo "AP actif"
    elif ip link show wlan0 &>/dev/null; then
        cat /sys/class/net/wlan0/operstate 2>/dev/null || echo "inconnu"
    else
        echo "absent"
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
        echo "absent"
        return
    fi
    local state
    state=$(cat /sys/class/net/wlan1/operstate 2>/dev/null || echo "inconnu")

    if [[ "$state" == "up" ]]; then
        local wpa_state
        wpa_state=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2 || echo "N/A")
        if [[ "$wpa_state" == "COMPLETED" ]]; then
            local ssid ip
            ssid=$(wpa_cli -i wlan1 status 2>/dev/null | grep '^ssid=' | cut -d= -f2 || echo "?")
            ip=$(ip -4 addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
            echo "Connecté -> $ssid ($ip)"
        else
            echo "Actif (non connecté — état: $wpa_state)"
        fi
    else
        echo "inactif ($state)"
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

    # Remove any existing managed block for this interface, then append a fresh one.
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
# Built-in Pi 4 WiFi chip -> wlan0 (Astroberry AP)
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

# Detect the Pi model now so PI_GEN/PI_MODEL are available for BACKTITLE below
detect_pi_model

BACKTITLE="WiFi Manager — Astroberry v${SCRIPT_VERSION} — Pi ${PI_GEN}"

msg_box() {
    dialog --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 64
}

info_box() {
    dialog --backtitle "$BACKTITLE" --infobox "$1" 5 50
}

# ---- Screen: persistent interface naming (udev) -----------------------------
screen_fix_names() {
    local builtin_if usb_if builtin_mac usb_mac
    builtin_if=$(find_builtin_iface)
    usb_if=$(find_usb_iface)
    builtin_mac=$(get_iface_mac "$builtin_if")
    usb_mac=$(get_iface_mac "$usb_if")

    # Build a description of what we detected
    local detected="Interfaces détectées :\n\n"
    if [[ -n "$builtin_if" ]]; then
        detected+="  Intégrée (Pi 4) : ${builtin_if}  [${builtin_mac}]\n"
    else
        detected+="  Intégrée (Pi 4) : NON DÉTECTÉE\n"
    fi
    if [[ -n "$usb_if" ]]; then
        detected+="  Dongle USB      : ${usb_if}  [${usb_mac}]\n"
    else
        detected+="  Dongle USB      : NON DÉTECTÉ\n"
    fi

    if [[ -z "$builtin_mac" || -z "$usb_mac" ]]; then
        msg_box "Fixer les noms" "${detected}\nImpossible de continuer : les deux interfaces\n(intégrée + USB) doivent être présentes pour\ncréer une règle de nommage fiable."
        return
    fi

    local existing="(aucune)"
    [[ -f "$UDEV_RULES" ]] && existing="$UDEV_RULES"

    dialog --backtitle "$BACKTITLE" \
           --title "Fixer les noms d'interface (udev)" \
           --yesno "${detected}\nRègle proposée :\n  Intégrée -> wlan0  (AP Astroberry)\n  Dongle USB -> wlan1 (internet)\n\nRègle existante : ${existing}\n\nÉcrire/écraser la règle udev ?" \
           20 66 || return

    write_udev_rules "$builtin_mac" "$usb_mac"
    udevadm control --reload-rules 2>/dev/null || true

    msg_box "Fixer les noms" "✓ Règle écrite dans :\n${UDEV_RULES}\n\nLes noms seront appliqués au PROCHAIN REDÉMARRAGE.\n(Un renommage à chaud n'est pas possible si\nl'interface est déjà active.)\n\nPensez à redémarrer : sudo reboot"
}

# ---- Screen: routing metric management --------------------------------------
screen_metrics() {
    local m0_cfg m1_cfg
    m0_cfg=$(get_configured_metric "wlan0"); m0_cfg=${m0_cfg:-"(défaut)"}
    m1_cfg=$(get_configured_metric "wlan1"); m1_cfg=${m1_cfg:-"(défaut)"}

    local live
    live=$(get_live_metrics)
    [[ -z "$live" ]] && live="  (aucune route par défaut active)"

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "Priorité des interfaces (metric)" \
                    --menu "\
Metric configurée (dhcpcd.conf) :
  wlan0 (AP)  : $m0_cfg
  wlan1 (Net) : $m1_cfg

Routes actives (kernel) :
$live

Rappel : metric basse = priorité haute.
" \
                    20 66 4 \
                    "1" "wlan1 prioritaire pour internet (recommandé)" \
                    "2" "Saisir des metrics personnalisées" \
                    "3" "Réinitialiser (retirer les metrics gérées)" \
                    "4" "Retour" \
                    3>&1 1>&2 2>&3) || return

    case "$choice" in
        1)
            set_interface_metric "wlan0" "$DEFAULT_METRIC_WLAN0"
            set_interface_metric "wlan1" "$DEFAULT_METRIC_WLAN1"
            systemctl restart dhcpcd 2>/dev/null || true
            msg_box "Metrics" "✓ Appliqué :\n  wlan0 -> metric ${DEFAULT_METRIC_WLAN0}\n  wlan1 -> metric ${DEFAULT_METRIC_WLAN1}\n\nwlan1 (dongle) est maintenant la route\ninternet préférée. dhcpcd a été redémarré."
            ;;
        2)
            local new_m1 new_m0
            new_m1=$(dialog --backtitle "$BACKTITLE" --title "Metric wlan1" \
                     --inputbox "Metric pour wlan1 (dongle internet) :\n(plus bas = prioritaire, ex: 200)" \
                     10 50 "$DEFAULT_METRIC_WLAN1" 3>&1 1>&2 2>&3) || return
            new_m0=$(dialog --backtitle "$BACKTITLE" --title "Metric wlan0" \
                     --inputbox "Metric pour wlan0 (AP) :\n(ex: 300)" \
                     10 50 "$DEFAULT_METRIC_WLAN0" 3>&1 1>&2 2>&3) || return

            # Validate numeric input
            if ! [[ "$new_m1" =~ ^[0-9]+$ && "$new_m0" =~ ^[0-9]+$ ]]; then
                msg_box "Metrics" "✗ Valeurs invalides (chiffres uniquement)."
                return
            fi
            set_interface_metric "wlan1" "$new_m1"
            set_interface_metric "wlan0" "$new_m0"
            systemctl restart dhcpcd 2>/dev/null || true
            msg_box "Metrics" "✓ Appliqué :\n  wlan0 -> metric ${new_m0}\n  wlan1 -> metric ${new_m1}\n\ndhcpcd a été redémarré."
            ;;
        3)
            # Remove managed metric blocks from dhcpcd.conf
            sed -i "/# >>> wifi-manager metric: wlan0 >>>/,/# <<< wifi-manager metric: wlan0 <<</d" "$DHCPCD_CONF"
            sed -i "/# >>> wifi-manager metric: wlan1 >>>/,/# <<< wifi-manager metric: wlan1 <<</d" "$DHCPCD_CONF"
            systemctl restart dhcpcd 2>/dev/null || true
            log "Managed metric blocks removed"
            msg_box "Metrics" "✓ Metrics gérées retirées de dhcpcd.conf.\nValeurs par défaut de dhcpcd restaurées."
            ;;
        4) return ;;
    esac
}

# ---- Screen: WiFi network selection -----------------------------------------
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
    info_box "  Scan des réseaux WiFi en cours…\n  (peut prendre ~5 secondes)"
    local raw
    raw=$(scan_networks)

    if [[ -z "$raw" ]]; then
        msg_box "Scan" "Aucun réseau trouvé.\n\nVérifiez que wlan1 est actif et que le dongle\nest branché."
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

    [[ ${#menu_items[@]} -eq 0 ]] && { msg_box "Scan" "Aucun réseau détecté."; return 1; }

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "Réseaux WiFi disponibles" \
                    --menu "Choisissez un réseau :" 20 65 12 \
                    "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

    local selected_ssid="${ssid_map[$choice]}"
    [[ -z "$selected_ssid" ]] && return 1

    local password
    password=$(dialog --backtitle "$BACKTITLE" \
                      --title "Connexion : $selected_ssid" --insecure \
                      --passwordbox "Mot de passe WiFi :\n(laisser vide si réseau ouvert)" \
                      10 55 3>&1 1>&2 2>&3) || return 1

    info_box "  Connexion à '$selected_ssid' en cours…"
    if connect_network "$selected_ssid" "$password"; then
        local ip; ip=$(ip -4 addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
        msg_box "Succès" "✓ Connecté à : $selected_ssid\n  IP obtenue  : $ip\n\nLe NAT est actif — les clients AP ont accès\nà Internet."
    else
        msg_box "Échec" "✗ Impossible de se connecter à '$selected_ssid'.\n\nVérifiez le mot de passe ou la disponibilité.\nJournal : $LOG_FILE"
    fi
}

# ---- Screen: wlan0 management (AP) ------------------------------------------
screen_wlan0() {
    local status; status=$(get_wlan0_status)
    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "wlan0 — Point d'accès Astroberry" \
                    --menu "État actuel : $status\n\n⚠  Désactiver wlan0 coupe l'AP et toute\nconnexion distante." \
                    14 65 3 \
                    "1" "Activer l'AP (hostapd + dnsmasq)" \
                    "2" "Désactiver l'AP  [⚠ DÉCONNEXION]" \
                    "3" "Retour" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) info_box "  Activation de wlan0 (AP)…"
           enable_wlan0_ap && msg_box "wlan0" "✓ AP Astroberry activé." \
                           || msg_box "wlan0" "✗ Erreur. Voir $LOG_FILE" ;;
        2) dialog --backtitle "$BACKTITLE" --title "Confirmation" \
               --yesno "Désactiver l'AP wlan0 va couper toutes\nles connexions WiFi vers Astroberry.\n\nContinuer ?" 10 55 || return
           info_box "  Désactivation de wlan0…"
           disable_wlan0_ap
           msg_box "wlan0" "AP désactivé.\n\nReconnectez-vous via SSH/Ethernet ou écran." ;;
        3) return ;;
    esac
}

# ---- Screen: wlan1 management (dongle) --------------------------------------
screen_wlan1() {
    local status; status=$(get_wlan1_status)
    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "wlan1 — Dongle WiFi (accès Internet)" \
                    --menu "État actuel : $status" \
                    14 65 4 \
                    "1" "Activer le dongle wlan1" \
                    "2" "Choisir un réseau WiFi…" \
                    "3" "Désactiver le dongle wlan1" \
                    "4" "Retour" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) info_box "  Activation de wlan1…"
           enable_wlan1 && msg_box "wlan1" "✓ Dongle wlan1 activé." \
                        || msg_box "wlan1" "✗ Erreur. Dongle branché ? Voir $LOG_FILE" ;;
        2) screen_select_network ;;
        3) info_box "  Désactivation de wlan1…"
           disable_wlan1
           msg_box "wlan1" "✓ Dongle wlan1 désactivé. NAT retiré." ;;
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

    local nat_label="désactivé"
    [[ "$nat_st" -gt 0 ]] && nat_label="ACTIF ($nat_st règle(s))"

    # Physical identification of each interface
    local w0_desc w1_desc
    w0_desc=$(describe_iface "wlan0")
    w1_desc=$(describe_iface "wlan1")

    local live; live=$(get_live_metrics); [[ -z "$live" ]] && live="  (aucune)"

    msg_box "État du réseau" "\
Modèle : $PI_MODEL

wlan0 : $w0_desc
        $wlan0_st
wlan1 : $w1_desc
        $wlan1_st

  IP wlan1   : $ip1
  Passerelle : $gw
  IP forward : $fwd
  NAT (wlan1): $nat_label

Routes par défaut :
$live"
}

# ---- Main menu --------------------------------------------------------------
main_menu() {
    while true; do
        local w0_st w1_st
        w0_st=$(get_wlan0_status)
        w1_st=$(get_wlan1_status)

        local choice
        choice=$(dialog --backtitle "$BACKTITLE" \
                        --title "Menu principal" \
                        --cancel-label "Quitter" \
                        --menu "\
  wlan0 (AP) : $w0_st
  wlan1 (Net): $w1_st
" \
                        18 66 7 \
                        "1" "Gérer wlan0  (Point d'accès Astroberry)" \
                        "2" "Gérer wlan1  (Dongle WiFi internet)" \
                        "3" "Choisir réseau WiFi…" \
                        "4" "Priorité des interfaces (metric)" \
                        "5" "Fixer les noms d'interface (udev)" \
                        "6" "Afficher l'état du réseau" \
                        "7" "Quitter" \
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

log "=== wifi-manager started (PID $$) — model: $PI_MODEL (gen $PI_GEN) ==="

# Warn if running on a Pi generation this script was not validated against
if [[ "$PI_GEN" != "4" && "$PI_GEN" != "5" ]]; then
    dialog --backtitle "$BACKTITLE" --title "Modèle non validé" \
           --msgbox "⚠  Modèle détecté :\n   $PI_MODEL\n\nCe script est validé pour le Raspberry Pi 4 et\nle Pi 5. La détection de la puce WiFi intégrée\npeut être imprécise sur ce matériel.\n\nLe script continue, mais vérifiez l'écran d'état." \
           12 64 || true
fi

# Warn if the USB dongle interface is missing
if [[ -z "$(find_usb_iface)" ]]; then
    dialog --backtitle "$BACKTITLE" --title "Avertissement" \
           --msgbox "⚠  Aucun dongle WiFi USB détecté.\n\nVérifiez qu'il est bien branché. Le script\ncontinuera mais wlan1 sera non fonctionnel." \
           10 62 || true
fi

main_menu
