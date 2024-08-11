# SPDX-License-Identifier: MIT

KOTAI_CODE_OFFSET=40

UBOOT_ENVSD="/dev/mmcblk1"
UBOOT_ENVOFFSET="0x1fe000"
UBOOT_ENVREDUND="0x1fa000"
UBOOT_ENVSIZE="0x2000"

is_at_dtweb_dtbo_applied() {
	local overlays=/target/boot/overlays.txt

	[ -e "$overlays" ] || return 1

	grep -E '^fdt_overlays=' "$overlays" 2>/dev/null \
		| grep -Eq 'armadillo-640-at-dtweb\.dtbo|armadillo-610-at-dtweb\.dtbo'
}

board_setup() {
	# reset hwrevision even if it's already set:
	# we could be installing to a newer revision.
	[ -n "$SN" ] || SN=$(get_kotai_code)
	# note ${SN:x:y} is not posix but works on busybox ash/mksh
	case "${SN:0:4}" in
	0097|009C) echo 'a640 at1';;
	00B4|00B7) echo 'a610 at1';;
	*) echo 'unknown-board at1';;
	esac > /target/etc/hwrevision \
		|| error "Could not update /etc/hwrevision"

	if [ -n "$LED" ]; then
		sed -i -e 's#/sys/class/leds/yellow#/sys/class/leds/'"$LED"'#g' \
				/target/etc/atmark/baseos.conf \
			|| error "Could not update baseos.conf"
	fi

	# append dtbos if at-dtweb.dtbo is not applied.
	# at-dtweb.dtbo may contain the following dtbos and should be
	# applied alone.
	if ! is_at_dtweb_dtbo_applied; then
		case "${SN:0:4}" in
		0097|009C) # a640
			enable_overlay armadillo-640-lcd70ext-l00.dtbo
			# lwb5+ usb id
			if lsusb | grep -q 04b4:640c; then
				enable_overlay armadillo-640-con9-thread-lwb5plus.dtbo
			fi
			;;
		00B4|00B7) # a610
			enable_overlay armadillo-610-extboard-eva.dtbo
			enable_overlay armadillo-640-lcd70ext-l00.dtbo
			;;
		esac
	fi

	if [ -e "${DISK}boot0" ]; then
		# eMMC
		local ret

		# enable micron emmc self refresh function
		#  self refresh: enable
		#  self refresh rtc: used
		#  delay1: 60 sec
		#  delay2: 100 msec
		# set bkops manual
		emmc-sref --setup "$DISK"
		ret=$?

		case "$ret" in
		0) ;;
		1) error "Could not enable self refresh function" ;;
		2) ;; # not supported eMMC version. ignore for a640.
		esac
	fi
}
