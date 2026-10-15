from parley_relay import audio, style


def test_synthetic_sentence_is_24k_mono_16bit_and_plausible():
    wav = audio.synthetic_sentence("This is a short test sentence, with a pause.")
    meta = audio.info(wav)
    assert (meta.rate, meta.channels, meta.sample_width) == (24000, 1, 2)
    assert 1500 < meta.duration_ms < 6000


def test_join_concatenates_pcm():
    a = audio.synthetic_sentence("One two three.")
    b = audio.synthetic_sentence("Four five six seven.")
    joined = audio.join([a, b])
    assert audio.info(joined).frames == audio.info(a).frames + audio.info(b).frames


def test_style_instructions_load():
    text = style.instructions()
    assert style.CURRENT == "style-v1"
    assert "<attachment>" in text and "1,800 characters" in text
