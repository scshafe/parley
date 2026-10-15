"""The style instructions sent with every turn ("Answers written for speech").

The text lives in a versioned file, ``prompts/<version>.md``; a turn records
which version it was answered under. A new wording is a new file and a new
``CURRENT``, never an edit of a published one.
"""

from __future__ import annotations

from functools import cache
from importlib import resources

CURRENT = "style-v1"


@cache
def instructions(version: str = CURRENT) -> str:
    return resources.files("parley_relay").joinpath("prompts", f"{version}.md").read_text("utf-8").strip()
