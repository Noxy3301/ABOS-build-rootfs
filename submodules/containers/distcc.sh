#!/bin/bash

# config

# archs to build
: "${VERSION=3.20}"

# mapping from alpine version to pmos version
# required to have matching cross gcc versions
declare -A PM_VERSIONS=(
	[3.15]=v21.12
	[3.16]=v22.06
	[3.17]=v22.12
	[3.18]=v23.06
	[3.19]=v23.12
	[3.20]=v24.06
)
declare -A GCC_ARCHS=(
	[3.15]=aarch64
)

if [[ -z "${PM_VERSIONS[$VERSION]}" ]]; then
	PM_VERSIONS[$VERSION]="master"
fi
if [[ -z "${GCC_ARCHS[$VERSION]}" ]]; then
	GCC_ARCHS[$VERSION]="aarch64 armv7"
fi

if [[ -z "$DOCKER" ]]; then
	command -v podman > /dev/null && DOCKER=podman
	command -v docker > /dev/null && DOCKER=docker
fi
if [[ -z "$DOCKER" ]] || ! command -v "$DOCKER" > /dev/null; then
	echo "docker or podman not found, install either or set \$DOCKER appropriately" >&2
	exit 1
fi

if ! "$DOCKER" image inspect alpine-${VERSION}-x86_64 >/dev/null 2>&1; then
	BUILDARCHS=x86_64 VERSION="$VERSION" DOCKER="$DOCKER" \
		"$(dirname "$0")"/build.sh
fi

packages=""
for arch in ${GCC_ARCHS[$VERSION]}; do
	packages="$packages gcc-$arch g++-$arch"
done

"$DOCKER" build --build-arg "version=${VERSION}" \
		--build-arg "pm_version=${PM_VERSIONS[$VERSION]}" \
		--build-arg "packages=${packages}" \
		-t "distcc-${VERSION}" \
		distcc
