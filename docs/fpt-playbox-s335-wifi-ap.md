# FPT Playbox S335 / SDMC DV8236 WiFi AP Fix

Device:
- FPT Playbox S335, board marked SDMC DV8236.
- WiFi module marking: CDTech 4761743.
- Kernel during repair: `6.18.35-current-meson64`.
- Confirmed SDIO ID: `sdio:c00v0271d050A`.
- Confirmed chip from ath10k: `qca6174 hw3.2 sdio target 0x05030000`.

Final result:
- SSID: `<redacted>`
- Password: `<redacted>`
- Band/channel: 5 GHz channel 149, 5745 MHz, VHT80 centered at 5775 MHz
- AP address: `10.70.2.1/24`
- DHCP range: `10.70.2.50` to `10.70.2.150`
- Uplink/NAT interface: `eth0`

## Final Working Driver Path

The final working setup uses the upstream QCA6174 SDIO ath10k firmware with hardware crypto:

```text
/usr/lib/firmware/ath10k/QCA6174/hw3.0/firmware-sdio-6.bin
```

The firmware reports:

```text
firmware ver WLAN.RMH.4.4.1-00174 api 6 features wowlan,ignore-otp,mfp
htt-ver 3.87 ... raw 0 hwcrypto 1
```

The board data is the Android `bdwlan30.bin` copied as:

```text
/usr/lib/firmware/ath10k/QCA6174/hw3.0/board.bin
```

The ath10k module options are:

```text
/etc/modprobe.d/ath10k-fpt-playbox.conf
options ath10k_core cryptmode=0 frame_mode=1
```

This is required for the official SDIO firmware. Do not use `cryptmode=1` with `firmware-sdio-6.bin`; that firmware does not advertise raw-mode support.

## Regulatory Patch

The official SDIO firmware works for WPA, but this board's EEPROM reports Atheros regdomain `0x6c`. The stock `ath.ko` maps that to PHY country `99` with all 5 GHz channels marked `NO-IR`, so hostapd cannot start a 5 GHz AP even after `iw reg set US`.

The fix was a small local patch in:

```text
/mnt/linux-6.18.35/drivers/net/wireless/ath/regd.c
```

For `ath_world_regdom_67_68_6A_6C`, the upper 5 GHz range was split so only the U-NII-3 range containing channel 149 is active:

```c
#define ATH_5GHZ_5470_5725     REG_RULE(5470-10, 5725+10, 80, 0, 30,\
                                         NL80211_RRF_NO_IR)
#define ATH_5GHZ_5725_5850_AP  REG_RULE(5725-10, 5850+10, 80, 0, 30, 0)
```

The patched module was built with:

```sh
make -C /mnt/linux-6.18.35 M=drivers/net/wireless/ath -j2 KBUILD_MODPOST_WARN=1 modules
```

Installed module:

```text
/lib/modules/6.18.35-current-meson64/kernel/drivers/net/wireless/ath/ath.ko
```

Backup of the stock module:

```text
/lib/modules/6.18.35-current-meson64/kernel/drivers/net/wireless/ath/ath.ko.stock-before-fpt-regd
```

After installing the patched module, `depmod 6.18.35-current-meson64` was run.

Expected channel check:

```sh
iw reg set US
iw phy phy0 info | grep '5745.0 MHz'
```

Expected output:

```text
* 5745.0 MHz [149] (30.0 dBm)
```

There should be no `(no IR)` marker on channel 149.

## Throughput Profile

The AP was originally kept in legacy 802.11a mode while debugging WPA failures. After switching to the official SDIO firmware with hardware crypto, hostapd was tuned for throughput:

```text
country_code=US
ieee80211d=1
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
uapsd_advertisement_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40][LDPC][RX-STBC1][MAX-AMSDU-7935]
vht_capab=[MAX-MPDU-11454][RXLDPC][SHORT-GI-80][TX-STBC-2BY1][SU-BEAMFORMEE][MU-BEAMFORMEE]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155
```

`iw dev wlan0 info` should report an 80 MHz AP channel. Capable clients should show `[WMM][HT][VHT]` in `hostapd_cli -i wlan0 all_sta`. Legacy clients may still connect, but they will not get VHT rates and can reduce airtime efficiency.

## AP Services

Files:

```text
/etc/hostapd/wifi-ap.conf
/etc/dnsmasq.d/wifi-ap.conf
/usr/local/sbin/wifi-ap-net.sh
/etc/systemd/system/wifi-ap-net.service
/etc/systemd/system/wifi-ap.service
/etc/systemd/system/wifi-dnsmasq.service
```

The AP network script now sets the regulatory country before bringing `wlan0` up:

```sh
iw reg set "$REG_DOMAIN"
```

Default `REG_DOMAIN` is `US`. Change this only if the target country allows the chosen channel.

Services are enabled:

```sh
systemctl is-enabled wifi-ap-net.service
systemctl is-enabled wifi-ap.service
systemctl is-enabled wifi-dnsmasq.service
```

Restart AP:

```sh
systemctl restart wifi-ap-net.service
systemctl restart wifi-ap.service
systemctl restart wifi-dnsmasq.service
```

## Verification From Working Run

Hostapd:

```text
wlan0: AP-ENABLED
freq=5745
channel=149
ieee80211n=1
ieee80211ac=1
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155
ssid[0]=REDACTED
```

Radio width:

```text
channel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz
```

Client connection:

```text
STA <redacted-mac> WPA: received EAPOL-Key frame (2/4 Pairwise)
STA <redacted-mac> WPA: received EAPOL-Key frame (4/4 Pairwise)
EAPOL-4WAY-HS-COMPLETED <redacted-mac>
```

