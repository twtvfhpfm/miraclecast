#!/usr/bin/env bash
#
# One-shot Miracast source cast helper.
# 1) pick wireless iface  2) (optional) scan sinks  3) cast via dispctl
#
# Matches the manual flow:
#   sudo miracle-wifid -i <iface>
#   sudo miracle-dispd
#   miracle-dispctl -i <iface> -p <mac>     # as normal user, NOT root
#
# Usage:
#   ./res/miracle-cast.sh
#   ./res/miracle-cast.sh -i wlp4s0 -p c4:3a:35:d2:ba:cc
#   sudo ./res/miracle-cast.sh -i wlp4s0 -p c4:3a:35:d2:ba:cc
#
# Ctrl-C / exit cleans up wifid / dispd / dispctl and children.
#
set -euo pipefail

WIFID_BIN="${WIFID_BIN:-miracle-wifid}"
DISPD_BIN="${DISPD_BIN:-miracle-dispd}"
DISPCTL_BIN="${DISPCTL_BIN:-miracle-dispctl}"
WFD_SUBELEMS="${WFD_SUBELEMS:-000600101c4400c8}"
SCAN_ROUNDS="${SCAN_ROUNDS:-8}"
SCAN_INTERVAL_SEC="${SCAN_INTERVAL_SEC:-2}"

IFACE=""
PEER_MAC=""
PEER_NAME=""
WIFID_PID=""
DISPD_PID=""
DISPCTL_PID=""
CLEANED=0
LOGDIR=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		err "missing command: $1"
		exit 1
	}
}

# Real desktop user (dispctl must not run as uid 0 — StartSession needs login1 RuntimePath).
resolve_user() {
	if [[ "$(id -u)" -eq 0 ]]; then
		if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
			err "run as a normal user (or: sudo -u <you> / sudo with SUDO_USER set)"
			err "miracle-dispctl must not run as root (uid=0 breaks gstencoder session)"
			exit 1
		fi
		REAL_USER="$SUDO_USER"
	else
		REAL_USER="$USER"
	fi
	REAL_UID="$(id -u "$REAL_USER")"
	REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
	log "dispctl user: $REAL_USER (uid=$REAL_UID)"
}

# Run command as REAL_USER; keep X11/session env.
run_as_user() {
	local display xauth runtime
	display="${DISPLAY:-:0}"
	xauth="${XAUTHORITY:-$REAL_HOME/.Xauthority}"
	runtime="${XDG_RUNTIME_DIR:-/run/user/$REAL_UID}"

	if [[ "$(id -u)" -eq 0 ]]; then
		sudo -u "$REAL_USER" \
			DISPLAY="$display" \
			XAUTHORITY="$xauth" \
			XDG_RUNTIME_DIR="$runtime" \
			DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime/bus}" \
			"$@"
	else
		DISPLAY="$display" \
		XAUTHORITY="$xauth" \
		XDG_RUNTIME_DIR="$runtime" \
		"$@"
	fi
}

sudo_root() {
	if [[ "$(id -u)" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

cleanup() {
	local ec=$?
	if [[ "$CLEANED" -eq 1 ]]; then
		return 0
	fi
	CLEANED=1
	trap - INT TERM EXIT

	log ""
	log "cleaning up..."

	if [[ -n "$DISPCTL_PID" ]] && kill -0 "$DISPCTL_PID" 2>/dev/null; then
		kill -INT "$DISPCTL_PID" 2>/dev/null || true
		sleep 0.5
		kill -TERM "$DISPCTL_PID" 2>/dev/null || true
		wait "$DISPCTL_PID" 2>/dev/null || true
	fi

	if [[ -n "$DISPD_PID" ]] && kill -0 "$DISPD_PID" 2>/dev/null; then
		kill -TERM "$DISPD_PID" 2>/dev/null || true
		sudo_root pkill -P "$DISPD_PID" 2>/dev/null || true
		wait "$DISPD_PID" 2>/dev/null || true
	fi

	if [[ -n "$WIFID_PID" ]] && kill -0 "$WIFID_PID" 2>/dev/null; then
		kill -TERM "$WIFID_PID" 2>/dev/null || true
		sudo_root pkill -P "$WIFID_PID" 2>/dev/null || true
		wait "$WIFID_PID" 2>/dev/null || true
	fi

	sudo_root pkill -f 'wpa_supplicant .* /run/miracle/wifi' 2>/dev/null || true

	# Give NM the iface back if we stole it.
	if [[ -n "${IFACE:-}" ]] && command -v nmcli >/dev/null 2>&1; then
		nmcli device set "$IFACE" managed yes 2>/dev/null || true
	fi

	log "done."
	exit "$ec"
}

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h|--help) usage ;;
	-i|--iface) IFACE="$2"; shift 2 ;;
	-p|--peer) PEER_MAC="$2"; shift 2 ;;
	-w|--wfd-subelems) WFD_SUBELEMS="$2"; shift 2 ;;
	*) err "unknown arg: $1"; exit 1 ;;
	esac
