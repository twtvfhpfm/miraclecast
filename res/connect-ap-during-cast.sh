#!/usr/bin/env bash
#
# During Miracast Source cast, use miracle's wpa_supplicant (not system wpa)
# to associate the SAME physical NIC to an infrastructure AP.
#
# PSK:
#   sudo ./test/connect-ap-during-cast.sh --ssid "Home" --pass "secret"
#
# Enterprise PEAP (MSCHAPv2):
#   sudo ./test/connect-ap-during-cast.sh --mode peap \
#     --ssid "CorpWiFi" --identity "user@corp.com" --pass "secret"
#   sudo ./test/connect-ap-during-cast.sh --mode peap \
#     --ssid "CorpWiFi" --identity "user" --pass "secret" \
#     --ca-cert /path/to/ca.pem
#   # lab only (skip server cert verify):
#   sudo ./test/connect-ap-during-cast.sh --mode peap \
#     --ssid "CorpWiFi" --identity "user" --pass "secret" --insecure-no-ca
#
# Other:
#   sudo ./test/connect-ap-during-cast.sh --status
#   sudo ./test/connect-ap-during-cast.sh --disconnect
#
# Notes:
#   - Requires active miracle-wifid (ctrl under /run/miracle/wifi).
#   - Configures parent iface only; does not touch p2p-0.
#   - Concurrent STA+P2P is driver-dependent.
#
set -euo pipefail

CTRL_DIR=/run/miracle/wifi
SSID="xxxx"
PASS="xxx"
IDENTITY="xxx"
ANON_ID=""
CA_CERT=""
PHASE2="auth=MSCHAPV2"
MODE="peap"          # psk | peap (auto: peap if --identity set)
IFACE="wlp4s0"
DO_DHCP=1
INSECURE_NO_CA=0
WAIT_SEC=45
ACTION=connect

usage() {
	sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h|--help) usage ;;
	--ssid) SSID="$2"; shift 2 ;;
	--pass|--password) PASS="$2"; shift 2 ;;
	--identity|--user) IDENTITY="$2"; shift 2 ;;
	--anonymous-identity) ANON_ID="$2"; shift 2 ;;
	--ca-cert) CA_CERT="$2"; shift 2 ;;
	--phase2) PHASE2="$2"; shift 2 ;;
	--mode) MODE="$2"; shift 2 ;;
	--insecure-no-ca) INSECURE_NO_CA=1; shift ;;
	--iface|-i) IFACE="$2"; shift 2 ;;
	--ctrl) CTRL_DIR="$2"; shift 2 ;;
	--wait) WAIT_SEC="$2"; shift 2 ;;
	--no-dhcp) DO_DHCP=0; shift ;;
	--status) ACTION=status; shift ;;
	--disconnect) ACTION=disconnect; shift ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

need_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "run as root (sudo)" >&2
		exit 1
	fi
}

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }

