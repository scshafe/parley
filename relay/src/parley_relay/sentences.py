"""Which characters each speech segment spoke, and where a long reply is cut.

voice-lab renders one segment per sentence, but its segment records do not
carry their text yet (voice-lab#78 adds ``text_start``/``text_end``). Until
then the relay repeats voice-lab's documented splitting rule (SPEECH_API.md
§7, "Sentences and seeds"):

    The job runner splits the text into sentences (after ``.``, ``!``, ``?``,
    ``…`` and their CJK forms followed by a space or the end, and at line
    breaks); a fragment under 12 characters joins the next sentence (the last
    one joins the sentence before it), and a sentence too long for one pass of the release's model is split at its last
    comma, semicolon or colon within the limit, else at a space.

Everything that depends on the rule goes through :func:`segment_ranges`, so the
day voice-lab reports each segment's range only that function changes.

All offsets are Python string indices: Unicode code points.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass

# After one of these, followed by whitespace or the end of the line, a sentence ends.
SENTENCE_END = frozenset(".!?…。！？")
# A fragment shorter than this joins the next sentence.
MIN_FRAGMENT = 12
# voice-lab's per-request limit, in code points (SPEECH_API.md §6).
MAX_JOB_CHARACTERS = 2000
_SOFT_BREAKS = ",;:，；："


@dataclass(frozen=True)
class Span:
    """A half-open range ``[start, end)`` of code points in a text."""

    start: int
    end: int

    def of(self, text: str) -> str:
        return text[self.start : self.end]

    def shifted(self, by: int) -> Span:
        return Span(self.start + by, self.end + by)


def _strip_span(text: str, start: int, end: int) -> Span | None:
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    return Span(start, end) if end > start else None


def raw_sentences(text: str) -> list[Span]:
    """Sentence pieces before short fragments are joined: cut after a sentence
    mark followed by whitespace or the end, and at every line break."""
    spans: list[Span] = []
    line_start = 0
    for line in text.split("\n"):
        line_end = line_start + len(line)
        piece_start = line_start
        for i in range(line_start, line_end):
            if text[i] in SENTENCE_END and (i + 1 == line_end or text[i + 1].isspace()):
                span = _strip_span(text, piece_start, i + 1)
                if span:
                    spans.append(span)
                piece_start = i + 1
        span = _strip_span(text, piece_start, line_end)
        if span:
            spans.append(span)
        line_start = line_end + 1
    return spans


def _split_long(text: str, span: Span, limit: int) -> list[Span]:
    """Cut a sentence longer than ``limit`` at its last comma, semicolon or colon
    within the limit, else at its last space, else hard at the limit."""
    out: list[Span] = []
    rest = span
    while rest.end - rest.start > limit:
        window = text[rest.start : rest.start + limit]
        cut = max(window.rfind(c) for c in _SOFT_BREAKS)
        if cut > 0:
            cut += 1  # keep the mark with the first part
        else:
            cut = window.rfind(" ")
            if cut <= 0:
                cut = limit
        head = _strip_span(text, rest.start, rest.start + cut)
        if head:
            out.append(head)
        tail = _strip_span(text, rest.start + cut, rest.end)
        if tail is None:
            return out
        rest = tail
    out.append(rest)
    return out


def voice_lab_sentences(text: str, *, max_sentence_chars: int | None = None) -> list[Span]:
    """The sentences voice-lab renders for ``text``, one segment each.

    ``max_sentence_chars`` is the release's one-pass limit; voice-lab derives it
    from the reference clip, which the relay cannot see, so it is a setting
    (``None``: no sentence is cut for length)."""
    joined: list[Span] = []
    pending: Span | None = None
    for span in raw_sentences(text):
        if pending is not None:
            span = Span(pending.start, span.end)
            pending = None
        if span.end - span.start < MIN_FRAGMENT:
            pending = span
            continue
        joined.append(span)
    if pending is not None:
        # A short fragment at the very end has no next sentence to join: it joins
        # the one before it ("…tonight? Done." is one segment), or is the only one.
        if joined:
            joined[-1] = Span(joined[-1].start, pending.end)
        else:
            joined.append(pending)
    if not max_sentence_chars:
        return joined
    out: list[Span] = []
    for span in joined:
        out.extend(_split_long(text, span, max_sentence_chars))
    return out


def segment_ranges(
    text: str,
    segments: Sequence[Mapping[str, object]],
    *,
    max_sentence_chars: int | None = None,
) -> list[Span] | None:
    """The span of ``text`` each speech segment spoke, in segment order.

    When every segment carries ``text_start``/``text_end`` (voice-lab#78) they
    are used as given. Otherwise the documented rule is repeated; if it does
    not give one sentence per segment, the answer is ``None`` and the caller
    falls back to treating the job as one span."""
    if segments and all("text_start" in s and "text_end" in s for s in segments):
        spans = [Span(int(s["text_start"]), int(s["text_end"])) for s in segments]  # type: ignore[call-overload]
        if all(0 <= sp.start < sp.end <= len(text) for sp in spans):
            return spans
        return None
    spans = voice_lab_sentences(text, max_sentence_chars=max_sentence_chars)
    if len(spans) != len(segments):
        return None
    return spans


def split_for_jobs(text: str, limit: int = MAX_JOB_CHARACTERS) -> list[Span]:
    """Cut a reply into speech jobs of at most ``limit`` code points each, at
    sentence boundaries. A single sentence over the limit is cut like voice-lab
    cuts one that is too long (last comma, semicolon or colon, else a space)."""
    whole = _strip_span(text, 0, len(text))
    if whole is None:
        return []
    if whole.end - whole.start <= limit:
        return [whole]
    pieces: list[Span] = []
    for span in raw_sentences(text):
        pieces.extend(_split_long(text, span, limit))
    jobs: list[Span] = []
    current: Span | None = None
    for piece in pieces:
        if current is None:
            current = piece
        elif piece.end - current.start <= limit:
            current = Span(current.start, piece.end)
        else:
            jobs.append(current)
            current = piece
    if current is not None:
        jobs.append(current)
    return jobs
