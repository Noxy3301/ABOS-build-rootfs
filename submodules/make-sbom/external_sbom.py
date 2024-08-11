#  SPDX-FileCopyrightText: 2023 Atmark Techno contributors
#
#  SPDX-License-Identifier: MIT


import logging
from typing import Any, List

from spdx_tools.spdx.model import Relationship, RelationshipType
from spdx_tools.spdx.parser.error import SPDXParsingError
from spdx_tools.spdx.parser.parse_anything import parse_file

from utility import get_spdx_id


class ExternalSbom:
    def __init__(self, filepath: str) -> None:
        self.document = self.spdx_parse(filepath)
        self.packages = self.remove_file_name(self.document.packages)
        self.files = self.document.files
        self.extracted_licensing_info = self.document.extracted_licensing_info

    def spdx_parse(self, filepath: str):
        try:
            # Try to parse the input file. If successful, returns a Document, otherwise raises an SPDXParsingError
            document: Any = parse_file(filepath)
        except SPDXParsingError:
            logging.exception("Failed to parse spdx file")
            exit()
        return document

    def remove_file_name(self, packages):
        for package in packages:
            package.file_name = None
        return packages

    def get_relationships(self, spdx_id: str):
        relationships = self.remove_root_relationship()
        # Add an external sbom as a CONTAINS
        # relationship to the sbom to be created
        relationships += [
            Relationship(
                spdx_id,
                RelationshipType.CONTAINS,
                get_spdx_id(self.document.creation_info.name),
            )
        ]
        return relationships

    def remove_root_relationship(self) -> List[Relationship]:
        # Delete SPDXRef-DOCUMENT relationship as it replaces it.
        return [
            relationship
            for relationship in self.document.relationships
            if (relationship.spdx_element_id != "SPDXRef-DOCUMENT")
        ]
