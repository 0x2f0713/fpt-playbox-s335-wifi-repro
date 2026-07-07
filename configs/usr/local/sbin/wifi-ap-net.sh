#!/bin/sh
set -eu

AP_IF="${AP_IF:-wlan0}"
AP_CIDR="${AP_CIDR:-10.70.2.1/24}"
AP_NET="${AP_NET:-10.70.2.0/24}"
WAN_IF="${WAN_IF:-}"
REG_DOMAIN="${REG_DOMAIN:-US}"

find_wan_if() {
    if [ -n "$WAN_IF" ]; then
        printf '%s\n' "$WAN_IF"
        return
    fi

    ip -4 route show default | awk '{print $5; exit}'
}

iptables_add_once() {
    table="$1"
    shift

    if [ "$table" = "filter" ]; then
        iptables -C "$@" 2>/dev/null || iptables -A "$@"
    else
        iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
    fi
}

iptables_del_if_present() {
    table="$1"
    shift

    if [ "$table" = "filter" ]; then
        while iptables -C "$@" 2>/dev/null; do
            iptables -D "$@"
        done
    else
        while iptables -t "$table" -C "$@" 2>/dev/null; do
            iptables -t "$table" -D "$@"
        done
    fi
}

start_ap_net() {
    wan="$(find_wan_if)"
    if [ -z "$wan" ]; then
        echo "No IPv4 default route found; set WAN_IF in wifi-ap-net.service" >&2
        exit 1
    fi

    modprobe ath10k_sdio || true
    for _ in $(seq 1 20); do
        [ -d "/sys/class/net/$AP_IF" ] && break
        sleep 1
    done

    if [ ! -d "/sys/class/net/$AP_IF" ]; then
        echo "Interface $AP_IF did not appear after loading ath10k_sdio" >&2
        exit 1
    fi

    iw reg set "$REG_DOMAIN" || true
    sleep 1

    ip addr flush dev "$AP_IF" || true
    ip addr add "$AP_CIDR" dev "$AP_IF"
    ip link set "$AP_IF" up

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    iptables_add_once nat POSTROUTING -s "$AP_NET" -o "$wan" -j MASQUERADE
    iptables_add_once filter FORWARD -i "$AP_IF" -o "$wan" -j ACCEPT
    iptables_add_once filter FORWARD -i "$wan" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

stop_ap_net() {
    wan="$(find_wan_if || true)"
    if [ -n "$wan" ]; then
        iptables_del_if_present filter FORWARD -i "$wan" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables_del_if_present filter FORWARD -i "$AP_IF" -o "$wan" -j ACCEPT
        iptables_del_if_present nat POSTROUTING -s "$AP_NET" -o "$wan" -j MASQUERADE
    fi

    ip addr flush dev "$AP_IF" || true
}

case "${1:-start}" in
    start)
        start_ap_net
        ;;
    stop)
        stop_ap_net
        ;;
    restart)
        stop_ap_net
        start_ap_net
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}" >&2
        exit 2
        ;;
esac
