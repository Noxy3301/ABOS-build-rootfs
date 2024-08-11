#!/bin/sh

cd "$(dirname "$0")" || exit

fixup_spdx() {
    local file="$1"

    # fix up uuid in SPDXRef to generate reproductible output...
    # make_sbom needs a reproducible mode...
    awk '{
        if ($0 ~ /"created": "[0-9T:-]*Z"/) {
            gsub(/"[0-9T:-]*Z"/, "\"1970-01-01T00:00:00Z\"")
        }
        if (match($0, /SPDXRef-(.*)-([a-f0-9-]{36})"/, m)) {
            id=m[2];
            new=newid[id];
            if (!new) {
                new=newid[id]=idx++;
            }
            gsub(id, new);
        }
        print
    }' "$file" > "$file.tmp" \
        && mv "$file.tmp" "$file" \
        || exit
}

# parsing package list works
for list in package_list.alpine.txt package_list.debian.txt; do
    # we use list as input too, doesn't matter..
    ../make_sbom.sh -i "$list" -c ../config.yaml -p "$list" || exit
    fixup_spdx "$list.spdx.json"
done

# checking the 'cd' part of the script works
(
    dir=$PWD
    cd ../..
    "$dir/../make_sbom.sh" -i "$dir/package_list.alpine.txt" \
        -c "$dir/../config.yaml" \
        -o "$dir/test_cd.spdx.json" || exit
    fixup_spdx "$dir/test_cd.spdx.json"
) || exit

# check external sbom
../make_sbom.sh -i imx-boot_armadillo_x2_2020.04-at21.spdx.json \
    -c ../config.yaml \
    -e imx-boot_armadillo_x2_2020.04-at21.spdx.json \
    -o imx-boot_armadillo_x2_2020.04-at21.spdx.json.spdx.json || exit
fixup_spdx imx-boot_armadillo_x2_2020.04-at21.spdx.json.spdx.json

# check 2 external sboms
../make_sbom.sh -i a6e-gw-container-2.4.1.swu.spdx.json \
    -c ../config.yaml \
    -e imx-boot_armadillo_x2_2020.04-at21.spdx.json \
    -e a6e-gw-container-2.4.1.swu.spdx.json \
    -o a6e-gw-container-2.4.1.swu.spdx.json.spdx.json || exit
fixup_spdx a6e-gw-container-2.4.1.swu.spdx.json.spdx.json

# check git diff output manually for now!!
