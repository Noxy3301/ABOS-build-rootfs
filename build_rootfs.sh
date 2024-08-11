#!/bin/sh
# SPDX-License-Identifier: MIT

usage()
{
    echo "
USAGE:
  $(basename $0) [OPTIONS] [OUTPUT]

  OPTIONS:
    -b|--board <ax2|ax1|a6e|a600|qemu>  -- select which output to build
    -s|--sign  <key> <cert>    -- produce output.sig signature
    --release                  -- do not append date to version
    --alpine-mirror            -- url to use for atmark packages
                       e.g. https://download.atmark-techno.com/alpine
    -X|--extra-repos           -- add extra alpine repos
                       can be set multiple times, or a space-separated list
                       these repos have priority if a package is identical
                       and the first given has priority
                       (otherwise highest version wins)
    --cache <dir>              -- Directory or archive to use as apk cache.
                       If empty or non-existing the cache is initialized,
                       otherwise it is used and the build process will not
                       be given internet access.
    --cache-rw                 -- Allow cache to be modified
                       Allow network access and refresh metadata if required
                       by apk. The default keeps the cache read-only.
    --alpine-version           -- alpine version
                       default value from alpine-version file
    --nosbom                   -- do not create sbom (default create sbom)
    --sbom-config <config>     -- config used to generate SBOM
                       default value is baseos_sbom.yaml
    --sbom-external <sbom>     -- add sbom file
    -h|--help                  -- this output

  OUTPUT:
    filename of output. (e.g. alpine.tar.gz)
    if signing, also output.sig (e.g. alpine.tar.gz.sig)
"
}

error()
{
    echo "$@" >&2
    exit 1
}

############
# Veriables
############
alpine_version=$(cat alpine-version)
alpine_version_atmark=$(cat alpine-version)
atmark_version=$(cat atmark-version)
signkey=
signcert=
cache=
cache_rw=
timestamp_version=1
atmark_alpine_mirror=https://download.atmark-techno.com/alpine
extra_repos=
nosbom=
sbom_config="$(realpath baseos_sbom.yaml)"
sbom_external=
DOCKER=${DOCKER:-podman}
if ! command -v "$DOCKER" >/dev/null; then
    DOCKER=docker
fi
if ! command -v "$DOCKER" >/dev/null; then
    error "docker or podman is required"
fi

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
             platform="linux/aarch64"
             ;;
         "a6e")
             board=a6e
             arch=armv7
             suffix=6e
             platform="linux/arm"
             ;;
         "a600")
             board=a600
             arch=armv7
             suffix=600
             platform="linux/arm"
             ;;
        "qemu")
            board=qemu
            suffix=qemu
            arch=x86_64
            platform="linux/x86_64"
            ;;
        "ax1")
            board=ax1
            suffix=x1
            arch=armhf
            platform="linux/arm"
            ;;
        *)
            echo "unknown board($2)"
            usage
            exit 1
            ;;
        esac
        shift
        ;;
    "--alpine-mirror")
        [ $# -lt 2 ] && error "$1 requires an argument"
        atmark_alpine_mirror="$2"
        shift
        ;;
    "-X"|"--extra-repos")
        [ $# -lt 2 ] && error "$1 requires an argument"
        extra_repos="${extra_repos:+$extra_repos }$2"
        shift
        ;;
    "--alpine-version")
        [ $# -lt 2 ] && error "$1 requires an argument"
        alpine_version="$2"
        if [ "$alpine_version" != edge ]; then
            alpine_version_atmark="$alpine_version"
        fi
        shift
        ;;
    "--release")
        timestamp_version=
        ;;
    "--cache")
        [ $# -lt 2 ] && error "$1 requires an argument"
        cache=$(realpath "$2") \
            || error "--cache parent directory must exist"
        shift
        ;;
    "--cache-rw")
        cache_rw=1
        ;;
    "-s"|"--sign")
        [ $# -lt 3 ] && error "$1 requires [key cert] arguments"
        signkey="$2"
        signcert="$3"
        [ -r "$signkey" ] || error "key $signkey not readable"
        [ -r "$signcert" ] || error "cert $signcert not readable"
        shift 2
        ;;
    "--nosbom")
        nosbom=1
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
        extension="tar${output##*.tar}"
        ;;
    esac
    shift
