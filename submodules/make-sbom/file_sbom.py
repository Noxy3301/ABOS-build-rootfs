#  SPDX-FileCopyrightText: 2023 Atmark Techno contributors
#
#  SPDX-License-Identifier: MIT

import os
import subprocess
import json
import logging
import sys

from typing import List, Any

from spdx_tools.spdx.parser.jsonlikedict.json_like_dict_parser import JsonLikeDictParser
from spdx_tools.spdx.validation.uri_validators import validate_download_location
from spdx_tools.spdx.model import (
    Package,
    File,
    SpdxNoAssertion,
    Relationship,
    RelationshipType,
)


class FileSbom:
    def __init__(self, filepath: str) -> None:
        self.target = None
        self.document = self.get_tarball_sbom(filepath)
        self.packages = self.document.packages
        self.relationships = self.document.relationships
        self.files = self.document.files
        self.extracted_licensing_info = self.document.extracted_licensing_info

    def get_tarball_sbom(self, filepath: str):
        file_name = os.path.basename(filepath)
        try:
            syft_output = subprocess.run(['syft', '-o', 'spdx-json@2.2', filepath], capture_output=True, check=True)
        except subprocess.CalledProcessError as err:
            logging.error(err.stderr.decode())
            sys.exit(1)
        syft_dict = json.loads(syft_output.stdout)
        document = JsonLikeDictParser().parse(syft_dict)

        # packages
        for package in document.packages:
            package = self.check_package_element(package)
            if file_name == package.name:
                self.target = package
            elif filepath == package.name:
                self.target = package
                self.target.name = file_name
            if not package.files_analyzed:
                document = self.remove_package_unknown_file(package, document)

        # files
        for file in document.files[:]:
            file.name = os.path.basename(file.name)
            file.license_info_in_file = [SpdxNoAssertion()]
            cksum = file.checksums[0].value
            if cksum == '0' * len(cksum):
                self.remove_file(document, file)
        return document

    def remove_file(self, document: Any, file: File):
        for relation in document.relationships[:]:
            if file.spdx_id == relation.related_spdx_element_id:
                document.relationships.remove(relation)
        document.files.remove(file)

    def check_package_element(self, package: Package):
        if not package.files_analyzed:
            package.verification_code = None
        if not self.is_valid_download_location(str(package.download_location)):
            package.download_location = SpdxNoAssertion()
        return package

    def remove_package_unknown_file(self, package: Package,
                                    document: Any):
        remove_files = []
        remove_relations = []
        for relation in document.relationships:
            if package.spdx_id == relation.spdx_element_id and \
                relation.relationship_type == RelationshipType.CONTAINS:
                for file in document.files:
                    if relation.related_spdx_element_id == file.spdx_id:
                        remove_files.append(file)
                        remove_relations.append(relation)

        for remove_file in remove_files:
            document.files.remove(remove_file)
        for remove_relation in remove_relations:
            document.relationships.remove(remove_relation)
        return document

    def is_valid_download_location(self, url: str):
        if len(validate_download_location(url)) > 0:
            return False
        return True

    def get_relationships(self, spdx_id: str) -> List[Relationship]:
        if self.target:
            self.relationships.append(
                Relationship(
                    spdx_element_id=spdx_id,
                    relationship_type=RelationshipType.CONTAINS,
                    related_spdx_element_id=self.target.spdx_id,
                )
            )
        return self.relationships
