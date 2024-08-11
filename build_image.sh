#!/bin/sh
# SPDX-License-Identifier: MIT

usage()
{
    echo "
USAGE:
  $(basename "$0") [OPTIONS] [OUTPUT.img]

  OPTIONS:
    -b|--board <ax2|ax1|a6e|a600|qemu>    -- select which output to build
    -B|--boot <boot file to embed>        -- embed boot (sdcard, sw-versions)
    -s|--sign  <key> <cert>               -- produce output.sig signature
    --rootfs <tar archive>                -- rootfs to use (default <OUTPUT>.tar.zst)
    --firmware <image>                    -- add firmware image file (only for main image)
    --installer <image>                   -- produce installer sd card instead of first boot image
    --encrypt <userfs|all>                -- have installer produce an encrypted fs.
                                             (This only makes sense with secure boot enabled)
    --sbom                                -- create sbom (default to not create sbom)
    --sbom-config <config>                -- config used to generate SBOM
                                             (default baseos_sbom.yaml)
    --sbom-external <sbom>                -- add sbom file
    -h|--help

  OUTPUT:
    filename of output. (e.g. alpine.img)
    if signing, also output.sig (e.g. alpine.img.sig)
"
}

warning()
{
    printf "warning: %s\n" "$@" >&2
}

error()
{
    printf "error: %s\n" "$@" >&2
    exit 1
}

############
# Veriables
############
signkey=
signcert=
rootfs=
boot=
output=
installer=
board=
extlinux=
firmware=
fstype=
encrypt=
uboot_env=
check_commands="sgdisk:gdisk"
sbom_config="$(realpath baseos_sbom.yaml)"
sbom_external=

# parse args
while [ $# -ne 0 ]
do
    case "$1" in
    "-b"|"--board")
        [ $# -lt 2 ] && error "$1 requires an argument"
        case "$2" in
        "ax2")
            board=ax2
            arch=aarch64
            suffix=x2
            dtb=armadillo_iotg_g4.dtb
            ;;
        "a6e")
            board=a6e
            arch=armv7
            suffix=6e
            dtb=armadillo-iotg-a6e.dtb
            ;;
        "a600")
            board=a600
            arch=armv7
            suffix=600
            dtb=armadillo-640.dtb
            ;;
        "qemu")
            board=qemu
            arch=x86_64
            suffix=qemu
            ;;
        "ax1")
            board=ax1
            arch=armhf
            suffix=x1
            ;;
        *)
            echo "unknown board($2)"
            usage
            exit 1
            ;;
        esac
        shift
        ;;
    "-B"|"--boot")
        [ $# -lt 2 ] && error "$1 requires an argument"
        boot="$(readlink -e "$2")" \
            || error "boot $2 does not exist"
        shift
        ;;
    "-f"|"--firm"|"--firmware")
        [ $# -lt 2 ] && error "$1 requires an argument"
        firmware="$(readlink -e "$2")" \
            || error "firmware $2 does not exist"
        shift
        ;;
    "--fstype")
        [ $# -lt 2 ] && error "$1 requires an argument"
        fstype="$2"
        case "$fstype" in
        ext4|btrfs) ;;
        *) error "Invalid fstype: $fstype (only support ext4 and btrfs)";;
        esac
        shift
        ;;
    "--encrypt")
        [ $# -lt 2 ] && error "$1 requires an argument (userfs, all)"
        encrypt="$2"
        case "$encrypt" in
        userfs|all) ;;
        *) error "Invalid encrypt option: $encrypt (must be 'userfs' or 'all')";;
        esac
        shift
        ;;
    "-s"|"--sign")
        [ $# -lt 3 ] && error "$1 requires [key cert] arguments"
        signkey="$2"
        signcert="$3"
        [ -r "$signkey" ] || error "key $signkey is not readable"
        [ -r "$signcert" ] || error "cert $signcert is not readable"
        shift 2
        ;;
    "--installer")
        [ $# -lt 2 ] && error "$1 requires an argument"
        installer="$(readlink -e "$2")" \
            || error "install image $2 does not exist"
        [ "$installer" = "${installer%.img}" ] \
            && error "Installer $installer does not end in .img, image type not handled"
        shift
        ;;
    "--rootfs")
        [ $# -lt 2 ] && error "$1 requires an argument"
        rootfs="$(readlink -e "$2")" \
            || error "rootfs $2 does not exist"
        shift
        ;;
    "--uboot-env")
        [ $# -lt 2 ] && error "$1 requires an argument"
        uboot_env="$2"
        shift
        ;;
    "--sbom")
        sbom=true
        ;;
    "--sbom-config")
        sbom_config="$(readlink -e "$2")" \
            || error "sbom-config $2 does not exist"
        shift
        ;;
    "--sbom-external")
        [ $# -lt 2 ] && error "$1 requires an argument"
        sbom_external="$(readlink -e "$2")" \
            || error "sbom-external $2 does not exist"
        shift
        ;;
    "-h"|"--help")
        usage
        exit 0
        ;;
    -*)
        echo "Invalid option $1" >&2
        usage >&2
        exit 1
        ;;
    *)
        outdir="$(dirname "$(readlink -f "$1")")"
        output="$(basename "$1")"
        [ -z "$rootfs" ] && rootfs="${output%.img}.tar.zst"
        if [ "${output%.img}" = "$output" ]; then
            echo "Output file \"$output\" must end in .img" >&2
            exit 1
        fi
        ;;
    esac
    shift
