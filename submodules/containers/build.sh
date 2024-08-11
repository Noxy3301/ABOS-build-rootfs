#!/bin/bash

# config

# archs to build
: "${BUILDARCHS="x86_64 armv7 aarch64"}"
: "${VERSION=3.20}"

# mapping from docker arch to alpine arch
declare -A ARCH_MAP=( [x86_64]=amd64 [armhf]=arm32v6 [armv7]=arm32v7 [aarch64]=arm64v8 )

if [[ -z "$AT_VERSION" ]]; then
	AT_VERSION="$VERSION"
	[[ "$VERSION" = edge ]] && AT_VERSION=3.20
fi

if [[ -z "$DOCKER" ]]; then
	command -v podman > /dev/null && DOCKER=podman
	command -v docker > /dev/null && DOCKER=docker
fi
if [[ -z "$DOCKER" ]] || ! command -v "$DOCKER" > /dev/null; then
	echo "docker or podman not found, install either or set \$DOCKER appropriately" >&2
	exit 1
fi

for arch in $BUILDARCHS; do
	if [[ -z "${ARCH_MAP[$arch]}" ]]; then
		echo "$arch is not a valid arch, must be in ${!ARCH_MAP[*]}"
		exit 1
	fi
	"$DOCKER" build --build-arg "arch=${ARCH_MAP[$arch]}" \
		--build-arg "version=${VERSION}" \
		--build-arg "at_version=${AT_VERSION}" \
		-t "alpine-${VERSION}-$arch" \
		baseos
done
