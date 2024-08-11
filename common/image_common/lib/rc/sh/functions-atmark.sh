#!/bin/sh
# SPDX-License-Identifier: MIT

print_green() {
	printf "\e[1;92m%s\e[00m\n" "$@"
}

print_red() {
	printf "\e[1;91m%s\e[00m\n" "$@"
}

error() {
	if command -v print_red >/dev/null; then
		print_red "$@"
	else
		printf "%s\n" "$@"
	fi
	printf "INSTALLER: %s\n" "$@" > /dev/kmsg
	[ -n "$loop" ] && losetup -d "$loop"

	# gen_and_send_log is provided by the caller
	gen_and_send_log "NG" "$@"

	# If the script failed continue to normal boot
	# note we need to manually mark some services as already started
	# already started as starting them again fails boot
	mkdir -p /run/openrc/started
	ln -s /etc/init.d/overlayfs  /etc/init.d/root /etc/init.d/cgroups \
		/etc/init.d/reset_bootcount /etc/init.d/syslog \
		/etc/init.d/klogd /run/openrc/started/
	exec busybox init
}

umount_recursive() {
	# based on umount_if_mountpoint of mkswu/abos-base
	# Note we cannot use abos-ctrl umount as this must work with older
	# rootfs (through make-installer)
	findmnt -nr -o TARGET -R "$1" | tac | xargs -r umount --
}

fw_setenv_nowarn() {
	FILTER="Cannot read environment, using default|Environment WRONG|Environment OK" \
		filter command fw_setenv "$@"
}

filter() {
	local output ret

	output="$(mktemp /tmp/cmd_output.XXXXXX)" \
		|| error "Could not create tmpfile for $1"

	"$@" > "$output" 2>&1
	ret=$?

	if [ -n "$FILTER" ]; then
		grep -vE "$FILTER" < "$output"
	else
		cat "$output"
	fi
	rm -f "$output"
	return "$ret"
}

luks_format() {
	# from mkswu scripts/common.sh
	# modifies dev with new target
	local target="$1"
	[ -n "$dev" ] || error "\$dev must be set"
	command -v cryptsetup > /dev/null \
		|| error "cryptsetup must be installed"
	command -v caam-encrypt > /dev/null \
		|| error "caam-encrypt must be installed"

	local index offset
	case "$dev" in
	*p[0-9])
		index=${dev##*p}
		index=$((index-1))
		offset="$(((9*1024 + index*4)*1024))"
		;;
	*) error "LUKS only supported on *p[0-9] partitions (got $dev)" ;;
        esac

	mkdir -p /run/caam
	local KEYFILE=/run/caam/lukskey
	# lower iter-time to speed PBKDF phase up,
	# since our key is random PBKDF does not help
	# also, we don't need a 16MB header so make it as small as possible (1MB)
	# by limiting the maximum number of luks keys (3 here, same size with less)
	# key size is 112
	unshare -m sh -c "mount -t tmpfs tmpfs /run/caam \
		&& caam-keygen create ${KEYFILE##*/} ccm -s 32 \
		&& dd if=/dev/random of=$KEYFILE.luks bs=$((4096-112-16)) count=1 status=none \
		&& dd if=/dev/random of=$KEYFILE.iv bs=16 count=1 status=none \
		&& cat $KEYFILE.iv $KEYFILE.luks > $KEYFILE.toenc \
		&& caam-encrypt $KEYFILE.bb AES-256-CBC $KEYFILE.toenc $KEYFILE.enc \
		&& cat $KEYFILE.bb $KEYFILE.iv $KEYFILE.enc > $KEYFILE.mmc \
		&& { if ! [ \$(stat -c %s $KEYFILE.mmc) = 4096 ]; then \
			echo \"Bad key size \$(stat -c %s $KEYFILE.mmc)\"; false; \
		fi; } \
		&& cryptsetup luksFormat -q --key-file $KEYFILE.luks \
			--pbkdf pbkdf2 --iter-time 1 \
			--luks2-keyslots-size=768k \
			$dev > /dev/null \
		&& cryptsetup luksOpen --key-file $KEYFILE.luks \
			--allow-discards $dev $target \
		&& dd if=$KEYFILE.mmc of=$DISK bs=4k count=1 status=none \
			oflag=seek_bytes seek=$offset" \
		|| error "Could not create luks partition on $dev"

	dev="/dev/mapper/$target"
}