done

# set default
if [ -z "$board" ]; then
    echo "use default(board=ax2)"
    board=ax2
    arch=aarch64
    suffix=x2
    dtb=armadillo_iotg_g4.dtb
fi
if [ -z "$output" ]; then
    if [ -z "$rootfs" ]; then
        # shellcheck disable=SC2010 # ls | grep because too complex to glob
        rootfs=$(ls --sort=time baseos-$suffix-*.tar* 2>/dev/null \
                 | grep -vE '\.sig$|\.spdx.json$' | head -n 1)
        # create rootfs if it we didn't find one
        if [ -z "$rootfs" ]; then
            ./build_rootfs.sh -b "$board"
            # shellcheck disable=SC2010 # ls | grep because too complex to glob
            rootfs=$(ls --sort=time baseos-$suffix-*.tar* 2>/dev/null \
                     | grep -vE '\.sig$|\.spdx.json$' | head -n 1)
            [ -n "$rootfs" ] || error "Could not find rootfs that was just built"
        fi
    fi
    outdir="$(pwd)"
    output="${rootfs%.tar*}${installer:+-installer}.img"
    output="$(basename "$output")"
    echo "use default(outdir=$outdir)"
    echo "use default(output=$output)"
fi

[ -e "$rootfs" ] \
    || error "rootfs $rootfs does not exist -- specify with --rootfs or match image name to previously built image"
rootfs=$(realpath -e "$rootfs")

[ "$arch" = "x86_64" ] && extlinux=1 && fstype=ext4
if [ -n "$installer" ]; then
    [ -n "$boot" ] || error "--boot must be set for --installer"
    [ -z "$fstype" ] && fstype=btrfs

    check_commands="$check_commands xxhsum:xxhash"
fi
[ -z "$fstype" ] && fstype=ext4
case "$fstype" in
ext4) check_commands="$check_commands mkfs.ext4:e2fsprogs";;
btrfs) check_commands="$check_commands mkfs.btrfs:btrfs-progs";;
esac
[ -z "$encrypt" ] || [ -n "$installer" ] || error "--encrypt can only be set for --installer"

if [ "${PATH%sbin*}" = "$PATH" ] && ! command -v sgdisk >/dev/null; then
    # debian by default doesn't include sbin in PATH,
    # but only add it if needed
    PATH=/usr/sbin:$PATH
fi

missing_commands=""
for command in $check_commands; do
    command -v "${command%:*}" >/dev/null || missing_commands="$missing_commands ${command#*:}"
done
if [ -n "$missing_commands" ]; then
    sudo=""
    [ "$(id -u)" != "0" ] && sudo="sudo "
    error "Missing required programs: please install with: ${sudo}apt install$missing_commands"
fi

