#!/bin/sh
# SPDX-License-Identifier: MIT

# This script is a simple wrapper around make_sbom.py,
# with two purposes:
# - install deps in a subdir to avoid user making a virtual env themselves
# - fixup all paths given so we can cd into main input's directory as that
#   is a current script limitation. When that limitation is lifted this
#   script can be simplified greatly to just run make_sbom.py "$@" directly
#   with only python deps fixed up -- defaults can be set from python

usage() {
    echo "
USAGE:
  $(basename "$0") [OPTIONS] [OUTPUT]

  OPTIONS:
    -i|--input <file>               -- name of the file for which
                                        the sbom is to be created
    -c|--config <yaml>              -- file in yaml format for creating sbom.
                                        default value is config.yaml
    -d|--debug                      -- set log output level to debug
    -e|--external_sbom <spdx.json>  -- external .sbom.json file(s) to add to
                                        the sbom you are creating
    -o|--output <sbom file name>    -- file name of the sbom to be created
    -p|--package <package_list>     -- *package_list.txt created by build_rootfs
                                        e.g. baseos-x2-3.18.4-at.5.package_list.txt
    -f|--file <scan file>           -- created sbom from file(s).
    -h|--help                       -- this output

  OUTPUT:
    created sbom.json (<input>.sbom.json)
"
}

error() {
    echo "$@" >&2
    exit 1
}

required_input() {
    usage >&2
    error "-i|--input <file> option is a required parameter"
}

SCRIPTDIR="$(realpath "$(dirname "$0")")"

switch=""
input_seen=""
config_seen=""
output_seen=""
container_scan=""

for arg in "$@"; do
    # always consume exactly one argument to keep in sync
    shift
    if [ -z "$switch" ]; then
        case "$arg" in
        "-i" | "--input")
            switch=input
            ;;
        "-c" | "--config")
            switch=config
            ;;
        "-d" | "--debug")
            set -- "$@" --debug
            ;;
        "-e" | "--external_sbom")
            switch=external_sbom
            ;;
        "-o" | "--output")
            switch=output
            ;;
        "-p" | "--package")
            switch=package
            ;;
        "-f" | "--file")
            switch=file
            ;;
        "-h" | "--help")
            usage
            exit 0
            ;;
        *)
            echo "Invalid option $arg" >&2
            usage >&2
            exit 1
            ;;
        esac
        continue
    fi
    case "$switch" in
    input)
        input_seen="$arg"
        [ -e "$arg" ] || error "input $arg does not exist"
        input_dir=$(dirname "$arg")
        input_base="$(basename "$arg")"
        set -- "$@" --input "$input_base"
        ;;
    config)
        config_seen=1
        [ -e "$arg" ] || error "config $arg does not exist"
        set -- "$@" --config "$(realpath "$arg")"
        ;;
    external_sbom)
        [ -e "$arg" ] || error "external sbom $arg does not exist"
        set -- "$@" --external_sbom "$(realpath "$arg")"
        ;;
    output)
        output_seen=1
        set -- "$@" --output "$(realpath "$arg")"
        ;;
    package)
        set -- "$@" --package "$(realpath "$arg")"
        ;;
    file)
        container_scan=1
        input_seen=1
        set -- "$@" --file "$(realpath "$arg")"
        ;;
    esac
    switch=""
done

[ -z "$switch" ] || error "Processing --$switch but no arg given?"
[ -n "$input_seen" ] || required_input
if [ -z "$output_seen" ]; then
    # If output is not specified, SBOM is output to the current directory
    set -- "$@" --output "$PWD/$input_base.spdx.json"
fi
if [ -z "$config_seen" ]; then
    # use config.yaml in script dir, which should always exist...
    set -- "$@" --config "$SCRIPTDIR/config.yaml"
fi

deps="$SCRIPTDIR/deps"
env_file="$deps/env"
if [ -e "$env_file" ]; then
    . "$env_file"
fi
# shellcheck disable=SC3013 # dash, busybox ash and mksh all support -nt
if ! [ -e "$deps/.stamp" ] ||
    [ "$SCRIPTDIR/requirements.txt" -nt "$deps/.stamp" ] ||
    ! PYTHONPATH="$deps" python3 -m spdx_tools.spdx.clitools.pyspdxtools --help >/dev/null 2>&1; then
    # install if missing, or update if requirements changed,
    # or could not use it
    rm -rf "$deps"
    python3 -m pip install --target "$deps" -r "$SCRIPTDIR/requirements.txt" ||
        error "Could not install python deps - missing python or pip?"
    touch "$deps/.stamp"
fi

if [ -n "$container_scan" ]; then
	which_syft=$(which syft)
    if [ -z "${which_syft}" ]; then
	    echo syft is not found and install start
	    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b "$deps" v1.6.0
        if [ -e "$deps/syft" ]; then
            echo syft install success!
            if [ ! -e "$env_file" ]; then
                touch "$env_file"
            fi
            echo "export SYFT_CHECK_FOR_APP_UPDATE=false" >> "$env_file"
            echo "export PATH=\"$deps:\$PATH\"" >> "$env_file"
            . "$env_file"
        else
            echo syft install failed.
            exit
        fi
    fi
fi

# make_sbom.py currently only works with input in current directory
if [ -n "$input_dir" ]; then
    cd "$input_dir" || exit
fi
PYTHONPATH="$deps" \
    python3 "$SCRIPTDIR/make_sbom.py" \
    "$@"