luks_unlock() {
        # modifies dev if unlocked
        local target="$1"
        [ -n "$dev" ] || error "\$dev must be set"

        if [ -e "/dev/mapper/$target" ]; then
                # already unlocked, use it
                dev="/dev/mapper/$target"
                return
        fi

        command -v cryptsetup > /dev/null \
                || return 0

        # not luks? nothing to do!
        cryptsetup isLuks "$dev" \
                || return 0

        command -v caam-decrypt > /dev/null \
                || return 0

        local index offset
        case "$dev" in
        *p*)
                # keys are stored in $rootdev as follow
                # 0MB        <GPT header and partition table>
                # 9MB        key for part 1
                # 9MB+4k     key for part 2
                # 9MB+(n*4k) key for part n+1
                # 10MB       first partition
                index=${dev##*p}
                index=$((index-1))
                offset="$(((9*1024 + index*4)*1024))"
                ;;
        *) error "LUKS only supported on *p* partitions" ;;
        esac

        mkdir -p /run/caam
        local KEYFILE=/run/caam/lukskey
        # use unshared tmpfs to not leak key too much
        # key is:
        # - 112 bytes of caam black key
        # - 16 bytes of iv followed by rest of key
        unshare -m sh -c "mount -t tmpfs tmpfs /run/caam \
                && dd if=$DISK of=$KEYFILE.mmc bs=4k count=1 status=none \
                        iflag=skip_bytes skip=$offset \
                && dd if=$KEYFILE.mmc of=$KEYFILE.bb bs=112 count=1 status=none \
                && dd if=$KEYFILE.mmc of=$KEYFILE.enc bs=4k status=none \
                        iflag=skip_bytes skip=112 \
                && caam-decrypt $KEYFILE.bb AES-256-CBC $KEYFILE.enc \
                        $KEYFILE.luks >/dev/null 2>&1 \
                && cryptsetup luksOpen --key-file $KEYFILE.luks \
                        --allow-discards $dev $target >/dev/null 2>&1" \
                || return

        dev="/dev/mapper/$target"
}

get_kotai_code() {
	# qemu has no nvmem, just skip this in this case.
	[ -e /sys/bus/nvmem/devices/imx-ocotp0/nvmem ] \
		|| return

	# offset must be set.
	[ -n "$KOTAI_CODE_OFFSET" ] || error "KOTAI_CODE_OFFSET variable has not been set!"

	dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem \
			bs=4 skip="$KOTAI_CODE_OFFSET" count=2 status=none \
		| xxd -p \
		| sed -e 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/g' \
		      -e 's/^....//' \
		| tr '[:lower:]' '[:upper:]'
}

format_ext() {
	local dev="$1"
	local label="$2"

	[ -e "$dev" ] || error "No partition $dev!"
	[ -n "$ENCRYPT_USERFS" ] && luks_format "${dev##*/}"
	dd if=/dev/zero of="$dev" bs=32k count=1 status=none
	mkfs.ext4 -q -L "$label" "$dev" \
		|| error "mkfs ext4 failed"
}

copy_firm() {
	local firm sz xxh

	# prefer installer version over rootfs version over just-read version
	[ -e "/tmp/firm.squashfs" ] && firm="/tmp/firm.squashfs"
	[ -e "/target/firm.squashfs" ] && firm="/target/firm.squashfs"
	[ -e "/firm.squashfs" ] && firm="/firm.squashfs"

	# nothing we can write
	[ -e "$firm" ] || return

	# encrypt partition if required
	[ -n "$ENCRYPT_USERFS" ] && luks_format "${dev##*/}"

	# in many cases the firmware to write will already be on disk,
	# skip disk write if content is identical
	if [ -e "$firm.xxh" ]; then
		sz=$(stat -c "%s" "$firm")
		xxh=$(dd if="$dev" bs=1M count="$sz" iflag=count_bytes status=none \
			| xxhsum)
		xxh=${xxh%% *}
		[ "$(cat "$firm.xxh")" = "$xxh" ] && return
	fi

	# actual copy and write check
	printf "Copying firm partition... "
	dd if="$firm" of="$dev" bs=1M conv=fsync status=none \
		|| error "Copy of firmware failed"
	if [ -e "$firm.xxh" ]; then
		xxh=$(dd if="$dev" bs=1M count="$sz" iflag=count_bytes,direct status=none \
			| xxhsum)
		xxh=${xxh%% *}
		[ "$(cat "$firm.xxh")" = "$xxh" ] \
			|| error "firmware checksum does not match, expected $(cat "$firm.xxh"), got $xxh"
	fi

	print_green "ok"
}

