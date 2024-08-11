#!/usr/bin/env python3

#  SPDX-FileCopyrightText: 2023 Atmark Techno contributors
#
#  SPDX-License-Identifier: MIT

# pyright: reportPrivateImportUsage=false

import logging
from argparse import ArgumentParser, Namespace
from os import path
from typing import List

from spdx_tools.spdx.writer.write_anything import write_file

from external_sbom import ExternalSbom
from packages_sbom import PackagesSbom
from file_sbom import FileSbom
from yaml_sbom import YamlSbom
from utility import get_spdx_id
from spdx_tools.spdx.model import (
    Document
)


def get_option() -> Namespace:
    parser = ArgumentParser()
    parser.add_argument(
        "-i",
        "--input",
        help="name of the file for which. the sbom is to be created",
    )
    parser.add_argument(
        "-c",
        "--config",
        help="file in yaml format for creating sbom. Default is config.yaml",
    )
    parser.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="set log output level to debug",
    )
    parser.add_argument(
        "-e",
        "--external_sbom",
        help="external .sbom.json to add to the sbom you are creating (multiple allowed)",
        action="append",
        default=[],
    )
    parser.add_argument("-o", "--output", help="file name of the sbom to be created")
    parser.add_argument(
        "-p", "--package", help="*package_list.txt created by build_rootfs"
    )
    parser.add_argument(
        "-f", "--file", help="create sbom include scan results to main sbom output if created",
        action="append", default=[],
    )
    return parser.parse_args()

def output_sbom(document, output, file):
    if output is None:
        out_file = f"{file}.spdx.json"
    else:
        out_file = (
            output
            if output.endswith(".spdx.json")
            else f"{output}.spdx.json"
        )
    write_file(document, out_file)
    logging.info("created " + path.basename(out_file))

def main():
    args = get_option()
    log_level = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(level=log_level)
    document = None
    if args.input:
        filename = path.basename(args.input)
        if filename is not args.input:
            logging.error(
                "-i, --input argument must be in the current directory"
            )
            exit()
        spdx_id = get_spdx_id(filename)
        yaml_config = args.config or "config.yaml"
        if not path.exists(yaml_config):
            logging.error(
                "config file '%s' does not exist", yaml_config
            )
            exit()
        yaml_sbom = YamlSbom(filename, yaml_config)
        document = yaml_sbom.document
        # This library uses run-time type checks when assigning properties.
        # Because in-place alterations like .append() circumvent these checks, we don't use them here.
        document.packages = [*yaml_sbom.packages]
    logging.info("Building SBOM...")
    if document:
        if args.package:
            logging.info("package information is created from package list")
            logging.warning("not created purl in package information")
            packages_sbom = PackagesSbom(args.package)
            document.packages += [*packages_sbom.packages]
            document.relationships += [*packages_sbom.get_relationships(spdx_id)]
        for sbom in args.external_sbom:
            external_sbom = ExternalSbom(sbom)
            document.packages += [*external_sbom.packages]
            document.relationships += [*external_sbom.get_relationships(spdx_id)]
            document.files += [*external_sbom.files]
            document.extracted_licensing_info += [*external_sbom.extracted_licensing_info]
    for file in args.file:
        file_sbom = FileSbom(file)
        if document:
            document.packages += [*file_sbom.packages]
            document.relationships += [*file_sbom.get_relationships(spdx_id)]
            document.files += [*file_sbom.files]
            document.extracted_licensing_info += [*file_sbom.extracted_licensing_info]
        else:
            file_doc = file_sbom.document
            output_sbom(file_doc, None, file)
    if document:
        output_sbom(document, args.output, filename)

if __name__ == "__main__":
    main()
