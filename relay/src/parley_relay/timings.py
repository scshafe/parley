"""Follow-along timings: when each sentence and word of the shown text is heard.

P1 estimates them. A sentence's start and end are exact: voice-lab renders one
segment per sentence and reports its ``duration_ms``. Within a sentence each word
gets a share of the time weighted by its syllables, with pauses for punctuation.
P3's forced aligner writes the same format with ``"source": "aligned"``.

``timings.json`` (``parley.timings/v1``)::

    {"format": "parley.timings/v1", "source": "estimated", "offsets": "unicode-scalars",
     "duration_ms": 5120, "text_length": 61,
     "sentences": [{"index": 0, "char_start": 0, "char_end": 27, "start_ms": 0, "end_ms": 2400}],
     "words": [{"index": 0, "char_start": 0, "char_end": 5, "start_ms": 40, "end_ms": 380,
                "sentence": 0}]}

Character offsets are half-open ranges of Unicode scalar values (code points) in
the shown text; Swift reads them through ``String.unicodeScalars``.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass

FORMAT = "parley.timings/v1"

# Pause weights, in syllable units.
LEAD_IN = 0.3
PAUSE_SOFT = 1.0  # , ; : — –
PAUSE_HARD = 1.6  # . ! ? … inside a sentence (an abbreviation, a joined fragment)
TRAIL = 1.2  # after the sentence's last word: the segment's tail silence

_WORD = re.compile(r"\S+")
_VOWELS = re.compile(r"[aeiouy]+")
_SOFT = set(",;:—–-，；：")
_HARD = set(".!?…。！？")


@dataclass(frozen=True)
class TimedSentence:
    char_start: int
    char_end: int
    start_ms: int
    end_ms: int


def _is_wordy(ch: str) -> bool:
    return unicodedata.category(ch)[0] in "LNM"


def syllables(word: str) -> float:
    """A rough syllable count, the weight of a word's share of its sentence."""
    w = word.lower()
    letters = "".join(c for c in w if c.isalpha())
    digits = sum(c.isdigit() for c in w)
    if not letters and digits:
        return 1.2 * digits
    if letters and not letters.isascii():
        return max(1.0, len(letters) / 2.5)
    groups = len(_VOWELS.findall(letters))
    if letters.endswith("e") and not letters.endswith(("le", "ee", "ye")) and groups > 1:
        groups -= 1
    if letters.endswith("ed") and len(letters) > 3 and letters[-3] not in "td" and groups > 1:
        groups -= 1
    return float(max(1, groups)) + 1.2 * digits


def _pause_for(punct: str) -> float:
    if any(c in _HARD for c in punct):
        return PAUSE_HARD
    if any(c in _SOFT for c in punct):
        return PAUSE_SOFT
    return 0.0


def words_of(text: str, start: int, end: int) -> list[tuple[int, int, float, float]]:
    """The words of ``text[start:end]``: ``(char_start, char_end, weight, pause_after)``.

    A word's range leaves out the punctuation around it; a token of punctuation
    alone (a dash) is not a word, it is a pause after the word before it."""
    out: list[tuple[int, int, float, float]] = []
    for m in _WORD.finditer(text, start, end):
        a, b = m.start(), m.end()
        while a < b and not _is_wordy(text[a]):
            a += 1
        while b > a and not _is_wordy(text[b - 1]):
            b -= 1
        trailing = text[b : m.end()]
        if a == b:
            if out:
                s, e, wgt, pause = out[-1]
                out[-1] = (s, e, wgt, pause + _pause_for(m.group(0)))
            continue
        out.append((a, b, syllables(text[a:b]), _pause_for(trailing)))
    return out


def estimate(text: str, sentences: Sequence[TimedSentence], *, source: str = "estimated") -> dict:
    """Build ``timings.json`` for ``text`` from exactly timed sentences."""
    timed_sentences: list[dict] = []
    timed_words: list[dict] = []
    for si, sent in enumerate(sentences):
        timed_sentences.append(
            {
                "index": si,
                "char_start": sent.char_start,
                "char_end": sent.char_end,
                "start_ms": sent.start_ms,
                "end_ms": sent.end_ms,
            }
        )
        words = words_of(text, sent.char_start, sent.char_end)
        if not words:
            continue
        # The sentence's last pause is its tail silence, whatever the mark.
        last = words[-1]
        words[-1] = (last[0], last[1], last[2], TRAIL)
        units = LEAD_IN + sum(w + p for _, _, w, p in words)
        span = max(0, sent.end_ms - sent.start_ms)
        per_unit = span / units if units else 0.0
        cursor = LEAD_IN
        for a, b, weight, pause in words:
            start_ms = sent.start_ms + round(cursor * per_unit)
            end_ms = sent.start_ms + round((cursor + weight) * per_unit)
            timed_words.append(
                {
                    "index": len(timed_words),
                    "char_start": a,
                    "char_end": b,
                    "start_ms": start_ms,
                    "end_ms": min(end_ms, sent.end_ms),
                    "sentence": si,
                }
            )
            cursor += weight + pause
    duration = max((s.end_ms for s in sentences), default=0)
    return {
        "format": FORMAT,
        "source": source,
        "offsets": "unicode-scalars",
        "duration_ms": duration,
        "text_length": len(text),
        "sentences": timed_sentences,
        "words": timed_words,
    }


def job_sentences(
    text: str,
    job_start: int,
    job_end: int,
    segments: Sequence[dict],
    offset_ms: int,
    *,
    max_sentence_chars: int | None = None,
) -> tuple[list[TimedSentence], bool]:
    """Exact sentence times for one speech job.

    ``segments`` are the job's segment records in order (``duration_ms``, and
    ``text_start``/``text_end`` once voice-lab reports them); ``offset_ms`` is
    where the job's audio starts in the reply's audio. Returns the sentences and
    whether each segment could be matched to its text; when it could not, the
    job is one sentence spanning its whole text."""
    from .sentences import segment_ranges

    job_text = text[job_start:job_end]
    spans = segment_ranges(job_text, segments, max_sentence_chars=max_sentence_chars)
    durations = [int(s.get("duration_ms") or 0) for s in segments]
    if spans is None:
        total = sum(durations)
        return [TimedSentence(job_start, job_end, offset_ms, offset_ms + total)], False
    out: list[TimedSentence] = []
    t = offset_ms
    for span, dur in zip(spans, durations, strict=True):
        out.append(TimedSentence(job_start + span.start, job_start + span.end, t, t + dur))
        t += dur
    return out, True