check_copy_firm() {
	local dev="$1"

	[ -e "$dev" ] || error "No partition $dev!"

	copy_firm

	luks_unlock "${dev##*/}"
	if unshare -m mount -t squashfs "$dev" /target >/dev/null 2>&1; then
		case "$dev" in
		/dev/mapper/*) firmware_dev="/dev/mapper/${DISKPART#/dev/}4";;
		*) firmware_dev="${DISKPART}4";;
		esac
	fi
}

format_app() {
	local dev="$1"
	local label="app"

	printf "Preparing app partition... "

	[ -e "$dev" ] || error "No partition $dev!"
	[ -n "$ENCRYPT_USERFS" ] && luks_format "${dev##*/}"
	mkfs.btrfs -q -f -L "$label" "$dev" \
		|| error "mkfs btrfs failed"
	mount -t btrfs "$dev" /mnt
	btrfs -q subvolume create /mnt/tmp \
		|| error "subvolume creation failed"
	mkdir /mnt/boot_0 /mnt/boot_1
	btrfs -q subvolume create /mnt/volumes \
		|| error "subvolume creation failed"
	btrfs -q subvolume create /mnt/boot_0/containers_storage \
		|| error "subvolume creation failed"
	btrfs -q subvolume create /mnt/boot_0/volumes \
		|| error "subvolume creation failed"

	# work around podman being silly and throwing errors if the
	# store does not look right
	podman --storage-opt additionalimagestore="" \
		--root /mnt/boot_0/containers_storage image list >/dev/null 2>&1
	rm -f /mnt/boot_0/containers_storage/libpod/bolt_state.db \
		/mnt/boot_0/containers_storage/db.sql
	# yes it really needs that too...
	mkdir -p /mnt/boot_0/containers_storage/overlay-layers /mnt/boot_0/containers_storage/overlay-images
	touch /mnt/boot_0/containers_storage/overlay-images/images.lock
	touch /mnt/boot_0/containers_storage/overlay-layers/layers.lock
	btrfs property set /mnt/boot_0/containers_storage ro true

	# and prepare boot_1 as well just in case
	btrfs -q subvolume snapshot -r /mnt/boot_0/containers_storage /mnt/boot_1/containers_storage \
		|| error "subvolume creation failed"
	btrfs -q subvolume create /mnt/boot_1/volumes \
		|| error "subvolume creation failed"

	mountpoint -q /mnt/boot_0/containers_storage/overlay \
		&& umount /mnt/boot_0/containers_storage/overlay
	umount /mnt

	# also create mountpoints in target rootfs
	mkdir -p /target/var/lib/containers/storage_readonly
	mkdir -p /target/var/lib/containers/storage
	mkdir -p /target/var/app/rollback/volumes
	mkdir -p /target/var/app/volumes /target/var/tmp

	print_green "ok"
}

create_partitions() {
	local part start size

	# We need a first non-trivial sgdisk call to "resize" the gpt,
	# otherwise partition creations fail saying there is not
	# enough space... Rerandomize disk/partition GUID.
	sgdisk -G "$DISK" >/dev/null

	size="$(lsblk -o SIZE -rn "$DISKPART"1)"
	sgdisk --new 2:0:+"$size" -c 2:rootfs_1 \
		--new 3:0:+50M -c 3:logs \
		--new 4:0:+200M -c 4:firm \
		--new 5:0:0 -c 5:app \
		"$DISK" > /dev/null \
		|| error "partitioning disk failed"
}