# Installs and configures extlinux.
# from https://github.com/alpinelinux/alpine-make-vm-image
setup_extlinux() {
        local mnt="$1"  # path of directory where is root device currently mounted
        local root_dev="$2"  # root device
        local modules="$3"  # modules which should be loaded before pivot_root
        local kernel_flavor="$4"  # name of default kernel to boot
        local serial_port="$5"  # serial port number for serial console
        local default_kernel="$kernel_flavor"
        local kernel_opts=''

        [ -z "$serial_port" ] || kernel_opts="console=$serial_port"

        if [ "$kernel_flavor" = 'virt' ]; then
                _apk search --root . --exact --quiet linux-lts | grep -q . \
                        && default_kernel='lts' \
                        || default_kernel='vanilla'
        fi

        sudo sed -Ei \
                -e "s|^[# ]*(root)=.*|\1=$root_dev|" \
                -e "s|^[# ]*(default_kernel_opts)=.*|\1=\"$kernel_opts\"|" \
                -e "s|^[# ]*(modules)=.*|\1=\"$modules\"|" \
                -e "s|^[# ]*(default)=.*|\1=$default_kernel|" \
                -e "s|^[# ]*(serial_port)=.*|\1=$serial_port|" \
                "$mnt"/etc/update-extlinux.conf

        sudo chroot "$mnt" extlinux --install /boot
        sudo chroot "$mnt" update-extlinux --warn-only 2>&1 \
                | grep -Fv 'extlinux: cannot open device /dev' >&2
}

#######
# Main
#######
cleanup() {
    [ -n "$workdir" ] || return
    [ -d "$workdir/mnt" ] && sudo umount "$workdir/mnt"
    rm -rf --one-file-system "$workdir"
}
trap cleanup EXIT


scriptdir=$(realpath "$(dirname "$0")")
workdir="$(mktemp -d -t alpine-build-rootfs.XXXXXX)"
cd "$workdir" || error "could not enter workdir"


create_disk() {
    # 'normal' rootfs is fixed at 300MB...
    SIZE=300
    if [ -n "$installer" ]; then
        # ... but installer can be quite bigger with container images:
        # compute size from embedded files + 20% for filesystem overhead
        # with a 390MB base size (installer rootfs and base image)
        # (390 as a workaround to keep the default, almost empty case below
        # 400MB for old abos-ctrl make-installer)
        SIZE=$(du -sm "$outdir"/common/image_common/ \
                "$outdir"/common/image_installer/ \
                "$outdir/$board"/image_common/ \
                "$outdir/$board"/image_installer/ 2>/dev/null \
            | awk '{ tot += $1 } END { print int(tot * 1.2 + 390) }')
    fi
    # x86_64 needs slightly bigger rootfs
    [ "$arch" = "x86_64" ] && SIZE=$((SIZE+50))
    truncate -s $((SIZE+21))M "$output"
    # XXX start 20480 only needed for sd card?
    local format_opts="--zap-all --new 1:20480:+$((SIZE))M -c 1:rootfs_0"
    case "$suffix" in
    "6e"|"600")
         format_opts="$format_opts -j $((20480-32))"
         ;;
    esac
    sgdisk $format_opts "$output"
}

create_mount_partition() {
    local offset=$((20480*512))
    local size=$((SIZE*1024))
    local lodev mountopt=""

    case "$fstype" in
    ext4)
        # extlinux needs the 64bit option to be disabled for some reason
        # (it sometimes works, but is not reliable)
        mkfs.ext4 -F -E "offset=$offset" ${extlinux:+-O "^64bit"} \
                -L rootfs_0 "$output" "$size" \
            || error "mkfs ext4 rootfs"
        ;;
    btrfs)
        # mkfs.btrfs has no offset option: go manual.
        lodev=$(sudo losetup --show -f -o "$offset" \
                --sizelimit "$((size*1024))" "$output") \
            || error "Could not setup loop device for rootfs creation"
        # ATDE9 ships btrfs-progs 5.10, which still requires -m DUP -R free-space-tree
        # (changed in 5.15)
        if ! sudo mkfs.btrfs -L rootfs_0 -m DUP -R free-space-tree "$lodev"; then
            sudo losetup -d "$lodev"
            error "mkfs btrfs failed"
        fi
        sudo losetup -d "$lodev"
        # loop file is only really removed after flush, so on slow devices
        # mount can fail below with loop device conflict error
        sync
        mountopt=",compress-force=zstd,discard"
        ;;
    *) error "Unknown fstype $fstype";;
    esac
    mkdir mnt
    sudo mount -o "offset=$offset,noatime$mountopt" "$output" mnt || error "mount rootfs failed"
}

