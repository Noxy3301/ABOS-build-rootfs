#  SPDX-FileCopyrightText: 2023 Atmark Techno contributors
#
#  SPDX-License-Identifier: MIT

from uuid import uuid4


def get_spdx_id(name: str, uuid=False) -> str:
    spdx_id = f"SPDXRef-{name.replace('_', '-').replace('+', 'p')}"
    return f"{spdx_id}-{uuid4()}" if uuid else spdx_id
