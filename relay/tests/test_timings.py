import math
import struct

import pytest

from parley_relay import audio
from parley_relay.timings import FORMAT, TimedSentence, estimate, job_sentences, measure, syllables, words_of


def tones(spans_ms, total_ms, rate=audio.RATE):
    """A WAV of silence with a 220 Hz tone in each ``(start_ms, end_ms)``: a
    stand-in for speech (synthetic audio only)."""
    samples = [0] * (total_ms * rate // 1000)
    for a, b in spans_ms:
        for i in range(a * rate // 1000, b * rate // 1000):
            samples[i] = int(8000 * math.sin(2 * math.pi * 220 * i / rate))
    return audio.encode(struct.pack(f"<{len(samples)}h", *samples), rate)


def starts(text, timings):
    return {text[w["char_start"] : w["char_end"]]: w["start_ms"] for w in timings["words"]}


def test_syllables_are_rough_but_ordered():
    assert syllables("cat") == 1
    assert syllables("water") == 2
    assert syllables("make") == 1
    assert syllables("conversation") >= 4
    assert syllables("2026") > syllables("7")


def test_words_leave_out_surrounding_punctuation():
    text = '"Hello," she said — quietly.'
    words = words_of(text, 0, len(text))
    assert [text[a:b] for a, b, _, _ in words] == ["Hello", "she", "said", "quietly"]
    # The comma and the dash are pauses.
    assert words[0][3] > 0 and words[2][3] > 0 and words[1][3] == 0


def test_estimate_word_times_stay_inside_their_sentence():
    text = "Good morning, friend. The plan for today is simple and short."
    s1, s2 = (0, 21), (22, len(text))
    timings = estimate(text, [TimedSentence(*s1, 0, 1500), TimedSentence(*s2, 1500, 4000)])
    assert timings["format"] == FORMAT
    assert timings["source"] == "estimated"
    assert timings["duration_ms"] == 4000
    assert [w["char_start"] for w in timings["words"]] == sorted(w["char_start"] for w in timings["words"])
    for w in timings["words"]:
        sent = timings["sentences"][w["sentence"]]
        assert sent["start_ms"] <= w["start_ms"] < w["end_ms"] <= sent["end_ms"]
        assert sent["char_start"] <= w["char_start"] < w["char_end"] <= sent["char_end"]
    starts = [w["start_ms"] for w in timings["words"]]
    assert starts == sorted(starts)
    assert [text[w["char_start"] : w["char_end"]] for w in timings["words"]][:3] == ["Good", "morning", "friend"]


def test_longer_words_get_more_time():
    text = "I understand everything."
    t = estimate(text, [TimedSentence(0, len(text), 0, 3000)])
    durations = [w["end_ms"] - w["start_ms"] for w in t["words"]]
    assert durations[0] < durations[1] and durations[0] < durations[2]


def test_job_sentences_maps_segments_and_offsets():
    text = "Opening words here. A second sentence follows. Then the last sentence."
    sents, exact = job_sentences(text, 0, len(text), [{"duration_ms": 1000}, {"duration_ms": 1200}, {"duration_ms": 900}], 500)
    assert exact
    assert [(s.start_ms, s.end_ms) for s in sents] == [(500, 1500), (1500, 2700), (2700, 3600)]
    assert text[sents[1].char_start : sents[1].char_end] == "A second sentence follows."


def test_job_sentences_degrades_to_one_span_on_mismatch():
    text = "One sentence. Two sentences here."
    sents, exact = job_sentences(text, 0, len(text), [{"duration_ms": 700}], 0)
    assert not exact
    assert sents == [TimedSentence(0, len(text), 0, 700)]


def test_non_ascii_offsets_are_code_points():
    text = "Café au lait, s'il vous plaît. 🎉 is gone."
    t = estimate(text, [TimedSentence(0, 30, 0, 2000)])
    assert [text[w["char_start"] : w["char_end"]] for w in t["words"]][:1] == ["Café"]
    assert t["text_length"] == len(text)


@pytest.mark.parametrize("dur", [0, 1, 50])
def test_tiny_durations_do_not_break(dur):
    text = "Short one here."
    t = estimate(text, [TimedSentence(0, len(text), 0, dur)])
    for w in t["words"]:
        assert 0 <= w["start_ms"] <= w["end_ms"] <= dur


def test_abbreviations_are_not_pauses():
    text = "Dr. Patel and Mrs. Gray came."
    words = words_of(text, 0, len(text))
    assert [text[a:b] for a, b, _, _ in words][:2] == ["Dr", "Patel"]
    assert words[0][3] == 0 and words[3][3] == 0


def test_measured_words_start_where_the_speech_starts():
    # A segment opens with a second of silence and ends on its last word; a
    # comma's pause is a silence in the audio.
    text = "Sure, here is the plan."
    wav = tones([(1000, 1300), (1600, 2900)], 3000)
    t = measure(text, [TimedSentence(0, len(text), 0, 3000)], audio.levels(wav))
    assert t["source"] == "measured"
    at = starts(text, t)
    assert abs(at["Sure"] - 1000) <= 20
    assert abs(at["here"] - 1600) <= 20
    assert at["here"] < at["is"] < at["the"] < at["plan"] < 2900
    assert all(0 <= w["start_ms"] <= w["end_ms"] <= 3000 for w in t["words"])
    # Syllables alone put the first word at the start of the segment.
    assert estimate(text, [TimedSentence(0, len(text), 0, 3000)])["words"][0]["start_ms"] < 300


def test_a_long_pause_falls_at_punctuation_even_against_the_pace():
    # Six quick words, a long pause, four slow ones (as F5 renders some
    # sentences): by pace alone "minutes" would go after the pause.
    text = "It is only about twenty minutes, and you said so."
    wav = tones([(200, 1300), (2600, 4200)], 4400)
    at = starts(text, measure(text, [TimedSentence(0, len(text), 0, 4400)], audio.levels(wav)))
    assert at["minutes"] < 1300
    assert abs(at["and"] - 2600) <= 20


def test_a_short_silence_without_punctuation_need_not_split_the_words():
    text = "Walk instead of driving, it helps."
    # A 100 ms stop inside "instead", the comma's pause after "driving".
    wav = tones([(500, 900), (1000, 1900), (2300, 3000)], 3200)
    at = starts(text, measure(text, [TimedSentence(0, len(text), 0, 3200)], audio.levels(wav)))
    assert abs(at["it"] - 2300) <= 20
    assert at["Walk"] == pytest.approx(500, abs=20)


def test_silent_or_unmeasurable_audio_falls_back_to_the_estimate():
    text = "Nothing to hear here."
    sents = [TimedSentence(0, len(text), 0, 2000)]
    assert measure(text, sents, audio.levels(tones([], 2000))) == estimate(text, sents)
    assert measure(text, sents, []) == estimate(text, sents)


def test_a_sentence_without_speech_is_estimated_alone():
    text = "First one is heard. Second is not."
    sents = [TimedSentence(0, 19, 0, 2000), TimedSentence(20, len(text), 2000, 4000)]
    t = measure(text, sents, audio.levels(tones([(800, 1900)], 4000)))
    at = starts(text, t)
    assert abs(at["First"] - 800) <= 20
    assert at["Second"] == estimate(text, sents)["words"][4]["start_ms"]


def test_levels_measure_only_mono_16_bit():
    assert audio.levels(audio.encode(b"\x00\x00" * 2400, channels=2)) == []
    lv = audio.levels(tones([(0, 100)], 200))
    assert len(lv) == 20 and lv[0] > -30 > lv[-1]