extract_rootfs() {
    sudo mkdir mnt/boot mnt/mnt mnt/target
    sudo tar -C mnt --xattrs --xattrs-include=security.capability \
        -xf "$rootfs" || error "extract rootfs"
}

offset_bootloader() {
    [ -z "$boot" ] && return

    # need to add the 1KB padding if missing because the installer
    # installs the boot file without 1KB offset
    if [ "$board" = a6e -o "$board" = a600 ] \
           && ! cmp -s -n 1024 "$boot" /dev/zero; then
        local boot_1koffset="$workdir/$(basename "$boot")"

        dd if="$boot" of="$boot_1koffset" bs=1M \
                seek=1024 oflag=seek_bytes status=none \
            || error "Could not create padded boot file"
        boot="$boot_1koffset"
    fi
}


customize_rootfs_firstboot() {
    # need to remove symlink first
    sudo rm -f mnt/sbin/init
    sudo cp -r "$outdir"/common/image_firstboot/. mnt \
        || error "could not copy first install files"
    if [ -e "$outdir/$board"/image_firstboot ]; then
        sudo cp -r "$outdir/$board"/image_firstboot/. mnt \
            || error "could not copy board first install files"
    fi
}

copy_to_lzo_and_csum() {
    local dest="$1"
    local sz="$2"
    shift 2
    local xxh
    local pid_xxh pid_wc pid_tee pid_source

    # assume we can read source multiple times
    mkfifo pipe_tee pipe_xxh pipe_lzop pipe_wc
    xxhsum < pipe_xxh > xxh &
    pid_xxh=$!

    wc -c < pipe_wc > sz &
    pid_wc=$!

    tee pipe_lzop pipe_xxh > pipe_wc < pipe_tee &
    pid_tee=$!

    "$@" > pipe_tee &
    pid_source=$!

    # shellcheck disable=SC2024 # don't need to read pipe as root
    sudo sh -c "lzop > mnt/$dest.lzo" < pipe_lzop \
        || error "Failed compressing or writing lzo file"
    wait "$pid_source" \
        || error "Source command failed for $dest"
    wait "$pid_xxh" \
        || error "Computing xxh failed for $dest"
    wait "$pid_wc" \
        || error "wc failed for $dest"
    wait "$pid_tee" \
        || error "tee failed for $dest"
    if [ -n "$sz" ]; then
        [ "$sz" = "$(cat sz)" ] \
            || error "Stream was not of the expected size"
    else
        sz="$(cat sz)" \
            || error "Could not read size"
        # sanity check
        [ -n "$sz" ] && [ "$sz" != 0 ] \
            || error "Read size was 0, problem with pipes?"
    fi
    xxh=$(cat xxh) \
        || error "Could not read xxh"
    xxh=${xxh%% *}
    wait "$pid_wc" \
        || error "$dest file does not have expected size (expected $sz)"
    sudo sh -c "echo $sz $xxh > mnt/$dest.xxh" \
        || error "Could not write $dest checksum"
    rm -f pipe_lzop pipe_xxh pipe_wc pipe_tee xxh sz
    local xxhcheck
    xxhcheck="$(lzop -d < "mnt/$dest.lzo" | xxhsum)"
    xxhcheck="${xxhcheck%% *}"
    [ "$xxh" = "$xxhcheck" ] \
        || error "Sha we just wrote does not match (expected $xxh got $xxhcheck"
}

