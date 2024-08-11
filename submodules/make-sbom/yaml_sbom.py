#  SPDX-FileCopyrightText: 2023 spdx contributors
#
#  SPDX-License-Identifier: MIT

# pyright: reportPrivateImportUsage=false

import logging
from box import Box
from datetime import datetime
from hashlib import sha1, sha256
from typing import List
from yaml import safe_load

from license_expression import get_spdx_licensing
from spdx_tools.spdx.model import (
    Actor,
    ActorType,
    Checksum,
    ChecksumAlgorithm,
    CreationInfo,
    Document,
    Package,
    PackageVerificationCode,
    Relationship,
    RelationshipType,
    SpdxNoAssertion,
)

from utility import get_spdx_id


class YamlSbom:
    def __init__(
        self,
        file: str,
        yaml: str = "config.yaml",
    ) -> None:
        self.spdx_id = get_spdx_id(file)

        with open(yaml) as f:
            self.yaml = Box(safe_load(f), default_box=True)
        self.document = self.make_document(file, self.yaml)
        self.packages = self.make_packages(file, self.yaml)

    def check_no_assertion(self, value):
        return value if value else SpdxNoAssertion()

    def check_license_no_assertion(self, value):
        return get_spdx_licensing().parse(value) if value else SpdxNoAssertion()

    def make_document(self, file: str, yaml: Box) -> Document:
        # Format to match pyspdxtools datetime format
        date = datetime.now()
        date = datetime(
            date.year, date.month, date.day, date.hour, date.minute, date.second
        )

        yaml.Document.creators = self.set_creators_actor_type(yaml.Document.creators)

        creation_info = CreationInfo(
            spdx_version="SPDX-2.2",
            spdx_id="SPDXRef-DOCUMENT",
            name=file,
            data_license="CC0-1.0",
            document_namespace=yaml.Document.documentNamespace,
            creators=yaml.Document.creators,
            created=date,
        )
        document = Document(creation_info)

        # Describe the relationship between documents and packages
        document.relationships += [
            Relationship(
                "SPDXRef-DOCUMENT",
                RelationshipType.DESCRIBES,
                self.spdx_id,
            )
        ]
        return document

    def make_packages(self, file: str, yaml: Box) -> List[Package]:
        packages = []
        with open(file, "rb") as f:
            text = f.read()
            file_sha1 = sha1(text).hexdigest()
            file_sha256 = sha256(text).hexdigest()

        for key in yaml.Package.keys():
            package = yaml.Package[key]

            if key == "mainPackage":
                name = file
                spdx_id = self.spdx_id
                file_name = f"./{file}"
                files_analyzed = True
                verification_code = PackageVerificationCode(value=file_sha1)
                checksum = [
                    Checksum(ChecksumAlgorithm.SHA256, file_sha256),
                ]
            else:
                spdx_id = get_spdx_id(key)
                name = key
                file_name = None
                files_analyzed = False
                verification_code = None
                checksum = []
                self.document.relationships += [
                    Relationship(
                        spdx_id,
                        RelationshipType.ANCESTOR_OF,
                        self.spdx_id,
                    )
                ]

            downloadLocation = self.check_no_assertion(package.downloadLocation)
            copyright = self.check_no_assertion(package.copyrightText)
            license_concluded = self.check_license_no_assertion(
                package.licenseConcluded
            )
            license_declared = self.check_license_no_assertion(package.licenseDeclared)

            packages += [
                Package(
                    name=name,
                    spdx_id=spdx_id,
                    download_location=downloadLocation,
                    version=str(package.version),
                    file_name=file_name,
                    files_analyzed=files_analyzed,
                    verification_code=verification_code,
                    checksums=checksum,
                    license_concluded=license_concluded,
                    license_declared=license_declared,
                    copyright_text=copyright,
                )
            ]
        return packages

    def set_creators_actor_type(self, creators):
        # Change creators defined in yaml to enum
        creators = [self.set_actor_type(creator) for creator in creators]
        return creators

    def set_actor_type(self, creator):
        for key in creator.to_dict().keys():
            if key == "Organization":
                actor_type = ActorType.ORGANIZATION
            elif key == "Person":
                actor_type = ActorType.PERSON
            elif key == "Tool":
                actor_type = ActorType.TOOL
            else:
                logging.exception(f"Unknown creator key: {key}")
                exit()
            actor = Actor(actor_type=actor_type, name=creator.to_dict()[key])
            return actor
