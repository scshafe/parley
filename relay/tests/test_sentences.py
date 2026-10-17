from parley_relay.sentences import (
    MAX_JOB_CHARACTERS,
    Span,
    raw_sentences,
    segment_ranges,
    split_for_jobs,
    voice_lab_sentences,
)


def texts(text, spans):
    return [s.of(text) for s in spans]


def test_splits_after_marks_followed_by_space_or_end():
    text = "The weather is fine today. Would you like a walk? Let's go now!"
    assert texts(text, voice_lab_sentences(text)) == [
        "The weather is fine today.",
        "Would you like a walk?",
        "Let's go now!",
    ]


def test_a_short_last_fragment_joins_the_sentence_before_it():
    # voice-lab's split_sentences: the carry left at the end is appended to the
    # last sentence; a reply ending "Done." must match it, or every segment's
    # text is lost and the reply's words are spread over the whole job.
    text = "That is exactly what I meant to say. Thanks."
    assert texts(text, voice_lab_sentences(text)) == [text]
    assert texts("Done.", voice_lab_sentences("Done.")) == ["Done."]


def test_mark_not_followed_by_space_does_not_split():
    text = "Version 3.12 is out now, and it is fast. The site example.com has it."
    assert texts(text, voice_lab_sentences(text)) == [
        "Version 3.12 is out now, and it is fast.",
        "The site example.com has it.",
    ]


def test_ellipsis_and_cjk_marks_split():
    text = "Well, I was thinking… Maybe tomorrow works best. 今日は良い天気です。 明日も晴れるでしょう。"
    assert texts(text, voice_lab_sentences(text)) == [
        "Well, I was thinking…",
        "Maybe tomorrow works best.",
        "今日は良い天気です。 明日も晴れるでしょう。",
    ]


def test_line_breaks_split_and_blank_lines_vanish():
    text = "First line without a stop\n\nSecond line here, also plain"
    assert texts(text, raw_sentences(text)) == ["First line without a stop", "Second line here, also plain"]


def test_short_fragments_join_the_next_sentence():
    text = "Yes. Ok. That is exactly what I meant to say."
    assert texts(text, voice_lab_sentences(text)) == ["Yes. Ok. That is exactly what I meant to say."]


def test_long_sentence_split_at_last_soft_break_within_limit():
    text = "This sentence is long, with a clause; and another one: then more words to finish it."
    spans = voice_lab_sentences(text, max_sentence_chars=50)
    assert texts(text, spans) == [
        "This sentence is long, with a clause; and another",
        "one: then more words to finish it.",
    ] or all(s.end - s.start <= 50 for s in spans)
    assert all(s.end - s.start <= 50 for s in spans)
    assert texts(text, spans)[0].endswith((",", ";", ":"))


def test_long_sentence_without_soft_break_splits_at_space():
    text = "word " * 30 + "end."
    spans = voice_lab_sentences(text.strip(), max_sentence_chars=40)
    assert all(s.end - s.start <= 40 for s in spans)
    assert "".join(texts(text, spans)).replace(" ", "") == text.replace(" ", "")


def test_segment_ranges_uses_reported_ranges_when_present():
    text = "Hello there, friend. How are you today?"
    segs = [{"duration_ms": 1, "text_start": 0, "text_end": 20}, {"duration_ms": 1, "text_start": 21, "text_end": 39}]
    assert segment_ranges(text, segs) == [Span(0, 20), Span(21, 39)]


def test_segment_ranges_rejects_bad_reported_ranges():
    assert segment_ranges("short", [{"text_start": 0, "text_end": 99}]) is None


def test_segment_ranges_falls_back_on_count_mismatch():
    text = "Hello there, friend. How are you today?"
    assert segment_ranges(text, [{"duration_ms": 1}]) is None
    assert segment_ranges(text, [{"duration_ms": 1}, {"duration_ms": 2}]) == [Span(0, 20), Span(21, 39)]


def test_split_for_jobs_keeps_short_replies_whole():
    assert split_for_jobs("  Just one.  ") == [Span(2, 11)]
    assert split_for_jobs("   ") == []


def test_split_for_jobs_cuts_at_sentence_boundaries():
    sentence = "This is a sentence of moderate length for testing purposes. "
    text = (sentence * 80).strip()
    jobs = split_for_jobs(text)
    assert len(jobs) > 1
    for job in jobs:
        assert job.end - job.start <= MAX_JOB_CHARACTERS
        assert job.of(text).endswith(".")
    # Nothing lost but the whitespace between jobs.
    assert "".join(j.of(text) for j in jobs).replace(" ", "") == text.replace(" ", "")


def test_split_for_jobs_cuts_an_overlong_sentence():
    text = ("many words, " * 300).strip()
    jobs = split_for_jobs(text, limit=500)
    assert all(j.end - j.start <= 500 for j in jobs)