DHCP:

```text
DHCPREQUEST(wlan0) 10.70.2.100 <redacted-mac>
DHCPACK(wlan0) 10.70.2.100 <redacted-mac> iPhone
```

Station state:

```text
flags=[AUTH][ASSOC][AUTHORIZED]
authorized: yes
```

NAT rules:

```sh
iptables -t nat -S POSTROUTING | grep 10.70.2.0/24
iptables -S FORWARD | grep wlan0
```

Expected:

```text
-A POSTROUTING -s 10.70.2.0/24 -o eth0 -j MASQUERADE
-A FORWARD -i wlan0 -o eth0 -j ACCEPT
-A FORWARD -i eth0 -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

## OpenWrt QCA6174 Test Result

OpenWrt package checked:

```text
ath10k-firmware-qca6174_20241110-r2_aarch64_cortex-a53.ipk
```

References checked:

```text
https://downloads.openwrt.org/releases/24.10.2/packages/aarch64_cortex-a53/base/ath10k-firmware-qca6174_20241110-r2_aarch64_cortex-a53.ipk
https://git.openwrt.org/openwrt/openwrt/plain/package/firmware/linux-firmware/qca_ath10k.mk?h=openwrt-24.10
https://git.openwrt.org/openwrt/openwrt/plain/package/firmware/linux-firmware/qca_ath10k.mk?h=openwrt-25.12
```

OpenWrt 24.10 and 25.12 package recipes install:

```text
ath10k/QCA6174/hw3.0/board-2.bin
ath10k/QCA6174/hw3.0/firmware-6.bin
```

They do not install `firmware-sdio-6.bin` for this SDIO board.

`board-2.bin` was tested and does not contain a matching entry for this board:

```text
bus=sdio,vendor=0271,device=050a,subsystem-vendor=0000,subsystem-device=0000
```

It was kept disabled as:

```text
/usr/lib/firmware/ath10k/QCA6174/hw3.0/board-2.bin.openwrt-test-no-sdio-match
```

Renaming OpenWrt `firmware-6.bin` to `firmware-sdio-6.bin` was also tested. It reported:

```text
firmware ver WLAN.RM.4.4.1-00309- api 6
```

but failed on SDIO:

```text
failed to write to address 0x828: -110
could not start HIF: -110
could not probe fw (-110)
```

The original `firmware-sdio-6.bin` was restored afterward.

## Earlier Android Firmware Test

The Android OTA was extracted from:

```text
/mnt/s905x-p212-dv8236-FPT-v6.7.92-1808071837.zip
```

Useful extracted files are preserved in:

```text
/mnt/android_extract/qca6174_wifi/
/usr/lib/firmware/ath10k/QCA6174/hw3.0/android-source/
```

Files:

```text
athwlan.bin
qwlan30.bin
bdwlan30.bin
otp30.bin
wlan/qcom_cfg.ini
wlan/cfg.dat
```

An Android raw-mode ath10k wrapper was built as `firmware-sdio-5.bin`. It allowed hostapd to start on 5 GHz channel 149, but encrypted clients failed the WPA 4-way handshake:

```text
WPA: sending 1/4 msg of 4-Way Handshake
WPA: EAPOL-Key timeout
PTKSTART: Retry limit 4 reached
```

An open AP test also showed DHCP offer traffic not completing. That path was abandoned after the official SDIO firmware plus patched `ath.ko` completed WPA and DHCP.

## qcacld-2.0 Status

`qcacld-2.0` was built far enough to produce `wlan.ko` for this SDIO ID:

```text
alias: sdio:c*v0271d050A*
```

Firmware/config staged for qcacld:

```text
/usr/lib/firmware/wlan/qcom_cfg.ini
/usr/lib/firmware/wlan/cfg.dat
/usr/lib/firmware/qwlan30.bin
/usr/lib/firmware/bdwlan30.bin
/usr/lib/firmware/otp30.bin
/usr/lib/firmware/utf30.bin
/usr/lib/firmware/athwlan.bin
```

It reached WMI service-ready on one run, but later failed with BMI timeouts. Because ath10k now works, qcacld is not used in the final setup.

## Recovery Commands

Reload WiFi after a bad firmware test:

```sh
systemctl stop wifi-ap.service wifi-dnsmasq.service wifi-ap-net.service
printf d0070000.mmc > /sys/bus/platform/drivers/meson-gx-mmc/unbind
modprobe -r ath10k_sdio ath10k_core ath mac80211 cfg80211 libarc4
modprobe ath10k_core cryptmode=0 frame_mode=1
modprobe ath10k_sdio
printf d0070000.mmc > /sys/bus/platform/drivers/meson-gx-mmc/bind
systemctl restart wifi-ap-net.service wifi-ap.service wifi-dnsmasq.service
```

Check the live firmware path:

```sh
journalctl -k --since '5 minutes ago' --no-pager | grep -Ei 'ath10k|firmware|htt-ver|regdomain'
for p in /sys/module/ath10k_core/parameters/cryptmode /sys/module/ath10k_core/parameters/frame_mode; do
    printf '%s=' "$(basename "$p")"
    cat "$p"
done
```

Expected:

```text
cryptmode=0
frame_mode=1
raw 0 hwcrypto 1
```

If a kernel package update replaces `ath.ko`, rebuild and reinstall the patched module from `/mnt/linux-6.18.35` or reapply the same `regd.c` patch to the new kernel source.
