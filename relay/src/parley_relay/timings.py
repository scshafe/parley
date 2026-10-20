"""Follow-along timings: when each sentence and word of the shown text is heard.

A sentence's start and end are exact: voice-lab renders one segment per
sentence and reports its ``duration_ms``. Within a sentence, :func:`measure`
places the words in the speech it hears (``"source": "measured"``): a segment
opens with a second or more of silence and ends on its last word, so the words
go where the sound is, and the pauses between them land on the silences the
audio has, at punctuation where it can. Without usable audio, :func:`estimate`
spreads them over the whole sentence by syllables (``"estimated"``). P3's forced
aligner would write the same format with ``"source": "aligned"``.

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

import math
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
# A period after one of these is not a pause ("Dr. Patel").
_ABBREVIATIONS = frozenset({"mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "e.g", "i.e"})

# Measuring (:func:`measure`), in 10 ms frames of the reply's audio.
FRAME_MS = 10
QUIET_DB = 35.0  # a frame this far below the reply's loud frames is silence
MIN_CONTRAST_DB = 20.0  # less spread than this between loud and quiet: nothing to measure
MIN_GAP_MS = 80  # a shorter silence inside speech is not a pause
FIRM_GAP_MS = 300  # a silence this long is always between words
# The choice of which silences are the pauses between words: each grouping of
# the words into stretches of speech costs
FIT = 1.0  # x (log of a stretch's length over its words' share of the speech)^2,
NONPUNCT = 0.3  # plus this for a pause after a word with no punctuation,
NONPUNCT_PER_S = 3.0  # and this per second of that pause (long pauses are punctuation),
MISSED = 0.4  # plus this for punctuation inside a stretch, with no pause,
SKIP = 0.3  # plus this for a short silence taken to be inside a stretch.
INNER = 0.3  # The pause units a punctuation mark inside a stretch takes.


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
        if trailing.startswith(".") and text[a:b].lower() in _ABBREVIATIONS:
            trailing = trailing[1:]
        if a == b:
            if out:
                s, e, wgt, pause = out[-1]
                out[-1] = (s, e, wgt, pause + _pause_for(m.group(0)))
            continue
        out.append((a, b, syllables(text[a:b]), _pause_for(trailing)))
    return out


def _estimated(words: list[tuple[int, int, float, float]], sent: TimedSentence) -> list[tuple[int, int, int, int]]:
    """Words spread over the whole sentence by syllables: ``(char_start, char_end, start_ms, end_ms)``."""
    # The sentence's last pause is its tail silence, whatever the mark.
    last = words[-1]
    words = [*words[:-1], (last[0], last[1], last[2], TRAIL)]
    units = LEAD_IN + sum(w + p for _, _, w, p in words)
    span = max(0, sent.end_ms - sent.start_ms)
    per_unit = span / units if units else 0.0
    cursor = LEAD_IN
    out = []
    for a, b, weight, pause in words:
        start_ms = sent.start_ms + round(cursor * per_unit)
        end_ms = sent.start_ms + round((cursor + weight) * per_unit)
        out.append((a, b, start_ms, min(end_ms, sent.end_ms)))
        cursor += weight + pause
    return out


def _silences(levels: Sequence[float], start: int, end: int, threshold: float) -> list[tuple[int, int]]:
    """The runs of quiet frames in ``[start, end)`` at least ``MIN_GAP_MS`` long."""
    out: list[tuple[int, int]] = []
    run: int | None = None
    for i in range(start, end):
        if levels[i] <= threshold:
            if run is None:
                run = i
        elif run is not None:
            if (i - run) * FRAME_MS >= MIN_GAP_MS:
                out.append((run, i))
            run = None
    return out


def _stretches(
    words: list[tuple[int, int, float, float]], start: int, end: int, gaps: list[tuple[int, int]]
) -> list[tuple[int, int, int, int]] | None:
    """Which silences are the pauses between words: ``(first_frame, end_frame,
    first_word, end_word)`` for each stretch of speech, or None if the words
    cannot be fitted (fewer words than the long silences need)."""
    n, m = len(words), len(gaps)
    weight = [w for _, _, w, _ in words]
    punct = [p > 0 for _, _, _, p in words]
    speech = (end - start) - sum(b - a for a, b in gaps)
    if speech <= 0:
        return None
    rate = speech / sum(weight)  # frames per syllable unit
    w_sum = [0.0]
    p_sum = [0]
    for w, p in zip(weight, punct):
        w_sum.append(w_sum[-1] + w)
        p_sum.append(p_sum[-1] + p)
    opens = [start] + [b for _, b in gaps]  # a stretch after silence g opens at opens[g + 1]
    closes = [a for a, _ in gaps] + [end]  # a stretch before silence g closes at closes[g]
    # best[(g, i)]: the cheapest way to reach a stretch opening after silence g
    # (-1: the start) with word i; (m, n) is the end.
    best: dict[tuple[int, int], tuple[float, tuple[int, int, int, int] | None]] = {(-1, 0): (0.0, None)}
    for g in range(-1, m):
        for i in range(n):
            if (g, i) not in best:
                continue
            base = best[(g, i)][0]
            skipped = 0.0
            for g2 in range(g + 1, m + 1):
                if g2 > g + 1:
                    a, b = gaps[g2 - 1]
                    if (b - a) * FRAME_MS >= FIRM_GAP_MS:
                        break  # a long silence cannot be inside a stretch
                    skipped += SKIP
                frames = closes[g2] - opens[g + 1]
                if frames <= 0:
                    continue
                for i2 in range(i + 1, n + 1):
                    if (g2 == m) != (i2 == n):
                        continue
                    inner = p_sum[i2 - 1] - p_sum[i]
                    need = (w_sum[i2] - w_sum[i] + INNER * inner) * rate
                    if need > 8 * frames:
                        break
                    cost = base + skipped + FIT * math.log(frames / need) ** 2 + MISSED * inner
                    if g2 < m and not punct[i2 - 1]:
                        a, b = gaps[g2]
                        cost += NONPUNCT + NONPUNCT_PER_S * (b - a) * FRAME_MS / 1000
                    if cost < best.get((g2, i2), (math.inf, None))[0]:
                        best[(g2, i2)] = (cost, (g, i, g2, i2))
    if (m, n) not in best:
        return None
    out: list[tuple[int, int, int, int]] = []
    key = (m, n)
    while (step := best[key][1]) is not None:
        g, i, g2, i2 = step
        out.append((opens[g + 1], closes[g2], i, i2))
        key = (g, i)
    return out[::-1]


def _measured(
    words: list[tuple[int, int, float, float]], sent: TimedSentence, levels: Sequence[float], threshold: float
) -> list[tuple[int, int, int, int]] | None:
    """Words placed in the sentence's measured speech, or None if it has none."""
    first = sent.start_ms // FRAME_MS
    last = min(len(levels), -(-sent.end_ms // FRAME_MS))
    voiced = [i for i in range(first, last) if levels[i] > threshold]
    if not voiced:
        return None
    start, end = voiced[0], voiced[-1] + 1
    gaps = _silences(levels, start, end, threshold)
    stretches = _stretches(words, start, end, gaps) or [(start, end, 0, len(words))]
    out = []
    for f0, f1, i0, i1 in stretches:
        group = words[i0:i1]
        units = [w + (INNER if p > 0 and k < len(group) - 1 else 0.0) for k, (_, _, w, p) in enumerate(group)]
        per_unit = (f1 - f0) * FRAME_MS / sum(units)
        cursor = f0 * FRAME_MS
        for (a, b, weight, _), u in zip(group, units):
            out.append((a, b, round(cursor), min(round(cursor + weight * per_unit), f1 * FRAME_MS)))
            cursor += u * per_unit
    return [(a, b, max(s, sent.start_ms), min(e, sent.end_ms)) for a, b, s, e in out]


def _timings(text: str, sentences: Sequence[TimedSentence], source: str, place) -> dict:
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
        for a, b, start_ms, end_ms in place(words, sent):
            timed_words.append(
                {
                    "index": len(timed_words),
                    "char_start": a,
                    "char_end": b,
                    "start_ms": start_ms,
                    "end_ms": end_ms,
                    "sentence": si,
                }
            )
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


def estimate(text: str, sentences: Sequence[TimedSentence], *, source: str = "estimated") -> dict:
    """Build ``timings.json`` for ``text`` from exactly timed sentences, by syllables alone."""
    return _timings(text, sentences, source, _estimated)


def measure(text: str, sentences: Sequence[TimedSentence], levels: Sequence[float]) -> dict:
    """Build ``timings.json`` with each sentence's words placed in the speech
    heard in ``levels`` (:func:`audio.levels` of the reply). Falls back to
    :func:`estimate` when the audio has nothing to measure; a sentence with no
    speech in it is estimated alone."""
    ordered = sorted(levels)
    if not ordered:
        return estimate(text, sentences)
    loud = ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))]
    if loud - ordered[0] < MIN_CONTRAST_DB:
        return estimate(text, sentences)
    threshold = loud - QUIET_DB

    def place(words, sent):
        return _measured(words, sent, levels, threshold) or _estimated(words, sent)

    return _timings(text, sentences, "measured", place)


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
    ``text_start``/``text_end``, null for old segments); ``offset_ms`` is
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
