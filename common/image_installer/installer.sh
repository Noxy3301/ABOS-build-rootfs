#!/bin/sh
# SPDX-License-Identifier: MIT

led_on() {
	[ -n "$LED" ] || return
	echo none > "/sys/class/leds/$LED/trigger"
	echo 255 > "/sys/class/leds/$LED/brightness"
}

led_off() {
	[ -n "$LED" ] || return
	echo none > "/sys/class/leds/$LED/trigger"
	echo 0 > "/sys/class/leds/$LED/brightness"
}

led_heartbeat() {
	[ -n "$LED" ] || return
	echo heartbeat > "/sys/class/leds/$LED/trigger"
}

image_log() {
	# also log dumped firm checksum if no new one
	local firm=/tmp/firm.squashfs.xxh
	[ -e "/firm.squashfs.xxh" ] && firm=/firm.squashfs.xxh

	echo "$(cat /boot.filename) $(cat /boot.xxh)"
	echo "$(cat /image.filename) $(cat /image.xxh)"
	[ -e "$firm" ] && echo "firm $(cat "$firm")"
	[ -e /appfs.xxh ] && echo "appfs $(cat /appfs.xxh)"
	[ -e /installer.conf ] && echo "installer.conf $(xxhsum < /installer.conf | cut -d' ' -f1)"
	[ -e "$overrides" ] && echo "$overrides $(xxhsum < "$overrides" | cut -d' ' -f1)"
	[ -n "$swu_hashs" ] && echo "$swu_hashs"
	[ -e /tmp/sw-versions ] && cat /tmp/sw-versions
}

gen_log() {
	echo "RESULT:$RESULT"
	image_log
	printf "ERROR:%s\n" "$@"
	cat /tmp/install.log
}

gen_and_send_log() {
	local RESULT

	RESULT="$1"
	shift

	gen_log "$@" > /tmp/upload.log

	if command -v send_log >/dev/null \
	   && ! send_log /tmp/upload.log; then
		echo "send_log: failed to upload log."
		echo "send_log: cancelling reboot/poweroff for debugging."
		echo "send_log: /tmp/install.log contains all logs"

		led_heartbeat

		# override gen_and_send_log() to cancel calling
		# gen_and_send_log() in error()
		gen_and_send_log() { :; }
		error "could not send log"
	fi

	if [ "$RESULT" = "OK" ]; then
		led_on
	else
		led_off
	fi
}

checksum() {
	local device="$1" cksum_file="$2"
	local sz xxh_check xxh_written

	[ -e "$cksum_file" ] || return

	read -r sz xxh_check < "$cksum_file"
	xxh_written="$(dd if="$device" bs=1M count="$sz" status=none \
			iflag=direct,count_bytes,fullblock status=none | xxhsum)"
	xxh_written="${xxh_written%% *}"
	[ "$xxh_written" = "$xxh_check" ] \
		|| error "image in $device does not match expected checksum (expected $xxh_check, got $xxh_written)"
	print_green "ok"
}

btrfs_resnapshot() {
	local src="$1"
	local dst="$2"

	[ -e "/mnt/$dst" ] && btrfs -q subvolume delete "/mnt/$dst"
	btrfs -q subvolume snapshot "/mnt/snapshots/$src" "/mnt/$dst" \
		|| error "Creating snapshot failed"
	btrfs -q subvolume delete "/mnt/snapshots/$src"
}

restore_appfs() {
	mount -t btrfs "$appdev" "/mnt" \
		|| error "Could not mount appfs"
	[ -d "/mnt/snapshots" ] || mkdir /mnt/snapshots \
		|| error "Could not make modify appfs: readonly?"

	# We cannot check xxh after the fact like other dd'd images.
	# We could check while streaming by using tee like when we make
	# the image but btrfs has its own checksums so let's trust it
	lzopcat /appfs.lzo |
			btrfs receive /mnt/snapshots \
		|| error "Could not restore btrfs subvolumes"

	btrfs_resnapshot volumes volumes
	btrfs_resnapshot boot_volumes boot_0/volumes
	btrfs_resnapshot boot_containers_storage boot_0/containers_storage

	# optional switch-storage disk volume
	[ -e "/mnt/snapshots/containers_storage" ] \
		&& btrfs_resnapshot containers_storage containers_storage

	find /mnt/snapshots -xdev -delete

	# we trust btrfs to check on reading, but not the emmc:
	# verify consistency
	sync
	echo 3 > /proc/sys/vm/drop_caches
	umount /mnt
	btrfs check --check-data-csum --readonly "$appdev" \
		|| error "btrfs check failed after restoring appfs"
}