done

list_wireless_ifaces() {
	local iface
	for iface in /sys/class/net/*/wireless; do
		[[ -e "$iface" ]] || continue
		basename "$(dirname "$iface")"
	done
}

pick_iface() {
	local -a ifaces=()
	local i choice

	if [[ -n "$IFACE" ]]; then
		if [[ ! -d "/sys/class/net/$IFACE" ]]; then
			err "interface not found: $IFACE"
			exit 1
		fi
		return 0
	fi

	mapfile -t ifaces < <(list_wireless_ifaces)
	if [[ ${#ifaces[@]} -eq 0 ]]; then
		err "no wireless interface found"
		exit 1
	fi

	log "Select wireless interface:"
	for i in "${!ifaces[@]}"; do
		printf '  [%d] %s\n' "$((i + 1))" "${ifaces[$i]}"
	done

	while true; do
		read -r -p "choice [1-${#ifaces[@]}]: " choice
		if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
			IFACE="${ifaces[$((choice - 1))]}"
			return 0
		fi
		log "invalid choice"
	done
}

wait_bus_name() {
	local name="$1"
	local timeout="${2:-20}"
	local i
	for ((i = 0; i < timeout * 2; i++)); do
		if busctl status "$name" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5
	done
	err "timeout waiting for D-Bus name: $name"
	return 1
}

find_link_path() {
	local iface="$1"
	local path name
	while IFS= read -r path; do
		[[ "$path" == */link/* ]] || continue
		name=$(busctl get-property org.freedesktop.miracle.wifi "$path" \
			org.freedesktop.miracle.wifi.Link InterfaceName 2>/dev/null \
			| awk -F'"' '{print $2}')
		if [[ "$name" == "$iface" ]]; then
			printf '%s\n' "$path"
			return 0
		fi
	done < <(busctl tree --list org.freedesktop.miracle.wifi 2>/dev/null || true)
	return 1
}

release_nm() {
	local iface="$1"
	if command -v nmcli >/dev/null 2>&1; then
		log "NetworkManager: set $iface managed no"
		nmcli device set "$iface" managed no 2>/dev/null || true
		sleep 0.5
	else
		log "nmcli not found; hope NM does not own $iface (or use dispctl borrow)"
	fi
}

dbus_manage_and_scan() {
	local link_path="$1"
	local i managed

	busctl call org.freedesktop.miracle.wifi "$link_path" \
		org.freedesktop.miracle.wifi.Link Manage >/dev/null

	managed=""
	for ((i = 0; i < 40; i++)); do
		managed=$(busctl get-property org.freedesktop.miracle.wifi "$link_path" \
			org.freedesktop.miracle.wifi.Link Managed 2>/dev/null | awk '{print $2}')
		[[ "$managed" == "true" ]] && break
		sleep 0.25
	done
	if [[ "$managed" != "true" ]]; then
		err "link not managed yet (is NM still owning the iface?)"
		return 1
	fi

	busctl set-property org.freedesktop.miracle.wifi "$link_path" \
		org.freedesktop.miracle.wifi.Link WfdSubelements s "$WFD_SUBELEMS"

	busctl set-property org.freedesktop.miracle.wifi "$link_path" \
		org.freedesktop.miracle.wifi.Link P2PScanning b true
}

scan_peers_once() {
	local path mac name wfd
	PEER_MACS=()
	PEER_NAMES=()

	while IFS= read -r path; do
		[[ "$path" == */peer/* ]] || continue
		mac=$(busctl get-property org.freedesktop.miracle.wifi "$path" \
			org.freedesktop.miracle.wifi.Peer P2PMac 2>/dev/null \
			| awk -F'"' '{print $2}')
		name=$(busctl get-property org.freedesktop.miracle.wifi "$path" \
			org.freedesktop.miracle.wifi.Peer FriendlyName 2>/dev/null \
			| awk -F'"' '{print $2}')
		wfd=$(busctl get-property org.freedesktop.miracle.wifi "$path" \
			org.freedesktop.miracle.wifi.Peer WfdSubelements 2>/dev/null \
			| awk -F'"' '{print $2}')
		[[ -n "$mac" ]] || continue
		[[ -n "$wfd" && "$wfd" != "none" ]] || continue
		[[ -n "$name" ]] || name="(unknown)"

		local dup=0 m
		if [[ ${#PEER_MACS[@]} -gt 0 ]]; then
			for m in "${PEER_MACS[@]}"; do
				if [[ "${m,,}" == "${mac,,}" ]]; then
					dup=1
					break
				fi
			done
		fi
		[[ "$dup" -eq 0 ]] || continue

		PEER_MACS+=("$mac")
		PEER_NAMES+=("$name")
	done < <(busctl tree --list org.freedesktop.miracle.wifi 2>/dev/null || true)
}

pick_sink() {
	local round choice i
	PEER_MACS=()
	PEER_NAMES=()

	log ""
	log "Scanning for Miracast peers (Ctrl-C to abort)..."

	for ((round = 1; round <= SCAN_ROUNDS; round++)); do
		scan_peers_once
		if [[ ${#PEER_MACS[@]} -gt 0 ]]; then
			break
		fi
		printf '\r  round %d/%d — no peer yet...' "$round" "$SCAN_ROUNDS"
		sleep "$SCAN_INTERVAL_SEC"
	done
	printf '\n'

	while true; do
		scan_peers_once
		if [[ ${#PEER_MACS[@]} -eq 0 ]]; then
			log "no sink found. options: [r]escan  [q]uit"
			read -r -p "> " choice
			case "$choice" in
			r|R) sleep "$SCAN_INTERVAL_SEC"; continue ;;
			q|Q) return 1 ;;
			*) continue ;;
			esac
		fi

		log ""
		log "Select sink:"
		for i in "${!PEER_MACS[@]}"; do
			printf '  [%d] %-24s  %s\n' \
				"$((i + 1))" "${PEER_NAMES[$i]}" "${PEER_MACS[$i]}"
		done
		log "  [r] rescan"
		log "  [q] quit"

		read -r -p "choice: " choice
		case "$choice" in
		r|R)
			sleep "$SCAN_INTERVAL_SEC"
			continue
			;;
		q|Q)
			return 1
			;;
		esac
		if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#PEER_MACS[@]} )); then
			PEER_MAC="${PEER_MACS[$((choice - 1))]}"
			PEER_NAME="${PEER_NAMES[$((choice - 1))]}"
			return 0
		fi
		log "invalid choice"
	done
}

kill_stale_daemons() {
	# Avoid "unable to publish WFD service" from leftover instances.
	sudo_root pkill -x miracle-dispd 2>/dev/null || true
	sudo_root pkill -x miracle-wifid 2>/dev/null || true
	sudo_root pkill -f 'wpa_supplicant .* /run/miracle/wifi' 2>/dev/null || true
	sleep 0.5
}

start_daemons() {
	local iface="$1"

	LOGDIR=$(mktemp -d /tmp/miracle-cast.XXXXXX)
	WIFID_LOG="$LOGDIR/wifid.log"
	DISPD_LOG="$LOGDIR/dispd.log"
	log "logs: $LOGDIR"

	kill_stale_daemons

	# shellcheck disable=SC2024
	sudo_root "$WIFID_BIN" --log-level info --wpa-loglevel info -i "$iface" \
		>"$WIFID_LOG" 2>&1 &
	WIFID_PID=$!

	wait_bus_name org.freedesktop.miracle.wifi 25 || {
		err "wifid failed to claim D-Bus; see $WIFID_LOG"
		tail -20 "$WIFID_LOG" >&2 || true
		return 1
	}

	# shellcheck disable=SC2024
	sudo_root "$DISPD_BIN" >"$DISPD_LOG" 2>&1 &
	DISPD_PID=$!

	wait_bus_name org.freedesktop.miracle.wfd 25 || {
		err "dispd failed to claim D-Bus; see $DISPD_LOG"
		tail -20 "$DISPD_LOG" >&2 || true
		return 1
	}

	# Ensure daemons still alive
	if ! kill -0 "$WIFID_PID" 2>/dev/null; then
		err "wifid exited early; see $WIFID_LOG"
		tail -30 "$WIFID_LOG" >&2 || true
		return 1
	fi
	if ! kill -0 "$DISPD_PID" 2>/dev/null; then
		err "dispd exited early; see $DISPD_LOG"
		tail -30 "$DISPD_LOG" >&2 || true
		return 1
	fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT_AP_SH="${CONNECT_AP_SH:-connect-ap-during-cast.sh}"

prompt_connect_ap() {
	local choice
	if [[ ! -x "$CONNECT_AP_SH" ]]; then
		err "connect-ap script missing/not executable: $CONNECT_AP_SH"
		return 1
	fi

	log ""
	log "========================================"
	log " After cast succeeds, press 1 + Enter"
	log " to connect WiFi (same NIC, PEAP)"
	log " Other / empty = skip"
	log "========================================"
	read -r -p "> " choice
	if [[ "$choice" != "1" ]]; then
		log "skipped WiFi connect"
		return 0
	fi

	log "running: sudo $CONNECT_AP_SH --insecure-no-ca --iface $IFACE"
	sudo_root "$CONNECT_AP_SH" --insecure-no-ca --iface "$IFACE" || {
		err "connect-ap-during-cast.sh failed (cast may still be running)"
		return 0
	}
}

start_dispctl() {
	local dont_borrow="$1"

	log ""
	log "casting to: ${PEER_NAME:-?} ($PEER_MAC)"
	log "starting $DISPCTL_BIN as user $REAL_USER (Ctrl-C to stop)..."

	local -a args=(
		"$DISPCTL_BIN"
		-i "$IFACE"
		-p "$PEER_MAC"
		-w "$WFD_SUBELEMS"
	)
	if [[ "$dont_borrow" -eq 1 ]]; then
		# Link already managed/scanning by this script.
		args+=(--dont-borrow --dont-return)
	fi

	# IMPORTANT: do NOT sudo dispctl — uid must be the desktop user.
	run_as_user "${args[@]}" &
	DISPCTL_PID=$!

	prompt_connect_ap || true

	log "waiting for cast session to end (Ctrl-C to stop)..."
	wait "$DISPCTL_PID" || true
	DISPCTL_PID=""
}

main() {
	need_cmd busctl
	need_cmd "$WIFID_BIN"
	need_cmd "$DISPD_BIN"
	need_cmd "$DISPCTL_BIN"

	resolve_user

	if [[ -z "${DISPLAY:-}" && "$(id -u)" -ne 0 ]]; then
		err "DISPLAY is not set (needed to capture the screen)"
		exit 1
	fi
	# When invoked via sudo, DISPLAY may be stripped; default :0 for the user session.
	export DISPLAY="${DISPLAY:-:0}"

	pick_iface
	log "interface=$IFACE"

	trap cleanup INT TERM EXIT

	start_daemons "$IFACE"

	if [[ -n "$PEER_MAC" ]]; then
		# Closest to manual: let dispctl borrow NM + manage + connect.
		log "peer given (-p); dispctl will acquire iface (same as manual)"
		PEER_NAME="${PEER_NAME:-$PEER_MAC}"
		start_dispctl 0
		return 0
	fi

	# Interactive: release NM, manage, scan, then dispctl without re-borrow.
	release_nm "$IFACE"

	LINK_PATH=$(find_link_path "$IFACE") || {
		err "cannot find D-Bus link for $IFACE (is wifid running with -i $IFACE?)"
		exit 1
	}
	log "link=$LINK_PATH"

	dbus_manage_and_scan "$LINK_PATH"

	if ! pick_sink; then
		log "aborted"
		exit 1
	fi

	start_dispctl 1
}

main "$@"
