"""The relay's backstop cleanup: from the agent's reply to the text that is both
shown and spoken.

The style instructions ask the agent for plain prose (prompts/style-v1.md). Whatever
slips through is cleaned here: markdown is stripped, bare URLs become "a link",
code and an ``<attachment>`` block move to the attachment the app shows below the
reply. Every change is recorded. The result's ``text`` is sent to voice-lab as is
and shown as is, so the follow-along highlighting can index it directly.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

_ATTACHMENT = re.compile(r"<attachment>(.*?)(?:</attachment>|\Z)", re.IGNORECASE | re.DOTALL)
_FENCE = re.compile(r"^[ \t]*(```|~~~)[^\n]*\n(.*?)(?:^[ \t]*\1[ \t]*$|\Z)", re.DOTALL | re.MULTILINE)
_IMAGE = re.compile(r"!\[([^\]\n]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_LINK = re.compile(r"\[([^\]\n]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_AUTOLINK = re.compile(r"<(https?://[^>\s]+)>")
_URL = re.compile(r"\b(?:https?://|www\.)[^\s<>()\[\]]+", re.IGNORECASE)
_HEADING = re.compile(r"^[ \t]*#{1,6}[ \t]+(.*?)[ \t#]*$", re.MULTILINE)
_BULLET = re.compile(r"^[ \t]*(?:[-*+•]|\d{1,3}[.)])[ \t]+(.*)$", re.MULTILINE)
_QUOTE = re.compile(r"^[ \t]*>[ \t]?", re.MULTILINE)
_RULE = re.compile(r"^[ \t]*(?:[-*_][ \t]*){3,}$", re.MULTILINE)
_TABLE_SEP = re.compile(r"^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$", re.MULTILINE)
_TABLE_ROW = re.compile(r"^[ \t]*\|(.*)\|[ \t]*$", re.MULTILINE)
_BOLD = re.compile(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1")
_ITALIC_STAR = re.compile(r"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])")
_ITALIC_UNDERSCORE = re.compile(r"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])")
_STRIKE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
_INLINE_CODE = re.compile(r"`([^`\n]+)`")
_TERMINAL = tuple(".!?…:;。！？")

EMPTY_REPLY = "I've put the details on the screen."


@dataclass
class Cleaned:
    text: str
    attachment: str | None
    changes: list[dict[str, object]] = field(default_factory=list)


def _is_emoji(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x1F000 <= cp <= 0x1FAFF
        or 0x2600 <= cp <= 0x27BF
        or 0x2B00 <= cp <= 0x2BFF
        or cp in (0xFE0F, 0xFE0E, 0x200D, 0x20E3)
        or 0xE0020 <= cp <= 0xE007F
    )


def _sentence(line: str) -> str:
    line = line.strip()
    if line and not line.endswith(_TERMINAL):
        line += "."
    return line


class _Recorder:
    def __init__(self) -> None:
        self.changes: list[dict[str, object]] = []
        self.links: list[str] = []
        self.blocks: list[str] = []

    def sub(self, rule: str, pattern: re.Pattern[str], repl, text: str) -> str:  # type: ignore[no-untyped-def]
        def wrapped(m: re.Match[str]) -> str:
            after = repl(m) if callable(repl) else m.expand(repl)
            self.changes.append({"rule": rule, "before": m.group(0)[:200], "after": after[:200]})
            return after

        return pattern.sub(wrapped, text)


def clean_reply(reply: str) -> Cleaned:
    """Turn an agent reply into the spoken-and-shown text plus an attachment."""
    rec = _Recorder()
    text = reply.replace("\r\n", "\n").replace("\r", "\n")

    def take_attachment(m: re.Match[str]) -> str:
        body = m.group(1).strip()
        if body:
            rec.blocks.append(body)
        return ""

    text = rec.sub("attachment-block", _ATTACHMENT, take_attachment, text)

    def take_code(m: re.Match[str]) -> str:
        rec.blocks.append(m.group(0).strip())
        return ""

    text = rec.sub("code-block", _FENCE, take_code, text)

    def image(m: re.Match[str]) -> str:
        rec.links.append(m.group(2))
        return m.group(1)

    def link(m: re.Match[str]) -> str:
        rec.links.append(m.group(2))
        return m.group(1)

    def bare_url(m: re.Match[str]) -> str:
        url = m.group(0)
        trail = ""
        while url and url[-1] in ".,;:!?'\"":
            trail = url[-1] + trail
            url = url[:-1]
        rec.links.append(url)
        return "a link" + trail

    text = rec.sub("image", _IMAGE, image, text)
    text = rec.sub("link", _LINK, link, text)
    text = rec.sub("url", _AUTOLINK, lambda m: (rec.links.append(m.group(1)), "a link")[1], text)
    text = rec.sub("url", _URL, bare_url, text)
    text = rec.sub("rule", _RULE, "", text)
    text = rec.sub("table", _TABLE_SEP, "", text)
    text = rec.sub(
        "table",
        _TABLE_ROW,
        lambda m: _sentence(", ".join(c.strip() for c in m.group(1).split("|") if c.strip())),
        text,
    )
    text = rec.sub("heading", _HEADING, lambda m: _sentence(m.group(1)), text)
    text = rec.sub("list", _BULLET, lambda m: _sentence(m.group(1)), text)
    text = rec.sub("quote", _QUOTE, "", text)
    text = rec.sub("emphasis", _BOLD, r"\2", text)
    text = rec.sub("emphasis", _STRIKE, r"\1", text)
    text = rec.sub("emphasis", _ITALIC_STAR, r"\1", text)
    text = rec.sub("emphasis", _ITALIC_UNDERSCORE, r"\1", text)
    text = rec.sub("inline-code", _INLINE_CODE, r"\1", text)

    kept: list[str] = []
    dropped: list[str] = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch != "\n" and (cat in ("Cc", "Cf") or _is_emoji(ch)):
            if ch == "\t":
                kept.append(" ")
                continue
            dropped.append(ch)
            continue
        kept.append(ch)
    if dropped:
        rec.changes.append({"rule": "symbol", "before": "".join(dropped)[:200], "after": ""})
    text = "".join(kept)

    # Whitespace: single spaces, no trailing spaces, at most one blank line.
    lines = [re.sub(r"[  ]{2,}", " ", line).strip() for line in text.split("\n")]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()

    if not text:
        rec.changes.append({"rule": "empty", "before": "", "after": EMPTY_REPLY})
        text = EMPTY_REPLY

    parts = list(rec.blocks)
    if rec.links:
        unique = list(dict.fromkeys(rec.links))
        parts.append("Links:\n" + "\n".join(unique))
    attachment = "\n\n".join(parts) if parts else None
    return Cleaned(text=text, attachment=attachment, changes=rec.changes)