initialize_partitions() {
	# first partition is in use in firstboot case, use losetup -P to
	# recreate a new device with its own partition table.
	loop=$(losetup -f) && losetup -P "$loop" "$DISK" \
		|| error "Could not setup loop device"
	dd if=/dev/zero of="${loop}p2" bs=1M count=1 status=none \
		|| error "Could not wipe old 2nd rootfs"
	format_ext "${loop}p3" logs
	check_copy_firm "${loop}p4"
	format_app "${loop}p5"

	echo "Finishing installation..."

	losetup -d "$loop" || error "Could not destroy loop device"
	loop=""

	# format gp partitions we use
	if [ -e "$DISK"gp0 ]; then
		# If the mmc is write protected, turn it off.
		# We sometimes lock gp0 after writing license files,
		# so unlock can be required on reinstall
		if mmc writeprotect user get "$DISK"gp0 \
		    | grep -q "Temporary Write Protection"; then
			mmc writeprotect user set none 0 16384 "$DISK"gp0
		fi
		dd if=/dev/zero of="$DISK"gp0 bs=4k count=1 status=none
		mkfs.ext4 -q -F "$DISK"gp0 \
			|| error "Could not format gp0 partition"
		# baseos currently has no license files to copy
	fi
	if [ -e "$DISK"gp1 ]; then
		mkfs.vfat -n ATLOG "$DISK"gp1 > /dev/null \
			|| error "Could not format atlog partition (gp1)"
	fi
}

update_version() {
	local component="$1"
	local version="$2"
	local vers_file="/target/etc/sw-versions"

	awk -vcomp="$component" -vvers="$version" \
		'$1 == comp { print comp, vers; found=1 }
		 $1 != comp { print }
		 END { if (!found) print comp, vers }' \
			 < "$vers_file" > "$vers_file.tmp" \
		&& mv "$vers_file.tmp" "$vers_file" \
		|| error "Could not set $component version in sw-versions"
}

enable_overlay() {
	local enabled_overlays new_overlays=""

	if ! enabled_overlays=$(grep -E '^fdt_overlays=' \
				/target/boot/overlays.txt 2>/dev/null); then
		# file has no overlay yet: just append everything.
		new_overlays="$*"
		echo "fdt_overlays=$new_overlays" >> /target/boot/overlays.txt \
			|| error "Could not create overlays.txt"
		return
	fi
	enabled_overlays="${enabled_overlays#fdt_overlays=}"

	# check for any overlay already configured
	for overlay; do
		case " $enabled_overlays " in
		*" $overlay "*) ;;
		*) new_overlays=" $overlay";;
		esac
	done

	# nothing to do?
	[ -z "$new_overlays" ] && return

	sed -i -e "s/^fdt_overlays=.*/&$new_overlays/" /target/boot/overlays.txt \
		|| error "Could not update overlays.txt"
}

firstboot_setup() {
	mountpoint -q /proc \
		|| mount -t proc proc /proc -o nodev,noexec,nosuid \
		|| error "Could not mount proc"
	mountpoint -q /sys \
		|| mount -t sysfs sysfs /sys -o nodev,noexec,nosuid \
		|| error "Could not mount sysfs"
	# shellcheck disable=SC2317 ## commands for overlayfs script
	[ "$(findmnt -nr -o FSTYPE -T %T / 2>/dev/null)" = "overlay" ] || (
		eerror() { printf "%s\n" "$@"; exit 1; }
		ebegin() { :; }
		eend() { :; }
		. "/etc/init.d/overlayfs" > /dev/null 2>&1
		start
	) || error "Could not setup overlayfs"

	# most of these are actually only required for swupdate's use
	# of podman, but mount anyway for consistency
	mkdir -p /dev/pts /dev/shm /dev/mqueue
	mountpoint -q /dev/pts \
		|| mount -t devpts devpts /dev/pts -o noexec,nosuid,gid=5,mode=620 \
		|| error "Could not mount /dev/pts"
	mountpoint -q /dev/shm \
		|| mount -t tmpfs shm /dev/shm -o nosuid,nodev,noexec,mode=1777 \
		|| error "Could not mount /dev/shm"
	mountpoint -q /dev/mqueue \
		|| mount -t mqueue mqueue /dev/mqueue -o nodev,noexec,nosuid \
		|| error "Could not mount /dev/mqueue"
	mountpoint -q /sys/fs/cgroup \
		|| mount -t cgroup2 cgroup2 /sys/fs/cgroup -o nodev,noexec,nosuid \
		|| error "Could not mount cgroups"
	mountpoint -q /run \
		|| mount -t tmpfs tmpfs /run \
		|| error "Could not mount /run"
	mountpoint -q /tmp \
		|| mount -t tmpfs tmpfs /tmp \
		|| error "Could not mount /tmp"
	mount -o remount,rw / || error "Could not remount / rw"

	# /dev/loop-control isn't pre-created and we'll need loop, just ensure we can load it
	modprobe loop \
		|| error "loop isn't available on this kernel - wrong module versions installed?" \
			"(running $(uname -r), installed $(ls /lib/modules/ 2>&1)"
	# we copy /var/log/messages if anything was in it at the end
	syslogd -t -s 4096
	klogd
}

