# FPT Playbox S335 LEDs

The Android firmware in `/mnt/android_extract/android_p212_1g.dts` contains the useful LED GPIO definitions:

```dts
blinkled {
	compatible = "sdmca, blinkled";
	status = "okay";
	blinkled_gpio = <0x19 0x05 0x00>;
};

gpioctrl {
	compatible = "sdmc, gpioctrl";
	status = "okay";
	sys_led = <0x18 0x49 0x00>;
	net_led = <0x19 0x09 0x01>;
};
```

In that same DTS, phandle `0x18` is the peripheral GPIO bank and phandle `0x19` is the AO GPIO bank. On the current Linux boot:

- peripheral bank base is sysfs GPIO `523`
- AO bank base is sysfs GPIO `512`
- `0x49` maps to peripheral pin 73, `GPIODV_24`, sysfs GPIO `596`
- `0x09` maps to AO pin 9, `GPIOAO_9`, sysfs GPIO `521`
- `0x05` maps to AO pin 5, `GPIOAO_5`, sysfs GPIO `517`

The two main controls are:

| LED | Android property | Pin | Linux sysfs GPIO | Polarity |
| --- | --- | --- | --- | --- |
| `sys` | `gpioctrl.sys_led` | `GPIODV_24` | `596` | active-low |
| `net` | `blinkled_gpio` | `GPIOAO_5` | `517` | active-low |

Visual testing on the S335 front panel confirmed that `sys` is the red LED and `net` is the white LED. `sys` is active-low on this board, even though the Android DTS GPIO flag is `0`. The Android `gpioctrl.net_led` property on `GPIOAO_9` / sysfs GPIO `521` toggles electrically but did not light the visible white LED.

The helper keeps `gpioctrl-net` as a diagnostic target for the Android `gpioctrl.net_led` GPIO, but the service uses `net` / GPIO517 for the front-panel white LED.

The current kernel has `CONFIG_LEDS_GPIO=y`, but the booted P212 device tree does not define these LEDs, so `/sys/class/leds` is empty. `CONFIG_OF_OVERLAY` is not enabled, so the immediate control path is sysfs GPIO.

## Use

Run as root:

```sh
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh status candidates
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh blink sys
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh blink net
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh demo
```

Set persistent states until reboot or release:

```sh
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh on sys
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh off net
/mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh release candidates
```

## Boot Service

The repro kit includes `fpt-s335-leds.service`. It does two things:

- blinks `sys` while the device is running
- watches the configured Ethernet interface and pulses `net` when RX/TX byte counters change

Default config:

```sh
FPT_S335_LED_IFACE=eth0
FPT_S335_LED_POLL=0.25
FPT_S335_LED_PULSE=0.25
FPT_S335_SYS_MODE=blink
FPT_S335_SYS_ON=1
FPT_S335_SYS_OFF=1
```

Install and start manually:

```sh
install -m 0755 /mnt/fpt-playbox-s335-wifi-repro/scripts/fpt-s335-leds.sh /usr/local/sbin/fpt-s335-leds.sh
install -m 0644 /mnt/fpt-playbox-s335-wifi-repro/configs/etc/default/fpt-s335-leds /etc/default/fpt-s335-leds
install -m 0644 /mnt/fpt-playbox-s335-wifi-repro/configs/etc/systemd/system/fpt-s335-leds.service /etc/systemd/system/fpt-s335-leds.service
systemctl daemon-reload
systemctl enable --now fpt-s335-leds.service
```

## Device Tree Option

For a future kernel/device-tree build, add a normal `gpio-leds` node instead of using sysfs GPIO:

```dts
leds {
	compatible = "gpio-leds";

	sys {
		label = "s335:sys";
		gpios = <&gpio 73 GPIO_ACTIVE_LOW>; /* GPIODV_24 */
		default-state = "keep";
	};

	net {
		label = "s335:net";
		gpios = <&gpio_ao 5 GPIO_ACTIVE_LOW>; /* GPIOAO_5 */
		default-state = "off";
	};
};
```

That should create LED class devices under `/sys/class/leds/` and allow standard LED triggers. It cannot be applied live on the current boot because runtime OF overlays are disabled.
