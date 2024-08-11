#  SPDX-FileCopyrightText: 2023 Atmark Techno contributors
#
#  SPDX-License-Identifier: MIT

# pyright: reportPrivateImportUsage=false

import logging
import csv
import re

from license_expression import get_spdx_licensing, ExpressionError, LicenseExpression
from spdx_tools.spdx.model import (
    Package,
    SpdxNoAssertion,
    Relationship,
    RelationshipType,
)
from typing import List, Union

from rename_license import debian_license
from utility import get_spdx_id


class PackageInfo:
    def __init__(self, name: str, version: str, license: Union[str, list[str]]) -> None:
        self.name = name
        self.version = version
        self.license_concluded = None
        self.license_info_from_files = None
        self.license_comment = None

        # If there is only one license, it should be listed in license_concluded.
        if isinstance(license, str):
            self.license_concluded = self.get_spdx_license(name, license)
            # If the license cannot be inferred,
            # include the original inferred license in license_comment
            if self.license_concluded == SpdxNoAssertion():
                self.license_comment = f"The following licenses could not be estimated '{license}'"
        else:
            self.license_concluded = SpdxNoAssertion()
            self.license_info_from_files = self.get_license_info_from_files(name, license)
            # If a license that cannot be inferred is included,
            # include the license from which it was inferred in the license_comment.
            if SpdxNoAssertion() in self.license_info_from_files:
                self.license_comment = \
                    f"It was not possible to estimate all of the following licenses. '{' '.join(license)}'"

    def get_spdx_license(self, name: str, license: str, validate=True) -> str:
        # Receive ExpressionError if license cannot be obtained
        try:
            spdx_license = get_spdx_licensing().parse(license, validate=validate)
        except ExpressionError:
            spdx_license = SpdxNoAssertion()
            logging.debug(f"Failed to parse {name} license: {license}")
        return spdx_license

    def get_license_info_from_files(self, name: str, licenses: list[str])\
            -> List[Union[LicenseExpression, SpdxNoAssertion]]:
        return [self.get_spdx_license(name, license) for license in licenses]


class PackagesSbom:
    def __init__(self, filepath: str) -> None:
        self.packages = self.get_packages_sbom(filepath)

    def get_relationships(self, spdx_id: str) -> List[Relationship]:
        return [
            Relationship(
                spdx_element_id=spdx_id,
                relationship_type=RelationshipType.CONTAINS,
                related_spdx_element_id=package.spdx_id,
            )
            for package in self.packages
        ]

    def alpine_packages_parse(self, file_lines: list[str]) -> List[PackageInfo]:
        # Stored in a space-separated two-dimensional array
        # Data is stored as follows
        # ['abos-base-2.0-r1', 'aarch64', '{abos-base}', '(MIT)', '[installed]\n']
        extract_re = re.compile(r"([^ ]*)-(\d.*?-r\d+) [^(]*\(([^)]*)\)")

        packages_info = []
        for line in file_lines:
            package = extract_re.match(line)
            if package is None:
                logging.warning("Could not parse line: %s", line)
                continue
            name, version, license = package.groups()
            packages_info.append(PackageInfo(name, version, license))

        return packages_info

    def debian_packages_parse(self, file_lines: list[str]) -> List[PackageInfo]:
        # Data is stored as csv with such fields:
        # ['St', 'Name', 'Version', 'Arch', 'Description', 'Licenses']
        # ['ii', 'adduser', '3.134', 'all', 'add and remove users and groups', 'GPL-2+']

        reader = csv.DictReader(file_lines)

        packages_info = []
        for package in reader:
            # dpkg-license output may contain architecture, remove it
            name = package['Name'].replace(":armhf", "").replace(":arm64", "")
            version = package['Version']
            license = package['Licenses']

            # If there are multiple licenses, change to list type and
            # rename debian license name to SPDX license
            if " " in license:
                # Linux-syscall-note Split by whitespace character
                # except with because the license requires with
                extract_re = re.compile(r"(?<!\bwith)\s+(?!\bwith)")
                license = [debian_license(license) for license in extract_re.split(license)]
            else:
                license = debian_license(license)

            packages_info.append(PackageInfo(name, version, license))

        return packages_info

    def packages_parse(self, filepath: str) -> List[PackageInfo]:
        with open(filepath) as file:
            content = file.readlines()
            # debian packages (dpkg-licenses -c) start with a csv header
            if content[0].startswith('"St",'):
                return self.debian_packages_parse(content)
            # alpine package
            return self.alpine_packages_parse(content)

    def get_packages_sbom(self, filepath: str) -> List[Package]:
        packages_info = self.packages_parse(filepath)
        packages = []

        for package_info in packages_info:
            packages += [
                Package(
                    spdx_id=get_spdx_id(package_info.name, uuid=True),
                    name=package_info.name,
                    download_location=SpdxNoAssertion(),
                    version=package_info.version,
                    license_concluded=package_info.license_concluded,
                    license_info_from_files=package_info.license_info_from_files,
                    license_declared=SpdxNoAssertion(),
                    license_comment=package_info.license_comment,
                    copyright_text=SpdxNoAssertion(),
                    files_analyzed=False if package_info.license_info_from_files is None else True,
                )
            ]
        return packages
