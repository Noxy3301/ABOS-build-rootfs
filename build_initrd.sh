#!/bin/bash
# SPDX-License-Identifier: MIT

usage()
{
    echo "
USAGE:
  $(basename $0) [OPTIONS] [OUTPUT]

  OPTIONS:
    -b|--board <ax2|ax1|qemu> -- select which output to build
    --rootfs <tar archive>    -- rootfs to use (default <OUTPUT>.tar.zst)
    --lock                    -- disable fallback emergency shell
    -h|--help

  OUTPUT:
    filename of output. (e.g. initrd.zst)
"
}

error()
{
    echo error: "$@" >&2
    exit 1
}

############
# Veriables
############
rootfs=
output=
board=
lock=
scriptdir="$(realpath "$(dirname "$0")")"


# parse args
while [ $# -ne 0 ]
do
    case "$1" in
    "-b"|"--board")
        [ $# -lt 2 ] && error "$1 requires an argument"
        case "$2" in
        "ax2")
            board=ax2
            suffix=x2
            ;;
        "qemu")
            board=qemu
            suffix=qemu
            ;;
        "ax1")
            board=ax1
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
    "--rootfs")
        [ $# -lt 2 ] && error "$1 requires an argument"
        rootfs="$(readlink -e "$2")" \
            || error "rootfs $2 does not exist"
        shift
        ;;
    "--lock")
        lock="${root_pattern:-/dev/mmcblk2p[1-2]}"
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
        ;;
    esac
    shift
done

# set default
if [ -z "$board" ]; then
    echo "use default(board=ax2)"
    board=ax2
    suffix=x2
fi
if [ -z "$rootfs" ]; then
    # shellcheck disable=SC2010 ## using ls to sort by time
    rootfs=$(ls --sort=time "baseos-$suffix-"*.tar* 2>/dev/null | grep -vE '\.(spdx\.json|sig)$' | head -n 1)
    # create rootfs if it we didn't find one
    if [ -z "$rootfs" ]; then
        ./build_rootfs.sh -b "$board"
        # shellcheck disable=SC2010 ## using ls to sort by time
        rootfs=$(ls --sort=time "baseos-$suffix-"*.tar* 2>/dev/null | grep -vE '\.(spdx\.json|sig)$' | head -n 1)
        [ -n "$rootfs" ] || error "Could not find rootfs that was just built"
    fi
fi
if [ -z "$output" ]; then
    outdir="$(pwd)"
    output="initrd-${rootfs%.tar*}${installer:+-initrd}.zst"
    output="$(basename "$output")"
    echo "use default(outdir=$outdir)"
    echo "use default(output=$output)"
fi
case "$output" in
*.zst) comp="zstd --rm";;
*.gz) command -v pigz > /dev/null && comp=pigz || comp=gzip;;
*.bz2) command -v pbzip2 > /dev/null && comp=pbzip2 || comp=bzip2;;
*.xz) command -v pixz > /dev/null && comp=pixz || comp=xz;;
*) comp="cat";;
esac

[ -e "$rootfs" ] \
    || error "rootfs $rootfs does not exist -- specify with --rootfs or match image name to previously built image"
rootfs=$(realpath -e "$rootfs")

#######
# Main
#######
cleanup() {
    [ -n "$workdir" ] || return
    rm -rf "$workdir"
}
workdir=""
trap cleanup EXIT


main() {
    workdir="$(mktemp -d -t alpine-build-initrd.XXXXXX)" \
        || error "Could not create workdir"
    cd "$workdir" || error "could not enter workdir"

    mkdir "rootfs" \
        || error "Could not create temporary directories"
    tar -C "rootfs" -xf "$rootfs" \
        || error "Could not extract rootfs $rootfs"

    # tools we want to include
    # we need to cd into rootfs for cpio -p (pass-through), so it
    # doesn't copy the rootfs/ prefix as well.
    # pipefail so we notice if e.g. cryptsetup wasn't in rootfs
    (
        set -o pipefail
        cd rootfs &&
            "$scriptdir/tools/lddtree" -R "$PWD" -l \
                /bin/busybox \
                /sbin/cryptsetup \
                /usr/bin/caam-keygen \
                /usr/bin/caam-decrypt \
            | sed -e "s:$PWD/::" \
            | sort -u \
            | cpio --quiet -pdm ../initrd
    ) || error "Could not copy initrd binaries"


    ln -s busybox initrd/bin/sh \
        || error "Couldn't create bin/sh link"
    cp -a "$scriptdir/initrd/." initrd/ \
        || error "Couldn't copy init script"

    if [[ -n "$lock" ]]; then
        touch initrd/noshell initrd/noplain \
            && echo "$lock" > initrd/root_pattern \
            || error "Couldn't create initrd lock files"
    elif ! [[ -e initrd/noshell ]]; then
        echo
        echo "Initrd created without locking: this is only for compatibility,"
        echo "consider building with $0 --lock"
    fi

    (
        set -o pipefail
        cd initrd &&
            find . | sort | cpio --quiet --renumber-inodes -o -H newc | $comp
    ) > "$output" || error "Couldn't build initrd"

    mv "$output" "$outdir/" || error "Couldn't move $output to $outdir"

    echo
    echo "Successfully built $outdir/$output"
}

main
