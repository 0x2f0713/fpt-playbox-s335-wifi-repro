#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KREL="$(uname -r)"

DEFAULT_ENV=/etc/default/wifi-ap.env
if [ -f "$DEFAULT_ENV" ]; then
    # shellcheck disable=SC1090
    . "$DEFAULT_ENV"
fi
if [ -z "${AP_SSID:-}" ] || [ -z "${AP_PSK:-}" ]; then
    install -d /etc/default
    if [ ! -e "$DEFAULT_ENV" ]; then
        install -m 0644 "$ROOT/configs/etc/default/wifi-ap.env.example" "$DEFAULT_ENV"
    fi
    echo "Set AP_SSID and AP_PSK in $DEFAULT_ENV or export them in the environment." >&2
    exit 1
fi

install_file() {
	src="$1"
	dst="$2"
	mode="$3"
	install -d "$(dirname "$dst")"
	if [ -e "$dst" ] && [ ! -e "$dst.before-fpt-playbox-wifi" ]; then
		cp -a "$dst" "$dst.before-fpt-playbox-wifi"
	fi
	install -m "$mode" "$src" "$dst"
}

install_file "$ROOT/configs/etc/dnsmasq.d/wifi-ap.conf" /etc/dnsmasq.d/wifi-ap.conf 0644
install_file "$ROOT/configs/etc/default/fpt-s335-leds" /etc/default/fpt-s335-leds 0644
install_file "$ROOT/configs/etc/systemd/system/wifi-ap-net.service" /etc/systemd/system/wifi-ap-net.service 0644
install_file "$ROOT/configs/etc/systemd/system/wifi-ap.service" /etc/systemd/system/wifi-ap.service 0644
install_file "$ROOT/configs/etc/systemd/system/wifi-dnsmasq.service" /etc/systemd/system/wifi-dnsmasq.service 0644
install_file "$ROOT/configs/etc/systemd/system/fpt-s335-leds.service" /etc/systemd/system/fpt-s335-leds.service 0644
install_file "$ROOT/configs/etc/modprobe.d/ath10k-fpt-playbox.conf" /etc/modprobe.d/ath10k-fpt-playbox.conf 0644
install_file "$ROOT/configs/etc/modules-load.d/ath10k_sdio.conf" /etc/modules-load.d/ath10k_sdio.conf 0644
install_file "$ROOT/configs/etc/sysctl.d/90-fpt-playbox-ap.conf" /etc/sysctl.d/90-fpt-playbox-ap.conf 0644
install_file "$ROOT/configs/usr/local/sbin/wifi-ap-net.sh" /usr/local/sbin/wifi-ap-net.sh 0755
install_file "$ROOT/scripts/fpt-s335-leds.sh" /usr/local/sbin/fpt-s335-leds.sh 0755

install -d /etc/default
if [ ! -e /etc/default/wifi-ap.env ]; then
	install -m 0644 "$ROOT/configs/etc/default/wifi-ap.env.example" /etc/default/wifi-ap.env
fi

cat > /etc/hostapd/wifi-ap.conf <<EOF
interface=wlan0
driver=nl80211
ctrl_interface=/run/hostapd
ctrl_interface_group=0
logger_syslog=-1
logger_syslog_level=0

ssid=$AP_SSID
country_code=US
ieee80211d=1
hw_mode=a
channel=149

ieee80211n=1
ieee80211ac=1
wmm_enabled=1
uapsd_advertisement_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40][LDPC][RX-STBC1][MAX-AMSDU-7935]
vht_capab=[MAX-MPDU-11454][RXLDPC][SHORT-GI-80][TX-STBC-2BY1][SU-BEAMFORMEE][MU-BEAMFORMEE]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155

auth_algs=1
ignore_broadcast_ssid=0
eapol_version=2
wpa=2
wpa_passphrase=$AP_PSK
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
ieee80211w=0
EOF

install_file "$ROOT/firmware/ath10k/QCA6174/hw3.0/board.bin" /usr/lib/firmware/ath10k/QCA6174/hw3.0/board.bin 0644
install_file "$ROOT/firmware/ath10k/QCA6174/hw3.0/firmware-sdio-6.bin" /usr/lib/firmware/ath10k/QCA6174/hw3.0/firmware-sdio-6.bin 0644

if [ "$KREL" = "6.18.35-current-meson64" ]; then
	install_file "$ROOT/kernel/prebuilt/$KREL/ath.ko" "/lib/modules/$KREL/kernel/drivers/net/wireless/ath/ath.ko" 0644
	depmod "$KREL"
else
	echo "No prebuilt ath.ko for $KREL; apply kernel/ath-regd-qca6174-sdio-channel149.patch and rebuild ath.ko." >&2
fi

systemctl daemon-reload
sysctl -w net.ipv4.ip_forward=1 >/dev/null
systemctl enable wifi-ap-net.service wifi-ap.service wifi-dnsmasq.service fpt-s335-leds.service
systemctl restart wifi-ap-net.service
systemctl restart wifi-ap.service
systemctl restart wifi-dnsmasq.service
systemctl restart fpt-s335-leds.service

hostapd_cli -i wlan0 status || true
