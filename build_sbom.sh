#!/bin/sh
# SPDX-License-Identifier: MIT

SCRIPT="$(realpath "$(dirname "$0")/submodules/make-sbom/make_sbom.sh")"
exec "$SCRIPT" "$@"