installer_dump_firmware() {
	# mostly same as abos-ctrl make-installer
	local size dev="${DISKPART}4"
	luks_unlock "${dev##*/}"

	# we can get the squashfs size through df to not copy too many useless trailing data
	# skip if not squashfs or not mountable
	if [ "$(head -c 4 "$dev")" != "hsqs" ] \
	    || ! mount -t squashfs "$dev" /opt/firmware >/dev/null 2>&1; then
		[ "${dev#/dev/mapper}" = "$dev" ] || cryptsetup close "${dev##*/}"
		return
	fi
	size=$(findmnt -nr --bytes -o SIZE /opt/firmware)
	# note: update max size if partition layout changes
	if [ -n "$size" ] && [ "$size" -le "$((200*1024*1024))" ]; then
		dd if="$dev" of=/tmp/firm.squashfs bs=1M count="$size" iflag=count_bytes status=none \
			|| error "Could not backup firm from mmc"
		xxhsum /tmp/firm.squashfs | sed -e 's/ .*//' > /tmp/firm.squashfs.xxh
	fi
	umount /opt/firmware
	[ "${dev#/dev/mapper}" = "$dev" ] || cryptsetup close "${dev##*/}"
}

workaround_ax2_mmc() {
	# older firmware for Armadillo X2/IoT G4 can brick the MMC if power is lost
	# while writing to boot partitions with >= 16KB blocks: limit to 8KB if required.
	[ "$(cat "/sys/class/block/${DISK#/dev/}/device/name" 2>/dev/null)" = G1M15L ] || return
	# affected version: ECQT00HS
	[ "$(cat "/sys/class/block/${DISK#/dev/}/device/fwrev")" = 0x4543515430304853 ] || return

	echo 8 > "/sys/class/block/${DISK#/dev/}boot0/queue/max_sectors_kb"
	echo 8 > "/sys/class/block/${DISK#/dev/}boot1/queue/max_sectors_kb"
}

write_check_boot() {
	# skip if no boot image
	[ -e "/boot.lzo" ] || return

	printf "Writing boot loader... "

	workaround_ax2_mmc

	# no boot partition = error. Eventually add qemu or other loader support?
	[ -e "${DISK}boot0" ] || error "${DISK}boot0 not found"

	if ! echo 0 > /sys/block/"${DISK#/dev/}"boot0/force_ro \
	    || ! lzopcat /boot.lzo | dd of="${DISK}boot0" bs=1M conv=fsync status=none; then
		echo 1 > /sys/block/"${DISK#/dev/}"boot0/force_ro
		error "Could not copy boot over"
	fi
	if [ -n "$ENCRYPT_ROOTFS" ] \
	    && ! dd if=/boot/Image of="${DISK}boot0" bs=1M seek=5 conv=fsync status=none; then
		# XXX allow using different image and check it looks like FIT
		echo 1 > /sys/block/"${DISK#/dev/}"boot0/force_ro
		error "Could not copy linux image for encrypted rootfs"
	fi
	echo 1 > /sys/block/"${DISK#/dev/}"boot0/force_ro

	if echo 0 > /sys/block/"${DISK#/dev/}"boot1/force_ro 2>/dev/null; then
		# for imx6ull, trying to boot from the wrong disk without bootloader
		# would brick a remote armadillo so copy u-boot just in case.
		lzopcat /boot.lzo | dd of="${DISK}boot1" bs=1M conv=fsync status=none \
			|| error "Could not copy boot to B-side"
		echo 1 > /sys/block/"${DISK#/dev/}"boot1/force_ro
		# don't print ok, but fail on error
		checksum "${DISK}boot1" "/boot.xxh" >/dev/null
	fi

	checksum "${DISK}boot0" "/boot.xxh"

	# make sure board boots on first partition
	mmc bootpart enable 1 0 "$DISK" \
		|| error "Could not set boot partition"
	mmc extcsd read "$DISK" | grep -q 'PARTITION_CONFIG: 0x08' \
		|| error "PARTITION_CONFIG was not set properly after setting bootpart" \
			"$(mmc extcsd read "$DISK" | grep PARTITION_CONFIG)"
}

install() {
	local DISK="" DISKPART="" SD="" LED="" loop="" dev
	local REBOOT="" USER_MOUNT="" BLKDISCARD="" SN
	local overrides="/installer_overrides.sh"
	local swu_hashs="" hwpart

	echo
	echo
	echo "Starting image installer script"
	echo

	# run common hooks
	. /lib/rc/sh/functions-atmark.sh

	firstboot_setup

	# log stdout/stderr to /tmp/install.log while keeping a copy to console
	mkfifo /tmp/.installer-log-fifo
	tee < /tmp/.installer-log-fifo /dev/console > /tmp/install.log &
	exec > /tmp/.installer-log-fifo 2>&1

	# source common functions and init env
	[ -e /installer.conf ] || error "/installer.conf not found, refusing to install"
	. /installer.conf
	[ -n "$DISK" ] || error "mandatory DISK variable was not set in installer.conf"
	[ -z "$DISKPART" ] && DISKPART="${DISK}p"
	if [ -z "$SD" ]; then
		SD=$(sed -ne 's/.*root=\([^ ]*\).*/\1/p' < /proc/cmdline)
		[ -e "$SD" ] || SD="$(findfs "$SD")"
		SD="${SD%[12]}"
		SD="${SD%p}"
	fi
	[ -z "$SDPART" ] && SDPART="${SD}p"

	# Override hooks. second partition's 'installer_overrides.sh' and
	# swus with the same path are preferred over main one if both exist
	if [ -e "${SDPART}2" ]; then
		local mount
		# check if abos-ctrl has the mount verb
		# To remove in first 3.20 release
		if abos-ctrl --help | grep -qw 'mount:'; then
			mount="abos-ctrl mount"
		else
			# adding exfat to /etc/filesystems makes busybox mount
			# try to mount as exfat even if module is not loaded;
			# but this will print errors in dmesg if not exfat so
			# prefer abos-ctrl mount if available.
			echo exfat > /etc/filesystems
			mount="mount"
		fi
		if $mount "${SDPART}2" /mnt; then
			USER_MOUNT=/mnt
			[ -e "/mnt$overrides" ] && overrides="/mnt$overrides"
		fi
	fi

	if [ -e "$overrides" ]; then
		. "$overrides"
	fi

	grep -q reboot /proc/cmdline && REBOOT="rebooting"
	SN=$(get_kotai_code) && [ "$SN" != "000000000000" ] \
		|| echo "Could not read serial number"

	# preinstall hook
	if command -v preinstall >/dev/null; then
		echo "Running preinstall command"
		preinstall
	fi

	# if rootfs size or encryption setting changes we'd lose
	# firmware partition. Try to recover it if missing.
	if ! [ -e "/firm.squashfs" ] && [ -e "${DISKPART}4" ]; then
		installer_dump_firmware
	fi

	# reset eMMC
	if [ "$BLKDISCARD" = yes ]; then
		printf "Erasing eMMC data... "
		for hwpart in "$DISK" "$DISK"gp*; do
			[ -e "$hwpart" ] || continue
			blkdiscard "$hwpart" || error "Could not discard $hwpart"
		done
		print_green "ok"
	fi

	# install image and bootloader
	local sz
	read -r sz _ < /image.xxh \
		|| error "image checksum file not found"

	# partition encryption has a 1MB overhead
	[ -n "$ENCRYPT_ROOTFS" ] && sz=$((sz + 1024*1024))

	# we build partition table in two steps: only create first partition here
	# to be in the same state as sd card image for common atmark-function setup
	# we zap and ignore error in a different command because a broken GPT
	# partition would error out (while still writing blank headers)
	sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true
	sgdisk --new 1:20480:+$(( (sz+511)/512 )) \
			-c 1:rootfs_0 "$DISK" >/dev/null \
		|| error "Could not create ${DISKPART#/dev/}1 partition"
	# sgdisk already does partprobe but doesn't give an error code, double check.
	# note we cannot use loop trick here as create_partitions relies on
	# ${DISKPART}1 size for rootfs_1
	# try three times with a delay because sometimes it fails...
	local count=0
	while ! partprobe "$DISK"; do
		[ "$count" -lt 3 ] \
			|| error "Could not reload $DISK partition table"
		sleep 1
		count=$((count + 1))
	done
	dev="${DISKPART}1"
	if [ -n "$ENCRYPT_ROOTFS" ]; then
		luks_format rootfs_0
	fi
	printf "Writing rootfs image... "
	lzopcat /image.lzo | dd of="$dev" bs=1M conv=fsync status=none \
		|| error "Could not copy mmc image over"
	checksum "$dev" "/image.xxh"

	write_check_boot

	# firstboot setup such as create partitions
	firstboot

	# if encryption was setup the device is still open,
	# but we don't know its name for sure (_probably_ loop0p5);
	# try any p5 partition in /dev/mapper, and fall back to normal path
	local appdev logdev
	for appdev in /dev/mapper/*p5; do
		[ -e "$appdev" ] || appdev="${DISKPART}5"
		break
	done
	logdev="${appdev%5}3"

	[ -e "/appfs.lzo" ] && restore_appfs

	if [ -e "${DISK}gp1" ]; then
		mkdir -p /target/var/at-log
		mountpoint -q /target/var/at-log \
			|| mount -t vfat "${DISK}gp1" /target/var/at-log
	fi
	mountpoint -q /target/var/log \
		|| mount -t ext4 "$logdev" /target/var/log \
		|| error "Could not mount /var/log"

	# prepare for postinstall or swu install
	# we build a list of swus in either user mount or / to run in
	# alpha order regardless of partition
	local swus="" swu
	local swu_dirs="${USER_MOUNT:+$USER_MOUNT/installer_swus $USER_MOUNT/} /installer_swus /"
	# shellcheck disable=SC2086 # not quoting on purpose
	swus="$(find $swu_dirs -maxdepth 1 -iname "*.swu" 2>/dev/null | sed -e 's:.*/::' | sort -u)"
	if command -v postinstall > /dev/null || [ -n "$swus" ]; then
		# prepare /target for swu installation
		local mountopt="compress=zstd:3,subvol"
		mount -t btrfs -o "$mountopt=boot_0/containers_storage" \
				"$appdev" /target/var/lib/containers/storage_readonly \
			|| error "Could not mount containers_storage subvol"
		mount -t btrfs -o "$mountopt=boot_0/volumes" \
				"$appdev" /target/var/app/rollback/volumes \
			|| error "Could not mount rollback/volume subvol"
		mount -t btrfs -o "$mountopt=volumes" "$appdev" /target/var/app/volumes \
			|| error "Could not mount volume subvol"
		mount -t btrfs -o "$mountopt=tmp" "$appdev" /target/var/tmp \
			|| error "Could not mount tmp subvol"

		btrfs property set -ts /target/var/lib/containers/storage_readonly ro false \
			|| error "Could not make storage_readonly temporarily writable"
		# we need storage_readonly on host for podman comands
		mkdir /var/lib/containers/storage_readonly

		# We need to use swupdate config from /target, but we can't and file paths
		# inside config are absolute (and sw-versions is not configurable anyway...)
		# Make symlinks so they get updated if target is updated between swus.
		for file in swupdate.cfg sw-versions hwrevision swupdate.pem swupdate.aes-key; do
			ln -sf /target/etc/"$file" /etc/ \
				|| error "Could not create symlink to swupdate config $file"
		done
		mount --bind /target/var/tmp /var/tmp \
			|| error "Could not bind mount /var/tmp"
	fi

	for swu in $swus; do
		for dir in $swu_dirs; do
			if [ -e "$dir/$swu" ]; then
				swu="$dir/$swu"
				break
			fi
		done
		[ -e "$swu" ] || error "Found $swu in listing, but not present for install?"
		# skip if empty (e.g. /dev/null symlink mask in user partition)
		[ -s "$swu" ] || continue
		swu_hashs="${swu_hashs:+$swu_hashs
}$swu $(xxhsum < "$swu" | cut -d' ' -f1)"

		echo "Installing SWU: $swu"
		# note SWUPDATE_FROM_INSTALLER requires swus built with mkswu 4.6+
		TMPDIR=/var/tmp SWUPDATE_FROM_INSTALLER=1 SWUPDATE_USB_SWU="$swu" \
			swupdate -i "$swu" \
				|| error "Could not install $swu"
	done

	if command -v postinstall >/dev/null; then
		echo "Running postinstall command"
		postinstall
	fi

	if mountpoint -q /target/var/lib/containers/storage_readonly; then
		rm -f /target/var/lib/containers/storage_readonly/libpod/bolt_state.db \
			/target/var/lib/containers/storage_readonly/db.sql
		btrfs property set -ts /target/var/lib/containers/storage_readonly ro true \
			|| error "Could not set storage_readonly back to read-only"
	fi

	# copy logs
	cp /target/etc/sw-versions /tmp/sw-versions
	logger -t installer < /tmp/install.log
	if [ -e /var/log/messages ]; then
		cp /var/log/messages /target/var/log/ \
			|| error "Could not copy install logs to device"
	fi
	if mountpoint -q /target/var/at-log; then
		image_log >> /target/var/at-log/atlog \
			|| error "Could not record installed images to atlog"
	fi

	[ -n "$USER_MOUNT" ] && umount_recursive "$USER_MOUNT"
	umount_recursive /target

	sync

	gen_and_send_log "OK"

	echo "Finished writing mmc. ${REBOOT:-powering off} now"

	# and reboot/poweroff into it
	sync
	[ -n "$REBOOT" ] && reboot -f || poweroff -f
}

install
