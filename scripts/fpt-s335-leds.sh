#!/bin/sh
set -eu

SYSFS_GPIO=/sys/class/gpio
VISIBLE_LEDS="sys net"
CANDIDATE_LEDS="sys net gpioctrl-net"

usage() {
	cat <<'EOF'
Usage:
  fpt-s335-leds.sh status [sys|net|gpioctrl-net|all|candidates]
  fpt-s335-leds.sh on     <sys|net|gpioctrl-net|all>
  fpt-s335-leds.sh off    <sys|net|gpioctrl-net|all>
  fpt-s335-leds.sh blink  <sys|net|gpioctrl-net|all|candidates> [count]
  fpt-s335-leds.sh net-watch [iface]
  fpt-s335-leds.sh demo
  fpt-s335-leds.sh release [sys|net|gpioctrl-net|all|candidates]

LED names from the Android firmware:
  sys    gpioctrl.sys_led   GPIODV_24  Linux GPIO 596  active-low
  net    blinkled_gpio      GPIOAO_5   Linux GPIO 517  active-low
  gpioctrl-net gpioctrl.net_led GPIOAO_9 Linux GPIO 521  active-low non-visible candidate

"all" means sys+net. "candidates" means sys+net+gpioctrl-net.

net-watch turns sys on, keeps net off when idle, and pulses net when the
selected interface RX/TX byte counters change. Defaults can be overridden with:
  FPT_S335_LED_IFACE=eth0
  FPT_S335_LED_POLL=0.25
  FPT_S335_LED_PULSE=0.25
  FPT_S335_SYS_MODE=blink
  FPT_S335_SYS_ON=1
  FPT_S335_SYS_OFF=1
EOF
}

die() {
	echo "fpt-s335-leds.sh: $*" >&2
	exit 1
}

normalize_led() {
	case "$1" in
		sys|system) echo sys ;;
		net|network|white|blink) echo net ;;
		gpioctrl-net|old-net|ao9) echo gpioctrl-net ;;
		*) die "unknown LED '$1'" ;;
	esac
}

expand_targets() {
	case "${1:-all}" in
		all) echo "$VISIBLE_LEDS" ;;
		candidates) echo "$CANDIDATE_LEDS" ;;
		*) normalize_led "$1" ;;
	esac
}

gpio_num() {
	case "$1" in
		sys) echo 596 ;;
		net) echo 517 ;;
		gpioctrl-net) echo 521 ;;
	esac
}

active_low() {
	case "$1" in
		sys|net|gpioctrl-net) echo 1 ;;
		*) echo 0 ;;
	esac
}

pin_desc() {
	case "$1" in
		sys) echo "GPIODV_24 gpioctrl.sys_led active-low" ;;
		net) echo "GPIOAO_5 blinkled_gpio active-low white LED" ;;
		gpioctrl-net) echo "GPIOAO_9 gpioctrl.net_led active-low non-visible candidate" ;;
	esac
}

ensure_gpio() {
	n="$1"
	if [ ! -d "$SYSFS_GPIO/gpio$n" ]; then
		echo "$n" > "$SYSFS_GPIO/export"
	fi

	wait_i=0
	while [ ! -d "$SYSFS_GPIO/gpio$n" ] && [ "$wait_i" -lt 50 ]; do
		sleep 0.02
		wait_i=$((wait_i + 1))
	done
	[ -d "$SYSFS_GPIO/gpio$n" ] || die "GPIO $n did not appear in sysfs"
}

state_value() {
	led="$1"
	state="$2"
	low="$(active_low "$led")"

	case "$state:$low" in
		on:0|off:1) echo 1 ;;
		off:0|on:1) echo 0 ;;
		*) die "unknown state '$state'" ;;
	esac
}

logical_state() {
	led="$1"
	value="$2"
	low="$(active_low "$led")"

	if { [ "$low" = 0 ] && [ "$value" = 1 ]; } ||
	   { [ "$low" = 1 ] && [ "$value" = 0 ]; }; then
		echo on
	else
		echo off
	fi
}

write_led() {
	led="$1"
	state="$2"
	n="$(gpio_num "$led")"
	value="$(state_value "$led" "$state")"
	ensure_gpio "$n"
	echo out > "$SYSFS_GPIO/gpio$n/direction"
	echo "$value" > "$SYSFS_GPIO/gpio$n/value"
}

set_targets() {
	state="$1"
	target="${2:-}"
	[ -n "$target" ] || die "$state needs a target"

	for led in $(expand_targets "$target"); do
		write_led "$led" "$state"
		n="$(gpio_num "$led")"
		value="$(cat "$SYSFS_GPIO/gpio$n/value")"
		printf "%-5s %-3s gpio%-3s value=%s %s\n" "$state" "$led" "$n" "$value" "$(pin_desc "$led")"
	done
}

status_targets() {
	for led in $(expand_targets "${1:-all}"); do
		n="$(gpio_num "$led")"
		if [ -d "$SYSFS_GPIO/gpio$n" ]; then
			dir="$(cat "$SYSFS_GPIO/gpio$n/direction")"
			value="$(cat "$SYSFS_GPIO/gpio$n/value")"
			if [ "$dir" = out ]; then
				logical="$(logical_state "$led" "$value")"
			else
				logical="n/a"
			fi
			printf "%-5s gpio%-3s direction=%-3s value=%s logical=%-3s %s\n" "$led" "$n" "$dir" "$value" "$logical" "$(pin_desc "$led")"
		else
			printf "%-5s gpio%-3s unexported          %s\n" "$led" "$n" "$(pin_desc "$led")"
		fi
	done
}