customize_rootfs_installer() {
    local start sz

    # kill autoupdate services
    sudo sh -c 'rm -vf mnt/etc/init.d/swupdate* mnt/lib/udev/rules.d/*swupdate*'


    # copy images to install
    sudo cp -r "$outdir"/common/image_installer/. mnt || error "could not copy installer files"
    if [ -e "$outdir/$board"/image_installer ]; then
        sudo cp -r "$outdir/$board"/image_installer/. mnt \
            || error "could not copy board installer files"
    fi

    # start sector, end sector. End sector in sgdisk is inclusive, add 1...
    start=$(sgdisk -p "$installer" | awk '/rootfs_0/ { print $2, $3 + 1}')
    echo "$start" | grep -qxE '[0-9]+ [0-9]+' \
        || error "Could not find rootfs_0 in image"
    sz=${start#* }
    start=${start% *}
    sz=$(((sz-start)*512))
    start=$((start*512))

    copy_to_lzo_and_csum image "$sz" \
        dd if="$installer" bs=1M iflag=count_bytes,skip_bytes \
            skip="$start" count="$sz" status=none
    basename "$installer" | sudo sh -c 'cat > mnt/image.filename' \
        || error "Could not write image filename"

    # round boot up to 2 or 4MB
    local count=4
    case "$board" in
    "a600") count=2;;
    esac
    copy_to_lzo_and_csum boot "$((count*1024*1024))" \
        sh -c "{ cat '$boot'; cat /dev/zero; } \
            | dd bs=1M count=$count iflag=fullblock status=none"
    basename "$boot" | sudo sh -c 'cat > mnt/boot.filename' \
        || error "Could not write boot filename"

    case "$encrypt" in
    all)
        # if encrypted rootfs, check installer boot/Image
        # which will be installed is fit with initrd
        ! command -v mkimage > /dev/null \
            || mkimage -l mnt/boot/Image | grep -q ramdisk \
            || error "rootfs encryption requested but installer boot/Image is not a fit image with initrd"
        printf "%s\n" "ENCRYPT_ROOTFS=1" "ENCRYPT_USERFS=1" | sudo sh -c 'cat >> mnt/installer.conf'
        ;;
    userfs)
        echo "ENCRYPT_USERFS=1" | sudo sh -c 'cat >> mnt/installer.conf'
        ;;
    esac

    # fix fw_env.config and write env
    (
        . mnt/lib/rc/sh/functions-atmark-board.sh || exit 1
        sed -e "s:{ENVDISK}:$output:" \
               -e "s:{ENVOFFSET}:${UBOOT_ENVOFFSET}:" \
               -e "s:{ENVREDUND}:${UBOOT_ENVREDUND}:" \
               -e "s:{ENVSIZE}:${UBOOT_ENVSIZE}:" \
               mnt/etc/fw_env.config > build_image_fw_env.config \
            || exit 1
        sudo sed -i -e "s:{ENVDISK}:${UBOOT_ENVSD}:" \
               -e "s:{ENVOFFSET}:${UBOOT_ENVOFFSET}:" \
               -e "s:{ENVREDUND}:${UBOOT_ENVREDUND}:" \
               -e "s:{ENVSIZE}:${UBOOT_ENVSIZE}:" \
               mnt/etc/fw_env.config
    ) || error "Could not create fw_env.config"

    if ! command -v fw_setenv >/dev/null; then
        [ -n "$uboot_env" ] && error "--uboot-env was requested but fw_setenv is not installed"
        echo "fw_setenv was not available, skipping setting env"
    elif ! grep -qE '^[^#]' mnt/boot/uboot_env.d/* 2>/dev/null; then
        [ -n "$uboot_env" ] && error "--uboot-env was requested but no default env available"
        echo "fw_setenv was not available, skipping setting env"
    else
        grep -qE "^bootcmd=" mnt/boot/uboot_env.d/* \
            || error "default env files existed but bootcmd was not set, aborting"

        echo "$uboot_env" | sudo sh -c "cat > mnt/boot/uboot_env.d/ZZ_installer" \
            || error "Could not write installer uboot env file"
        cat mnt/boot/uboot_env.d/* \
            | grep -v "upgrade_available=1" \
            | fw_setenv --config build_image_fw_env.config \
                --script - --defenv /dev/null \
            || error "Could not set installer uboot env"
    fi
    rm -f build_image_fw_env.config
}

customize_rootfs() {
    sudo cp -r "$outdir"/common/image_common/. mnt \
        || error "could not copy installer common files"
    if [ -e "$outdir/$board"/image_common ]; then
        sudo cp -r "$outdir/$board"/image_common/. mnt \
            || error "could not copy board installer common files"
    fi
    if [ -n "$firmware" ]; then
        sudo cp "$firmware" mnt/firm.squashfs \
            || error "Could not copy firmware"
        xxhsum "$firmware" \
                | sudo sh -c 'sed -e "s/ .*//" > mnt/firm.squashfs.xxh' \
            || error "Could not write firmware hash"
    fi
    if [ -n "$installer" ]; then
        customize_rootfs_installer
    else
        customize_rootfs_firstboot
    fi
    case "$fstype" in
    btrfs)
        sudo sed -i -e 's@^/dev/root.*@/dev/root\t/\t\t\t\tbtrfs\tro,noatime,compress-force=zstd,discard=async\t0 0@' \
                mnt/etc/fstab \
            || error "Could not update fstab rootfs mount options"
    esac
}

