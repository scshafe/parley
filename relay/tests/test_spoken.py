from parley_relay.spoken import EMPTY_REPLY, clean_reply


def test_plain_prose_is_unchanged():
    reply = "Sure. I can help with that. Let's start with the basics."
    out = clean_reply(reply)
    assert out.text == reply
    assert out.attachment is None
    assert out.changes == []


def test_attachment_block_is_split_off():
    out = clean_reply("I've put the link on your screen.\n<attachment>\nhttps://example.com/a\n</attachment>")
    assert out.text == "I've put the link on your screen."
    assert out.attachment == "https://example.com/a"
    assert any(c["rule"] == "attachment-block" for c in out.changes)


def test_unclosed_attachment_takes_the_rest():
    out = clean_reply("Here it is.\n<attachment>\nline one\nline two")
    assert out.text == "Here it is."
    assert out.attachment == "line one\nline two"


def test_bare_urls_become_a_link_and_are_kept():
    out = clean_reply("See https://example.com/docs?x=1. It explains everything.")
    assert out.text == "See a link. It explains everything."
    assert out.attachment == "Links:\nhttps://example.com/docs?x=1"


def test_markdown_link_keeps_its_words():
    out = clean_reply("Read [the guide](https://example.com/guide) first.")
    assert out.text == "Read the guide first."
    assert "https://example.com/guide" in out.attachment


def test_markdown_is_stripped_and_lists_become_sentences():
    reply = "# Plan\n\nHere is **the** plan:\n\n- buy *milk*\n- call `Sam`\n1. rest\n\n> quoted words\n\n---\nDone."
    out = clean_reply(reply)
    assert out.text == "Plan.\n\nHere is the plan:\n\nbuy milk.\ncall Sam.\nrest.\n\nquoted words\n\nDone."
    rules = {c["rule"] for c in out.changes}
    assert {"heading", "emphasis", "list", "inline-code", "quote", "rule"} <= rules


def test_code_blocks_move_to_the_attachment():
    out = clean_reply("Run this command.\n```sh\nls -la\n```\nThat lists files.")
    assert out.text == "Run this command.\n\nThat lists files."
    assert "ls -la" in out.attachment


def test_tables_become_sentences():
    out = clean_reply("| a | b |\n|---|---|\n| one | two |")
    assert out.text == "a, b.\n\none, two." or out.text == "a, b.\none, two."


def test_emoji_and_control_characters_are_removed():
    out = clean_reply("Great job! \U0001F389​ Keep going.\x07")
    assert out.text == "Great job! Keep going."
    assert any(c["rule"] == "symbol" for c in out.changes)


def test_snake_case_and_math_survive():
    out = clean_reply("The file_name_here stays, and 2 * 3 is six.")
    assert out.text == "The file_name_here stays, and 2 * 3 is six."


def test_an_empty_spoken_part_gets_a_sentence():
    out = clean_reply("<attachment>only code</attachment>")
    assert out.text == EMPTY_REPLY
    assert out.attachment == "only code"