blink_one() {
	led="$1"
	count="${2:-3}"
	case "$count" in
		''|*[!0-9]*) die "blink count must be a positive integer" ;;
	esac
	[ "$count" -gt 0 ] || die "blink count must be greater than zero"

	n="$(gpio_num "$led")"
	was_exported=1
	[ -d "$SYSFS_GPIO/gpio$n" ] || was_exported=0
	ensure_gpio "$n"
	was_dir="$(cat "$SYSFS_GPIO/gpio$n/direction")"
	was_value="$(cat "$SYSFS_GPIO/gpio$n/value")"

	blink_i=0
	while [ "$blink_i" -lt "$count" ]; do
		write_led "$led" on
		sleep 0.35
		write_led "$led" off
		sleep 0.35
		blink_i=$((blink_i + 1))
	done

	if [ "$was_dir" = out ]; then
		echo out > "$SYSFS_GPIO/gpio$n/direction"
		echo "$was_value" > "$SYSFS_GPIO/gpio$n/value"
	else
		echo in > "$SYSFS_GPIO/gpio$n/direction"
	fi
	if [ "$was_exported" = 0 ]; then
		echo "$n" > "$SYSFS_GPIO/unexport"
	fi
	printf "blink %-5s gpio%-3s count=%s restored_direction=%s restored_value=%s\n" "$led" "$n" "$count" "$was_dir" "$was_value"
}

blink_targets() {
	target="${1:-}"
	[ -n "$target" ] || die "blink needs a target"
	count="${2:-3}"

	for led in $(expand_targets "$target"); do
		blink_one "$led" "$count"
	done
}


net_sample() {
	iface="$1"
	stats="/sys/class/net/$iface/statistics"
	[ -r "$stats/rx_bytes" ] && [ -r "$stats/tx_bytes" ] || return 1
	IFS= read -r rx_bytes < "$stats/rx_bytes" || return 1
	IFS= read -r tx_bytes < "$stats/tx_bytes" || return 1
	NET_SAMPLE="$rx_bytes:$tx_bytes"
}

wait_for_iface() {
	iface="$1"
	while ! net_sample "$iface" >/dev/null 2>&1; do
		echo "waiting for network interface $iface" >&2
		sleep 1
	done
}

net_watch() {
	iface="${1:-${FPT_S335_LED_IFACE:-eth0}}"
	poll="${FPT_S335_LED_POLL:-0.2}"
	pulse="${FPT_S335_LED_PULSE:-0.08}"
	sys_mode="${FPT_S335_SYS_MODE:-on}"
	sys_on="${FPT_S335_SYS_ON:-3}"
	sys_off="${FPT_S335_SYS_OFF:-3}"
	sys_gpio=596
	net_gpio=517
	sys_value="$SYSFS_GPIO/gpio$sys_gpio/value"
	net_value="$SYSFS_GPIO/gpio$net_gpio/value"

	wait_for_iface "$iface"
	ensure_gpio "$sys_gpio"
	ensure_gpio "$net_gpio"
	echo out > "$SYSFS_GPIO/gpio$sys_gpio/direction"
	echo out > "$SYSFS_GPIO/gpio$net_gpio/direction"
	echo 1 > "$net_value"
	sys_blink_pid=

	case "$sys_mode" in
		on)
			echo 0 > "$sys_value"
			;;
		blink)
			(
				while :; do
					echo 0 > "$sys_value"
					sleep "$sys_on"
					echo 1 > "$sys_value"
					sleep "$sys_off"
				done
			) &
			sys_blink_pid=$!
			;;
		off)
			echo 1 > "$sys_value"
			;;
		*)
			die "unknown FPT_S335_SYS_MODE '$sys_mode'"
			;;
	esac

	cleanup_net_watch() {
		if [ -n "${sys_blink_pid:-}" ]; then
			kill "$sys_blink_pid" 2>/dev/null || true
			wait "$sys_blink_pid" 2>/dev/null || true
		fi
		echo 1 > "$net_value" || true
		echo 0 > "$sys_value" || true
		exit 0
	}
	trap cleanup_net_watch INT TERM

	net_sample "$iface"
	last="$NET_SAMPLE"
	echo "watching $iface for Ethernet activity; sys mode=$sys_mode" >&2
	while :; do
		sleep "$poll"
		if ! net_sample "$iface"; then
			wait_for_iface "$iface"
			net_sample "$iface"
			last="$NET_SAMPLE"
			continue
		fi
		if [ "$NET_SAMPLE" != "$last" ]; then
			echo 0 > "$net_value"
			sleep "$pulse"
			echo 1 > "$net_value"
			last="$NET_SAMPLE"
		fi
	done
}

release_targets() {
	for led in $(expand_targets "${1:-all}"); do
		n="$(gpio_num "$led")"
		if [ -d "$SYSFS_GPIO/gpio$n" ]; then
			echo in > "$SYSFS_GPIO/gpio$n/direction"
			echo "$n" > "$SYSFS_GPIO/unexport"
			printf "released %-5s gpio%-3s %s\n" "$led" "$n" "$(pin_desc "$led")"
		else
			printf "released %-5s gpio%-3s already unexported\n" "$led" "$n"
		fi
	done
}

cmd="${1:-}"
case "$cmd" in
	status)
		status_targets "${2:-all}"
		;;
	on|off)
		set_targets "$cmd" "${2:-}"
		;;
	blink)
		blink_targets "${2:-}" "${3:-3}"
		;;
	net-watch)
		net_watch "${2:-}"
		;;
	demo)
		blink_targets candidates 2
		;;
	release)
		release_targets "${2:-all}"
		;;
	-h|--help|help|'')
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
esac
