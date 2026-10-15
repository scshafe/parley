import pytest

from parley_relay.timings import FORMAT, TimedSentence, estimate, job_sentences, syllables, words_of


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