install_bootloader() {
    if [ -n "$extlinux" ]; then
        GPTMBR="mnt/usr/share/syslinux/gptmbr.bin"
        [ -e "$GPTMBR" ] || error "extlinux expected but $GPTMBR not found"
        dd bs=440 count=1 conv=notrunc if="$GPTMBR" of="$output" status=none
        sgdisk --attributes=1:set:2 "$output"
        sudo mount --bind /dev mnt/dev
        sudo mount --bind /proc mnt/proc
        setup_extlinux "$PWD/mnt" "LABEL=rootfs_0" "ext4" lts ttyS0
        sudo umount mnt/dev
        sudo umount mnt/proc
    fi

    # add link to dtb
    if [ -n "$dtb" ]; then
        [ -e "mnt/boot/$dtb" ] \
            || error "/boot/$dtb does not exist !!!"
        sudo ln -s "$dtb" mnt/boot/armadillo.dtb \
            || error "Could not add link to dtb"
    fi

    # actually write in boot image if provided
    [ -z "$boot" ] && return
    case "$board" in
    ax2)
        dd if="$boot" of="$output" bs=1k seek=32 conv=notrunc status=none \
            || error "Could not write boot file to image"
        ;;
    ax1|a6e|a600)
        # skip the 1kB padding for i.MX7/6 (and seek 1kB to avoid corrupting
        # the partition table of the disk)
        dd if="$boot" of="$output" bs=1k skip=1 seek=1 conv=notrunc status=none \
            || error "Could not write boot file to image"
        ;;
    *)
        error "Board does not support --boot: $board"
        ;;
    esac
}

board_has_swu() {
    local layer prefix
    for layer in common "$board"; do
        prefix="$scriptdir/$layer/image_installer"
        stat "$prefix/"*.swu >/dev/null 2>&1 && return
        stat "$prefix/installer_swus/"*.swu >/dev/null 2>&1 && return
    done
    return 1
}

build_sbom() {
    echo "Creating SBOM"

    "$scriptdir/build_sbom.sh" -i "$output" -c "$sbom_config" \
            -o "$outdir/$output" \
            ${sbom_external:+-e "$sbom_external"} \
            -e "$rootfs.spdx.json" \
        || error "Could not build sbom"

    if [ -z "$sbom_external" ] && board_has_swu; then
        warning "Note the generated SBOM will not contain license information for software" \
                "added through SWU files. Please append an external SBOM if required."
    fi
}

create_disk
create_mount_partition
extract_rootfs
offset_bootloader
customize_rootfs
install_bootloader

sudo umount mnt || error "could not umount rootfs"
rmdir mnt

[ -n "$sbom" ] && build_sbom

# assume VM image for x86_64, in which case create larger sparse file
[ "$arch" = "x86_64" ] && truncate -s 8G "$workdir/$output"

if [ -n "$signkey" ]; then
    openssl cms -sign -in "$workdir/$output" -out "$workdir/$output.sig" \
            -signer "$signcert" -inkey "$signkey" -outform DER \
            -nosmimecap -binary \
        || error "Could not sign image"
fi
! [ -e "$workdir/$output.sig" ] \
    || mv "$workdir/$output.sig" "$outdir" \
    || error "Could not move signature to $outdir"
mv "$workdir/$output" "$outdir/" \
    || error "Could not move image to $outdir"


echo
echo "Successfully built $outdir/$output"