# required environment variables
#  DISK = base block device e.g. /dev/mmcblk2 or /dev/vda
#  DISKPART = prefix for partitions e.g. /dev/mmcblk2p or /dev/vda
firstboot() {
	local bootdev="" firmware_dev=""

	create_partitions

	# self-destruct, and poweroff only if we really did something
	local rootdev="${DISKPART}1"
	[ -n "$ENCRYPT_ROOTFS" ] && rootdev="/dev/mapper/rootfs_0"
	# /target is pre-mounted for firstboot
	mountpoint -q /target \
		|| mount "$rootdev" /target \
		|| error "Could not mount $rootdev"
	mount -o remount,rw /target \
		|| error "Could not make $rootdev rw"
	initialize_partitions
	sed -i -e "s:{DISKPART}:$DISKPART:" /target/etc/fstab \
		|| error "Could not update fstab"

	if [ -e "${DISK}boot0" ]; then
		# eMMC
		sed -i -e "s:{ENVDISK}:${DISK}boot0:" \
				-e "s:{ENVOFFSET}:${UBOOT_ENVOFFSET}:" \
				-e "s:{ENVREDUND}:${UBOOT_ENVREDUND}:" \
				-e "s:{ENVSIZE}:${UBOOT_ENVSIZE}:" \
				/target/etc/fw_env.config \
			|| error "Could not update fw_env.config"
		bootdev="${DISK}boot0"
	elif readlink "/sys/class/block/${DISK#/dev/}/device" | grep -q mmc; then
		# SD card
		bootdev="$DISK"
		sed -i -e "s:{ENVDISK}:${DISK}:" \
				-e "s:{ENVOFFSET}:${UBOOT_ENVOFFSET}:" \
				-e "s:{ENVREDUND}:${UBOOT_ENVREDUND}:" \
				-e "s:{ENVSIZE}:${UBOOT_ENVSIZE}:" \
				/target/etc/fw_env.config \
			|| error "Could not update fw_env.config"
	else
		# qemu: no uboot
		rm /target/etc/fw_env.config
	fi
	if [ -e "${DISK}gp1" ] && ! grep -q /var/at-log /target/etc/fstab; then
		cat >> /target/etc/fstab <<EOF
${DISK}gp1	/var/at-log			vfat	defaults			0 0
EOF
	fi

	# update versions. later steps expect version file to exit for updating
	touch /target/etc/sw-versions
	[ -e /target/etc/atmark-release ] \
		&& update_version base_os "$(cat /target/etc/atmark-release)"
	if [ -n "$bootdev" ]; then
		local boot_version
		# extract version string from uboot binary.
		# we're cheating a bit with sdcard, but starting from start
		# of device is good enough here. If we didn't find one
		# (e.g. encrypted) just write in '1' so it gets copied,
		# and it'll be fixed by swupdate further runs...
		boot_version=$(dd if="$bootdev" bs=1M count=4 status=none | strings |
			grep -m1 -oE '20[0-9]{2}.[0-1][0-9]-[0-9a-zA-Z.-]*')
		# normalize version: we want 2020.04-atX to become 2020.4-atX
		boot_version="${boot_version/.0/.}"
		[ -z "$boot_version" ] && boot_version=1
		update_version boot "$boot_version"
	fi
	if [ -n "$ENCRYPT_ROOTFS" ]; then
		# cannot easily guess version from compressed boot image, use 1
		update_version boot_linux 1
	else
		sed -i -e '/^boot_linux /d' /target/etc/sw-versions \
			|| error "Could not update sw-versions"
	fi

	rm -f /target/firm.squashfs /target/firm.squashfs.xxh
	# remove to avoid duplicate/ensure it's unset if no firmware
	if grep -q -F /opt/firmware /target/etc/fstab 2>/dev/null; then
		sed -i -e "/\/opt\/firmware/d" /target/etc/fstab \
			|| error "Could not update fstab"
	fi
	if grep -q HAS_OPT_FIRMWARE /target/etc/atmark/baseos.conf 2>/dev/null; then
		sed -i -e '/HAS_OPT_FIRMWARE/d' /target/etc/atmark/baseos.conf \
			|| error "Could not update baseos.conf"
	fi
	if [ -n "$firmware_dev" ]; then
		cat >> /target/etc/fstab <<EOF \
			|| error "Could not update fstab"
$firmware_dev	/opt/firmware			squashfs defaults			0 0
EOF
		[ -d /target/etc/atmark ] || mkdir /target/etc/atmark \
			|| error "Could not create /etc/atmark"
		echo "HAS_OPT_FIRMWARE=$firmware_dev" >> /target/etc/atmark/baseos.conf \
			|| error "could not update baseos.conf"
	fi
	if [ -n "$ENCRYPT_USERFS" ]; then
		sed -i -e 's@dev/\(mmcblk[12]p[35]\)@dev/mapper/\1@' /target/etc/fstab \
			|| error "Could not update fstab"
	else
		sed -i -e 's@dev/mapper/\(mmcblk[12]p[35]\)@dev/\1@' /target/etc/fstab \
			|| error "Could not update fstab"
	fi

	# generate machine-id for this board; taken from /etc/init.d/machine-id
	dd if=/dev/urandom status=none bs=16 count=1 \
			| md5sum | cut -d' ' -f1 > /target/etc/machine-id \
		|| error "Could not create machine-id"

	# regenerate sshd keys if requested
	if [ -e /target/etc/ssh/ssh_host_keys_installer_regenerate ]; then
		rm -f /target/etc/ssh/ssh_host_keys_installer_regenerate \
			/target/etc/ssh/ssh_host_*key*
		ssh-keygen -A -f /target
	fi

	# remove abos-web certificate if present; will be regenerated next boot
	rm -rf /target/etc/abos_web/tls

	# if rootfs was copied from ab1 we also need to fix a couple more settings
	# this is harmless if useless, already done or for sd boot
	sed -i -e 's/subvol=boot_1/subvol=boot_0/' /target/etc/fstab \
		|| error "Could not update fstab"
	if [ -e /target/etc/fw_env.config ]; then
		sed -i -e 's/mmcblk\(.\)boot1/mmcblk\1boot0/' /target/etc/fw_env.config \
			|| error "Could not update fw_env.config"
	fi
	sed -i -e '/^other_boot\(_linux\)\? /d' /target/etc/sw-versions \
		|| error "Could not update sw-versions"

	if [ -e /target/etc/fw_env.config ] \
	    && grep -qE '^[^#]' /target/boot/uboot_env.d/* 2>/dev/null; then
		# remember console if set for installer
		local console
		if console=$(grep -oE 'console=\S*' /proc/cmdline) \
		    && ! grep -qxF "$console" /target/boot/uboot_env.d/*; then
			echo "$console" > /target/boot/uboot_env.d/10_console \
				|| error "Could not write console u-boot env file"
		fi
		grep -qE "^bootcmd=" /target/boot/uboot_env.d/* \
			|| error "uboot env files existed, but bootcmd is not set, aborting"

		# there isn't anything on B-side at this point,
		# make sure we don't set upgrade_available
		cat /target/boot/uboot_env.d/* \
			| grep -vx "upgrade_available=1" \
			| fw_setenv_nowarn --config /target/etc/fw_env.config \
				--script - \
				--defenv /dev/null \
			|| error "Could not set default env"
	fi

	if command -v board_setup >/dev/null; then
		board_setup
	fi

	rm -f /target/etc/init.d/firstboot-atmark
	rm -f /target/etc/runlevels/sysinit/firstboot-atmark
	rm -f /target/lib/rc/sh/functions-atmark.sh
	rm -f /target/lib/rc/sh/functions-atmark-board.sh
	rm -f /target/sbin/init
	ln -s /bin/busybox /target/sbin/init
	date +%s > /target/etc/.rootfs_update_timestamp
}

[ -e /lib/rc/sh/functions-atmark-board.sh ] \
	&& . /lib/rc/sh/functions-atmark-board.sh
