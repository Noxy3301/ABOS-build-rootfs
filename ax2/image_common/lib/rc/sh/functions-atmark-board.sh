# SPDX-License-Identifier: MIT

KOTAI_CODE_OFFSET=56

UBOOT_ENVSD="/dev/mmcblk1"
UBOOT_ENVOFFSET="0x3fe000"
UBOOT_ENVREDUND="0x3fa000"
UBOOT_ENVSIZE="0x2000"

ext_board_eeprom_read() {
	# this errors when no ext_board: silence errors here.
	# convert from i2cget little endian to big endian
	i2cget -y 3 0x50 "$1" w 2>/dev/null \
		| sed -e 's/0x\(..\)\(..\)/0x\2\1/'
}

ext_board_is_atmark_techno() {
	# check vendor id is 0x0001 on big endian
	[ "$(ext_board_eeprom_read 0x00)" = 0x0001 ]
}

ext_board_is_lte() {
	# vendor id must be atmark techno and
	# product id is 0x0001 on big endian
	ext_board_is_atmark_techno \
		&& [ "$(ext_board_eeprom_read 0x02)" = 0x0001 ]
}

pci_is_aw_xm458() {
	[ "$(cat /sys/bus/pci/devices/0000:01:00.0/vendor 2>/dev/null)" = 0x1b4b ] \
		&& [ "$(cat /sys/bus/pci/devices/0000:01:00.0/device 2>/dev/null)" = 0x2b43 ]
}

board_setup() {
	# reset hwrevision even if it's already set:
	# we could be installing to a newer revision.
	[ -n "$SN" ] || SN=$(get_kotai_code)
	case "$SN" in
	00C6*) echo 'iot-g4-eva at1';;
	00C7*) echo 'iot-g4-es1 at1';;
	00C8*) echo 'iot-g4-es2 at1';;
	00C9*) echo 'AGX4500 at1';;
	00CB*) echo 'iot-g4-es3 at1';;
	00D1*) echo 'x2-es1 at1';;
	00D2*) echo 'x2-es2 at1';;
	00D3*) echo 'AX2210 at1';;
	*) echo 'unknown-board at1';;
	esac > /target/etc/hwrevision \
		|| error "Could not update /etc/hwrevision"


	if ext_board_is_lte; then
		echo "LTE extension board found"
		enable_overlay armadillo_iotg_g4-lte-ext-board.dtbo
		ln -sf /etc/init.d/connection-recover /target/etc/runlevels/default/ \
			|| error "could not enable connection-recover service"
		ln -sf /etc/init.d/wwan-safe-poweroff /target/etc/runlevels/shutdown/ \
			|| error "could not enable wwan-safe-poweroff service"
	fi

	if pci_is_aw_xm458; then
		echo "WLAN card found"
		enable_overlay armadillo_iotg_g4-aw-xm458.dtbo
	fi
}