detect_iface() {
	local f base
	if [[ -n "$IFACE" ]]; then
		return 0
	fi
	for f in "$CTRL_DIR"/*.conf; do
		[[ -e "$f" ]] || continue
		base=$(basename "$f" .conf)
		IFACE=${base%-*}
		if [[ -d "/sys/class/net/$IFACE" ]]; then
			echo "auto iface: $IFACE"
			return 0
		fi
	done
	echo "cannot detect iface; pass --iface" >&2
	exit 1
}

resolve_mode() {
	if [[ -z "$MODE" ]]; then
		if [[ -n "$IDENTITY" ]]; then
			MODE=peap
		else
			MODE=psk
		fi
	fi
	case "$MODE" in
	psk|peap) ;;
	*) echo "mode must be psk|peap" >&2; exit 1 ;;
	esac
}

wpa() {
	wpa_cli -p "$CTRL_DIR" -i "$IFACE" "$@"
}

wpa_set() {
	local nid="$1" key="$2" val="$3" rc
	rc=$(wpa set_network "$nid" "$key" "$val")
	if [[ "$rc" != "OK" ]]; then
		echo "set_network $key failed: $rc" >&2
		exit 1
	fi
}

# Quote a string for wpa_cli set_network (wrap in double quotes).
q() { printf '"%s"' "$1"; }

p2p_ifaces() {
	local d
	for d in /sys/class/net/p2p-*; do
		[[ -e "$d" ]] || continue
		basename "$d"
	done
}

show_status() {
	echo "======== miracle ctrl ========"
	ls -la "$CTRL_DIR" 2>/dev/null || echo "(no $CTRL_DIR)"
	echo ""
	echo "======== links ========"
	ip -br link | grep -E "wlx|wlp|p2p" || true
	echo ""
	echo "======== STA ($IFACE) ========"
	if [[ -d "/sys/class/net/$IFACE" ]]; then
		iw dev "$IFACE" link 2>/dev/null || true
		wpa status 2>/dev/null || true
		ip -br addr show "$IFACE" || true
	else
		echo "iface $IFACE missing"
	fi
	echo ""
	echo "======== P2P group ========"
	local p
	for p in $(p2p_ifaces); do
		echo "--- $p ---"
		iw dev "$p" link 2>/dev/null || true
		wpa_cli -p "$CTRL_DIR" -i "$p" status 2>/dev/null || true
		ip -br addr show "$p" 2>/dev/null || true
	done
	if [[ -z "$(p2p_ifaces)" ]]; then
		echo "(no p2p-* iface; cast group may be down)"
	fi
}

find_miracle_networks() {
	wpa list_networks 2>/dev/null | awk 'NR>1 {print $1}'
}

disconnect_ap() {
	local id
	echo "disabling/removing networks on $IFACE ..."
	for id in $(find_miracle_networks); do
		wpa disable_network "$id" >/dev/null 2>&1 || true
		wpa remove_network "$id" >/dev/null 2>&1 || true
		echo "  removed network id=$id"
	done
	if [[ "$DO_DHCP" -eq 1 ]]; then
		dhclient -r "$IFACE" 2>/dev/null || true
	fi
	echo "done"
	show_status
}

configure_psk() {
	local nid="$1"
	wpa_set "$nid" key_mgmt "WPA-PSK"
	wpa_set "$nid" psk "$(q "$PASS")"
}

configure_peap() {
	local nid="$1"

	if [[ -z "$IDENTITY" ]]; then
		echo "PEAP requires --identity" >&2
		exit 1
	fi
	if [[ -n "$CA_CERT" && ! -f "$CA_CERT" ]]; then
		echo "ca-cert not found: $CA_CERT" >&2
		exit 1
	fi
	if [[ -z "$CA_CERT" && "$INSECURE_NO_CA" -ne 1 ]]; then
		echo "PEAP: pass --ca-cert /path/to/ca.pem, or --insecure-no-ca for lab only" >&2
		exit 1
	fi

	wpa_set "$nid" key_mgmt "WPA-EAP"
	wpa_set "$nid" eap "PEAP"
	wpa_set "$nid" identity "$(q "$IDENTITY")"
	wpa_set "$nid" password "$(q "$PASS")"
	wpa_set "$nid" phase2 "$(q "$PHASE2")"

	if [[ -n "$ANON_ID" ]]; then
		wpa_set "$nid" anonymous_identity "$(q "$ANON_ID")"
	fi

	if [[ -n "$CA_CERT" ]]; then
		wpa_set "$nid" ca_cert "$(q "$CA_CERT")"
	elif [[ "$INSECURE_NO_CA" -eq 1 ]]; then
		echo "WARNING: --insecure-no-ca — server certificate not verified"
		# Empty ca_cert + peaplabel often works on lab APs; may still fail
		# if the AP requires a proper trust chain.
		wpa_set "$nid" phase1 "$(q "peaplabel=0")"
	fi
}

connect_ap() {
	local nid rc state i p2p_before p2p_after

	if [[ -z "$SSID" ]]; then
		echo "--ssid required" >&2
		exit 1
	fi
	if [[ -z "$PASS" ]]; then
		echo "--pass required" >&2
		exit 1
	fi
	if [[ ! -d "$CTRL_DIR" ]]; then
		echo "missing $CTRL_DIR — is miracle-wifid running?" >&2
		exit 1
	fi
	if [[ ! -d "/sys/class/net/$IFACE" ]]; then
		echo "iface $IFACE not found" >&2
		exit 1
	fi

	p2p_before=$(p2p_ifaces | tr '\n' ' ')
	echo "P2P before: ${p2p_before:-"(none)"}"
	if [[ -z "$p2p_before" ]]; then
		echo "WARNING: no p2p-* iface — cast may not be active; continuing anyway"
	fi

	echo "STA iface: $IFACE"
	echo "ctrl:     $CTRL_DIR"
	echo "ssid:     $SSID"
	echo "mode:     $MODE"
	if [[ "$MODE" == "peap" ]]; then
		echo "identity: $IDENTITY"
		echo "phase2:   $PHASE2"
		echo "ca_cert:  ${CA_CERT:-"(none / insecure)"}"
	fi
	echo ""

	for nid in $(find_miracle_networks); do
		echo "cleanup old network id=$nid"
		wpa disable_network "$nid" >/dev/null 2>&1 || true
		wpa remove_network "$nid" >/dev/null 2>&1 || true
	done

	nid=$(wpa add_network | awk '{print $NF}')
	if [[ -z "$nid" || "$nid" == "FAIL" ]]; then
		echo "add_network failed" >&2
		exit 1
	fi
	echo "network id=$nid"

	wpa_set "$nid" ssid "$(q "$SSID")"
	case "$MODE" in
	psk) configure_psk "$nid" ;;
	peap) configure_peap "$nid" ;;
	esac

	rc=$(wpa enable_network "$nid")
	[[ "$rc" == "OK" ]] || { echo "enable_network failed: $rc" >&2; exit 1; }
	# Prefer this network; avoid sticking on scan-only.
	wpa select_network "$nid" >/dev/null 2>&1 || true

	echo "waiting for COMPLETED (up to ${WAIT_SEC}s) ..."
	state=""
	for i in $(seq 1 "$WAIT_SEC"); do
		state=$(wpa status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
		echo "  [${i}s] wpa_state=$state"
		if [[ "$state" == "COMPLETED" ]]; then
			break
		fi
		# Surface EAP failures early
		if wpa status 2>/dev/null | grep -qi 'EAP authentication failed'; then
			echo "EAP authentication failed (see journal / wpa log)"
			break
		fi
		sleep 1
	done

	if [[ "$state" != "COMPLETED" ]]; then
		echo "FAIL: STA did not reach COMPLETED (state=$state)"
		echo "Tips for PEAP:"
		echo "  - check identity/password / domain\\user format"
		echo "  - try --anonymous-identity \"anon\" if outer ID required"
		echo "  - provide corporate --ca-cert, or --insecure-no-ca for lab"
		echo "  - sudo journalctl -f SYSLOG_IDENTIFIER=miracle-wifid-*  during connect"
		p2p_after=$(p2p_ifaces | tr '\n' ' ')
		echo "P2P after: ${p2p_after:-"(none)"}"
		show_status
		exit 2
	fi

	echo "STA associated OK"
	iw dev "$IFACE" link 2>/dev/null || true
	wpa status 2>/dev/null | grep -E '^(ssid|key_mgmt|eap_type|ip_address|wpa_state)=' || true

	if [[ "$DO_DHCP" -eq 1 ]]; then
		echo "running dhclient on $IFACE ..."
		dhclient -v "$IFACE" || echo "WARNING: dhclient failed"
		ip -br addr show "$IFACE" || true
	fi

	p2p_after=$(p2p_ifaces | tr '\n' ' ')
	echo ""
	echo "======== result ========"
	echo "STA:     COMPLETED on $IFACE ($MODE)"
	echo "P2P before: ${p2p_before:-"(none)"}"
	echo "P2P after:  ${p2p_after:-"(none)"}"
	if [[ -n "$p2p_before" && -z "$p2p_after" ]]; then
		echo "WARNING: p2p group iface disappeared — cast likely broken"
		exit 3
	fi
	for p in $(p2p_ifaces); do
		if ! iw dev "$p" link 2>/dev/null | grep -q "Connected to"; then
			echo "WARNING: $p not connected — cast may be down"
		else
			echo "OK: $p still connected"
			iw dev "$p" link 2>/dev/null | head -5
		fi
	done
	echo ""
	echo "Manual checks:"
	echo "  ping -c 3 -I $IFACE <gateway>"
	echo "  sudo tcpdump -i p2p-0 -c 20 'udp port 20100'"
	echo "  sudo $0 --status"
	echo "  sudo $0 --disconnect"
}

need_root
need wpa_cli
need iw
need ip
detect_iface
resolve_mode

case "$ACTION" in
status) show_status ;;
disconnect) disconnect_ap ;;
connect) connect_ap ;;
esac
