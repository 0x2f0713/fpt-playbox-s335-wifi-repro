# FPT Playbox S335 WiFi/AP Reproduction Kit

This repo contains the files needed to reproduce the working WiFi/AP setup on the FPT Playbox S335 / SDMC DV8236 with the CDTech 4761743 QCA6174 SDIO module.

Final verified state:
- SSID: `<redacted>`
- Password: `<redacted>`
- Band/channel: 5 GHz channel 149, 5745 MHz, VHT80 centered at 5775 MHz
- AP IP: `10.70.2.1/24`
- DHCP: `10.70.2.50` to `10.70.2.150`
- Uplink: `eth0`

## Contents

- `configs/`: hostapd, dnsmasq, systemd, modprobe, module-load, sysctl, and AP NAT script.
- `firmware/`: QCA6174 SDIO firmware and Android board data known to work on this board.
- `kernel/ath-regd-qca6174-sdio-channel149.patch`: source patch for the Atheros regulatory module.
- `kernel/prebuilt/6.18.35-current-meson64/ath.ko`: patched module built for `6.18.35-current-meson64`.
- `docs/fpt-playbox-s335-wifi-ap.md`: full repair/debug notes.
- `scripts/install-current-kernel.sh`: install the captured working setup on this same kernel.

## Install On Same Kernel

Run as root:

```sh
./scripts/install-current-kernel.sh
```

The script installs firmware/configs, installs the prebuilt patched `ath.ko` only when `uname -r` is `6.18.35-current-meson64`, reloads systemd, enables services, and restarts the AP.

## Rebuild Patched `ath.ko`

For a different kernel, apply the patch to that kernel source tree and rebuild the Atheros wireless module:

```sh
cd /path/to/linux-source
patch -p1 < /mnt/fpt-playbox-s335-wifi-repro/kernel/ath-regd-qca6174-sdio-channel149.patch
make M=drivers/net/wireless/ath -j2 KBUILD_MODPOST_WARN=1 modules
install -m 0644 drivers/net/wireless/ath/ath.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath.ko
depmod $(uname -r)
```

Then rerun:

```sh
systemctl restart wifi-ap-net.service wifi-ap.service wifi-dnsmasq.service
```

## Verify

```sh
hostapd_cli -i wlan0 status
hostapd_cli -i wlan0 all_sta
cat /var/lib/misc/dnsmasq.leases
iptables -t nat -vnL POSTROUTING
iptables -vnL FORWARD
```

Expected evidence:
- `state=ENABLED`
- `freq=5745`
- `channel=149`
- `ieee80211n=1`, `ieee80211ac=1`, `vht_oper_chwidth=1`
- `iw dev wlan0 info` shows `width: 80 MHz`
- capable stations have `[AUTH][ASSOC][AUTHORIZED][WMM][HT][VHT]`
- dnsmasq has a `10.70.2.x` lease
- NAT/FORWARD counters increase for `wlan0` and `eth0`
