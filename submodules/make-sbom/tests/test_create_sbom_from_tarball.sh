#!/bin/bash -x

# SPDX_ID_FILE
# CONFIG_FILE
# TARBALL_FILE

is_exist_files(){
	for FILE in "${@}"; do
		if [ ! -e "${FILE}" ]; then
			echo "${FILE} is not found."
			exit
		fi
	done
}

test_env(){
	export SPDX_ID_FILE=a6e-gw-container-2.5.2.swu
	export CONFIG_FILE=gw_container_config.yaml
	export TARBALL_FILE=a6e-gw-container-image.tar

	is_exist_files ${SPDX_ID_FILE} ${CONFIG_FILE} ${TARBALL_FILE}
}

make_sbom(){
	./jenkins/create_sbom_from_tarball.sh \
		-i ${SPDX_ID_FILE}  \
		-c ${CONFIG_FILE} \
		-f ${TARBALL_FILE}
}

is_exist_spdx_file(){
	OUTPUT_SPDX_FILE=${SPDX_ID_FILE}".spdx.json"
	if [ -e "${OUTPUT_SPDX_FILE}" ]; then
		echo "${OUTPUT_SPDX_FILE} is success!"
	else
		echo "${OUTPUT_SPDX_FILE} is not found....."
		return -1
	fi
}

test_env
make_sbom
is_exist_spdx_file
