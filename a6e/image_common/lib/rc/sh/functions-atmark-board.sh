# SPDX-License-Identifier: MIT

KOTAI_CODE_OFFSET=40

UBOOT_ENVSD="/dev/mmcblk1"
UBOOT_ENVOFFSET="0x3fe000"
UBOOT_ENVREDUND="0x3fa000"
UBOOT_ENVSIZE="0x2000"

base_board_eeprom_read() {
	# convert from i2cget little endian to big endian
	i2cget -y 1 0x50 "$1" w \
		| sed -e 's/0x\(..\)\(..\)/0x\2\1/'
}

base_board_is_atmark_techno() {
	case "$(base_board_eeprom_read 0x00)" in
	"") error "eeprom could not be read";;
	0xffff) error "eeprom is not initialized, please setup it.";;
	0x0001) return 0;;
	esac
	# not atmark techno
	return 1
}

base_board_read_product_id() {
	base_board_eeprom_read 0x02
}

base_board_read_revision() {
	base_board_eeprom_read 0x0A
}

enable_overlay_lwb5plus() {
    if [ -n "$sd_boot" ]; then
       print_red "ERROR: SD boot cannnot be used because lwb5plus is present"
       fw_setenv -- bootdelay -1
    fi
    enable_overlay armadillo-iotg-a6e-lwb5plus.dtbo
}

board_setup() {
	if ! base_board_is_atmark_techno; then
		echo 'unknown-board at1' > /target/etc/hwrevision \
			|| error "Could not udpate /etc/hwrevision"
		return 0
	fi

	[ -n "$SN" ] || SN=$(get_kotai_code)
	case "$SN" in
	00B7*) ;; # a6e-es1/a610
	00CD*) ;; # a6e-es2
	00CE*) ;; # a6e (LTE Cat.M & WLAN)
	00CF*) ;; # a6e-es (LTE Cat.M)
	00D0*) ;; # a6e (LTE Cat.M)
	00D5*) ;; # a6e-es (LAN only)
	00D6*) ;; # a6e (LAN only)
	00D7*) ;; # a6e-es (LTE Cat.1 & WLAN)
	00D8*) ;; # a6e (LTE Cat.1 & WLAN)
	00D9*) ;; # a6e (WLAN)
	00DA*) ;; # a6e (LTE Cat.1)
	*)
		echo 'unknown-board at1' > /target/etc/hwrevision \
			|| error "Could not udpate /etc/hwrevision"
		return 0
		;;
	esac
	local board="$(base_board_read_revision)"
	echo "board = $board"
	case "$board" in
	"") error "eeprom could not be read (revision)";;
	0xffff) error "eeprom revision is not initialized";;
	0x0001) echo 'iot-a6e-es1 at1';;
	0x0002) echo 'iot-a6e-es2 at1';;
	0x0003) echo 'iot-a6e at1';;
	*) echo 'unknown-board at1';;
	esac > /target/etc/hwrevision \
		|| error "Could not update /etc/hwrevision"

	local product_id="$(base_board_read_product_id)"
	echo "product_id = $product_id"
	case "$product_id" in
	"") error "eeprom could not be read (product_id)";;
	0xffff) error "eeprom product_id is not initialized";;
	0x0000) echo "WARNING: product_id 0x0000 is reserved";;
	0x0001)
		echo "EMS31 exists"
		enable_overlay armadillo-iotg-a6e-ems31.dtbo
		ln -sf /etc/init.d/ems31-boot /target/etc/runlevels/boot/ \
			|| error "Could not enable ems31-boot service"
		ln -sf /etc/init.d/wwan-led /target/etc/runlevels/default/ \
			|| error "Could not enable wwan-led service"
		ln -sf /etc/init.d/wwan-safe-poweroff /target/etc/runlevels/shutdown/ \
			|| error "Could not enable wwan-safe-poweroff service"
		;;
	0x0002)
		echo "EMS31 & lwb5plus exists"
		enable_overlay armadillo-iotg-a6e-ems31.dtbo
		enable_overlay_lwb5plus
		ln -sf /etc/init.d/ems31-boot /target/etc/runlevels/boot/ \
			|| error "Could not enable ems31-boot service"
		ln -sf /etc/init.d/wwan-led /target/etc/runlevels/default/ \
			|| error "Could not enable wwan-led service"
		ln -sf /etc/init.d/wwan-safe-poweroff /target/etc/runlevels/shutdown/ \
			|| error "Could not enable wwan-safe-poweroff service"
		;;
	0x0003)
		echo "ELS31 exists"
		enable_overlay armadillo-iotg-a6e-els31.dtbo
		ln -sf /etc/init.d/connection-recover /target/etc/runlevels/default/ \
			|| error "Could not enable connection-recover service"
		ln -sf /etc/init.d/modemmanager /target/etc/runlevels/boot/ \
			|| error "Could not enable modemmanager service"
		ln -sf /etc/init.d/wwan-led /target/etc/runlevels/default/ \
			|| error "Could not enable wwan-led service"
		ln -sf /etc/init.d/wwan-safe-poweroff /target/etc/runlevels/shutdown/ \
			|| error "Could not enable wwan-safe-poweroff service"
		;;
	0x0004)
		echo "ELS31 & lwb5plus exists"
		enable_overlay armadillo-iotg-a6e-els31.dtbo
		enable_overlay_lwb5plus
		ln -sf /etc/init.d/connection-recover /target/etc/runlevels/default/ \
			|| error "Could not enable connection-recover service"
		ln -sf /etc/init.d/modemmanager /target/etc/runlevels/boot/ \
			|| error "Could not enable modemmanager service"
		ln -sf /etc/init.d/wwan-led /target/etc/runlevels/default/ \
			|| error "Could not enable wwan-led service"
		ln -sf /etc/init.d/wwan-safe-poweroff /target/etc/runlevels/shutdown/ \
			|| error "Could not enable wwan-safe-poweroff service"
		;;
	0x0005)
		echo "LAN model"
		;;
	0x0006)
		echo "lwb5plus exists"
		enable_overlay_lwb5plus
		;;
	*)	echo "WARNING: unknown product_id: $product_id";;
	esac
}
