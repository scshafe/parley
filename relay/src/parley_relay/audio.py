"""WAV helpers: read a WAV's format and length, join replies, and make the
synthetic audio the fake voice-lab serves (tones and silence, never speech)."""

from __future__ import annotations

import array
import io
import math
import operator
import struct
import sys
import wave
from dataclasses import dataclass

RATE = 24_000  # voice-lab's API audio: 24 kHz, mono, 16-bit PCM


@dataclass(frozen=True)
class WavInfo:
    rate: int
    channels: int
    sample_width: int
    frames: int

    @property
    def duration_ms(self) -> int:
        return round(self.frames * 1000 / self.rate) if self.rate else 0


def info(data: bytes) -> WavInfo:
    with wave.open(io.BytesIO(data), "rb") as w:
        return WavInfo(w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes())


def _pcm(data: bytes) -> tuple[WavInfo, bytes]:
    with wave.open(io.BytesIO(data), "rb") as w:
        meta = WavInfo(w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes())
        return meta, w.readframes(meta.frames)


def levels(data: bytes, frame_ms: int = 10) -> list[float]:
    """The loudness of each ``frame_ms`` frame of a WAV, in dB below full scale
    (silence is about -120). Only voice-lab's format, mono 16-bit, is measured:
    anything else gives ``[]``."""
    meta, pcm = _pcm(data)
    if meta.channels != 1 or meta.sample_width != 2 or not meta.rate:
        return []
    samples = array.array("h")
    samples.frombytes(pcm)
    if sys.byteorder == "big":
        samples.byteswap()  # WAV PCM is little-endian
    n = max(1, meta.rate * frame_ms // 1000)
    full = 32768.0 * 32768.0
    out: list[float] = []
    for i in range(0, len(samples) - n + 1, n):
        frame = samples[i : i + n]
        out.append(10 * math.log10(sum(map(operator.mul, frame, frame)) / n / full + 1e-12))
    return out


def encode(pcm: bytes, rate: int = RATE, channels: int = 1, sample_width: int = 2) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sample_width)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def join(parts: list[bytes]) -> bytes:
    """Concatenate WAVs of one format, PCM after PCM, no cross-fade (as voice-lab
    joins its segments)."""
    if not parts:
        return encode(b"")
    first, pcm = _pcm(parts[0])
    chunks = [pcm]
    for part in parts[1:]:
        meta, more = _pcm(part)
        if (meta.rate, meta.channels, meta.sample_width) != (first.rate, first.channels, first.sample_width):
            raise ValueError("cannot join WAVs of different formats")
        chunks.append(more)
    return encode(b"".join(chunks), first.rate, first.channels, first.sample_width)


def synthetic_sentence(text: str, *, ms_per_syllable: int = 190, seed: int = 0) -> bytes:
    """A stand-in for a rendered sentence: one soft tone burst per word, with gaps
    for spaces and punctuation, at a plausible speaking rate. Synthetic only:
    there is no voice in it."""
    from .timings import syllables

    words = text.split()
    frames: list[bytes] = []
    lead = int(RATE * 0.12)
    frames.append(b"\x00\x00" * lead)
    base = 180 + (seed % 7) * 20
    for i, word in enumerate(words):
        n = int(RATE * syllables(word) * ms_per_syllable / 1000)
        freq = base + (i % 5) * 30
        samples = bytearray()
        for k in range(n):
            env = min(1.0, k / 240, (n - k) / 240)
            v = int(3000 * env * math.sin(2 * math.pi * freq * k / RATE))
            samples += struct.pack("<h", v)
        frames.append(bytes(samples))
        gap = 0.06
        if word[-1] in ",;:":
            gap = 0.2
        elif word[-1] in ".!?…":
            gap = 0.3
        frames.append(b"\x00\x00" * int(RATE * gap))
    frames.append(b"\x00\x00" * int(RATE * 0.25))
    return encode(b"".join(frames))