done

# set default
if [ -z "$board" ]; then
    echo "use default(board=ax2)"
    echo "use default(arch=aarch64)"
    board=ax2
    arch=aarch64
    suffix=x2
    platform="linux/aarch64"
fi
if [ -z "$output" ]; then
    outdir="$(pwd)"
    output="baseos-$suffix-ATVERSION.tar.zst"
    extension=tar.zst
    echo "use default(outdir=$outdir)"
    echo "use default(output=$output)"
fi

case "$extension" in
tar.zst) comp="zstd --rm -10";;
tar.gz) command -v pigz > /dev/null && comp=pigz || comp=gzip;;
tar.bz2) command -v pbzip2 > /dev/null && comp=pbzip2 || comp=bzip2;;
tar.xz) command -v pixz > /dev/null && comp=pixz || comp=xz;;
tar) comp=":";;
*) error "Output file \"$output\" must end in .tar or .tar.* (* = zst, gz, bz2, or xz)";;
esac

packages="$(cat common/packages $board/packages 2>/dev/null \
                | grep -v '^#' | xargs)"
alpine_container=alpine-${alpine_version#v}-${arch}

if "$DOCKER" --version | grep -q podman; then
    # podman does not properly handle --platform for local images
    platform=""
fi

############
# Functions
############
get_scripts()
{
    cp -rL "$PWD/submodules/alpine-make-rootfs/." "$workdir/alpine-make-rootfs" \
        || error "alpine-make-rootfs not initialized?"

    cp common/fixup "$workdir/" \
        || error "Could not copy fixup script to workdir"
    if [ -e "$board/fixup" ]; then
        cat $board/fixup >> "$workdir/fixup" \
            || error "Could not append board fixup script"
    fi
    chmod +x "$workdir/fixup" \
        || error "Could not set fixup executable"

    local repo
    for repo in $extra_repos; do
        printf "%s\n" "@atmark $repo" "$repo"
    done > "$workdir/repositories"
    cat >> "$workdir/repositories" <<EOF \
        || error "Could not write repositories file"
@atmark $atmark_alpine_mirror/$alpine_version_atmark/atmark
$atmark_alpine_mirror/$alpine_version_atmark/atmark
https://dl-cdn.alpinelinux.org/alpine/$alpine_version/main
https://dl-cdn.alpinelinux.org/alpine/$alpine_version/community
EOF

    cat > "$workdir/build-alpine-internal.sh" <<EOF \
        || error "Could not internal build script"
#!/bin/sh -e

echo "start build-alpine-internal.sh"

echo "
start install"
./install

echo "
start fixup"
./fixup "$atmark_version${timestamp_version:+.$(date +%Y%m%d)}"

[ -e /etc/atmark-release ] && cp /etc/atmark-release .
EOF
    chmod +x "$workdir/build-alpine-internal.sh" \
        || error "Could not make internal build script executable"

    cat > "$workdir/build-alpine.sh" <<EOF \
        || error "Could not write build script"
#!/bin/sh -e

exit_handler() {
    local ret=\$?
    # cleanup hard to delete (root owned) files here
    rm -rf rootfs resources
    echo "build-alpine.sh done"
    exit \$ret
}

trap exit_handler INT EXIT

[ -d /cache ] || mkdir /cache
# populate initial metadata if none
if ! [ -e /cache/installed ]; then
    mkdir -p tmproot/etc/apk
    cp repositories tmproot/etc/apk
    cp -r /etc/apk/keys tmproot/etc/apk
    apk add --root tmproot --cache-dir=/cache --initdb
    rm -rf tmproot
fi
# make epoch match the most up to date repo metadata,
# unless our latest commit is newer
metadata_epoch=\$(for index in /cache/APKINDEX*.tar*; do
        tar -xf \$index --to-command='echo \$TAR_MTIME'
    done | sort -nr | head -1)
if [ "\$SOURCE_DATE_EPOCH" -lt "\$metadata_epoch" ]; then
    SOURCE_DATE_EPOCH="\$metadata_epoch"
fi

# max age 35791394 is the highest possible value (2^31 seconds in minute)
INSTALL_HOST_PKGS=no \
APK_OPTS="--no-progress --cache-dir=/cache --cache-max-age=35791394" \
alpine-make-rootfs/alpine-make-rootfs \
    --packages "$packages" \
    --script-chroot \
    --repositories-file repositories \
    rootfs ./build-alpine-internal.sh

du -sk rootfs | cut -f 1 > rootfs_footprint_kbyte
apk -p "rootfs" list -I > rootfs_apk_list

tar -C rootfs -c --xattrs --xattrs-include security.capability \
    --numeric-owner --sort=name --mtime=@\$SOURCE_DATE_EPOCH --clamp-mtime \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -f rootfs.tar .

# busybox chown has no --reference..
owner=\$(stat -c %u:%g build-alpine.sh)
chown -R "\$owner" rootfs.tar rootfs_footprint_kbyte rootfs_apk_list \
    /cache
touch -t "@\$SOURCE_DATE_EPOCH" rootfs.tar
EOF
    chmod +x "$workdir/build-alpine.sh" \
        || error "Could not make build script executable"

    cp common/install "$workdir/install" \
        || error "could not copy install script to workdir"
    if [ -e "$board/install" ]; then
        cat "$board/install" >> "$workdir/install" \
            || error "could not append board install script"
    fi
    chmod +x "$workdir/install" \
        || error "Could not make install script executable"
}

rm_scripts()
{
    # some files can be owned by root depending on
    # timing, retry with sudo on error
    if ! rm -rf "$workdir"; then
        echo "Cleaning up work dir failed, trying again with sudo" >&2
        sudo rm -rf "$workdir"
    fi
}

exit_handler()
{
    local ret=$?

    set +e

    cd "$outdir" && rm_scripts
    if [ $ret != 0 ]; then
        echo "error occured."
    fi

    return $ret
}

int_handler()
{
    exit_handler
    local ret=$?

    echo "caught interrupt"
    exit $ret
}

build_sbom()
{
    "$scriptdir/build_sbom.sh" -i "$output" -c "$sbom_config" -f "$output" \
            ${sbom_external:+-e "$sbom_external"} \
        || error "Could not build sbom"
    mv -f "$workdir/$output.spdx.json" "$outdir" \
        || error "Could not move sbom to $outdir"
}

#######
# Main
#######
if [ -e .git ]; then
    # first submodule update -i checks out if required (diff-index
    # does not consider not checked out submodules as different...)
    # then force if there is any problem, including sync to force
    # URL change.
    if ! git submodule update -i \
            || ! git diff-index --ignore-submodules=untracked --quiet HEAD submodules; then
        git submodule update -i --force \
            || { git submodule sync && git submodule update -i --force; } \
            || error "Could not update git submodules"
    fi
    SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
elif [ -e .release_epoch ]; then
    SOURCE_DATE_EPOCH="$(cat .release_epoch)"
else
    SOURCE_DATE_EPOCH="$(date +%s)"
fi
export SOURCE_DATE_EPOCH

if ! "$DOCKER" image inspect "$alpine_container" > /dev/null; then
    echo "trying to build required alpine container"
    (
        cd submodules/containers &&
            DOCKER="$DOCKER" BUILDARCHS="$arch" VERSION="${alpine_version#v}" \
                ./build.sh
    ) || error "Could not build alpine container"
fi

trap exit_handler EXIT
trap int_handler INT

scriptdir=$(realpath "$(dirname "$0")")
workdir="$(mktemp -d -t alpine-build-rootfs.XXXXXX)" \
    || error "Could not create workdir"

get_scripts
cp -r common/resources/. "$workdir/resources" \
    || error "Could not copy resources to workdir"
if [ -e "$board/resources" ]; then
    cp -r "$board/resources/." "$workdir/resources/" \
        || error "Could not copy board resources to workdir"
fi

cache_ro=
if [ -d "$cache" ]; then
    cache_dir="$cache"
    if [ -e "$cache_dir/installed" ]; then
        echo "Reusing cache in $cache"
        cache_ro=1
    else
        echo "cache dir $cache does not look like a fully initialized cache, creating a new one"
        rm -rf "$cache_dir"
    fi
elif [ "${cache%.tar}" != "$cache" ]; then
    cache_dir="${cache##*/}"
    cache_dir="$workdir/${cache_dir%.tar}"
    if [ -e "$cache" ]; then
        mkdir "$cache_dir"
        tar -C "$cache_dir" --xform 's@[^/]*@.@' -xf "$cache" \
            || error "extraction of cache $cache failed"
        if [ -e "$cache_dir/installed" ]; then
            cache_ro=1
            echo "Reusing cache from $cache"
        else
            echo "$cache existed but it does not look like a fully initialized cache, creating a new one"
            rm -rf "$cache_dir"
            rm -f "$cache"
        fi
    else
        echo "Populating new cache archive $cache"
    fi
elif [ -n "$cache" ]; then
    [ -e "$cache" ] && error "Cache $cache is neither a directory or a tar"
    echo "Populating new cache in $cache"
    cache_dir="$cache"
else
    # no cache output, use temporary directory
    cache_dir="$workdir/cache"
fi
if [ -n "$cache_dir" ]; then
    mkdir -p "$cache_dir"
fi
if [ -n "$cache_rw" ]; then
    # allow network and make script refresh metadata if expired
    cache_ro=""
    rm -f "$cache_dir/installed"
fi

cd "$workdir" \
    || error "Could not enter workdir"
"$DOCKER" run --privileged --rm -v "$workdir":/build -w /build \
        --env SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
        ${cache_dir:+-v "$cache_dir:/cache"} \
        ${cache_ro:+--net=none} \
        ${platform:+--platform "$platform"} \
        "$alpine_container" /build/build-alpine.sh \
    || error "Failed building image"


if [ "${cache%.tar}" != "$cache" ] && [ -z "$cache_ro" ]; then
    tar -C "$workdir" -cf "$cache" \
            --numeric-owner --sort=name --clamp-mtime \
            --mtime="@$(stat -c %Y "$workdir/rootfs.tar")" \
            --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            "${cache_dir##*/}" \
        || error "Could not create cache $cache"
fi

$comp "$workdir/rootfs.tar" \
        || error "Failed compressing rootfs"

rootfs_footprint=$(cat "$workdir/rootfs_footprint_kbyte")000
tarball_size=$(stat -c %s "$workdir/rootfs.$extension")
if [ "${output%ATVERSION*}" != "$output" ]; then
    [ -e "$workdir/atmark-release" ] \
        || error "ATVERSION required for output name, but atmark-release was not created"
    atmark_version=$(cat "$workdir/atmark-release")
    output="${output%ATVERSION*}${atmark_version}${output#*ATVERSION}"
fi

mv -f "$workdir/rootfs.$extension" "$workdir/$output" \
    || error "Failed renaming rootfs"

if [ -n "$signkey" ]; then
    openssl cms -sign -in "$workdir/$output" -out "$workdir/$output.sig" \
            -signer "$signcert" -inkey "$signkey" -outform DER \
            -nosmimecap -binary \
        || error "Could not sign tarball"
fi

echo "name,footprint[byte],tarball[byte],packages" > "$workdir/footprint.csv"
echo "${output%.$extension},$rootfs_footprint,$tarball_size,$packages" >> "$workdir/footprint.csv"

echo "============================================"
printf "footprint[byte]  tarball[byte]  packages\n"
printf "%15d  %13d  %s\n" \
       "$rootfs_footprint" \
       "$tarball_size" \
       "$packages"
echo "============================================"

[ -z "$nosbom" ] && build_sbom

! [ -e "$workdir/$output.sig" ] \
    || mv -f "$workdir/$output.sig" "$outdir" \
    || error "Could not move signature to $outdir"
mv -f "$workdir/$output" "$workdir/footprint.csv" "$outdir" \
    || error "Could not move rootfs to $outdir"
mv -f "$workdir/rootfs_apk_list" "$outdir/${output%.tar*}.package_list.txt" \
    || error "Could not move package list to $outdir"

echo
echo "Successfully built $outdir/$output"
