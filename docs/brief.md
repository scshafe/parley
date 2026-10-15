# Parley: the owner's brief

The owner's request, 2026-10-15 (lightly edited for reading):

> An iOS application that I can use to connect to an agent running like an
> OpenClaw (it could maybe even be a fork of OpenClaw). It is based around AI
> voice, using my `voice-lab` API to produce TTS, for chat conversations. It
> runs in turns, and the AI's responses are designed to be responses that
> handle TTS smoothly. So it is like connecting to an OpenClaw, with
> instructions that say "make sure your response fits this style"; after the
> response is finished, the speech for it is produced automatically. When that
> is done, the phone app gets a notification, and I can view the response
> while listening to it. While I view it, follow-along highlighting tracks the
> audio on the visual text.
>
> The reason: I want to start leveraging my voice clone and get interactions
> with it.

## Fixed points

- **Turns, not a live call.** The user sends a turn; the agent answers in
  text; speech is made after the answer is complete; then the phone is
  notified.
- **Answers are written to be spoken.** The agent is told to keep a style
  that synthesizes well (see the design for the rules).
- **Speech comes from voice-lab,** in the owner's own voice release, through
  its speech API. No other voice and no other TTS service.
- **A notification when the reply is ready to hear.**
- **Read while listening:** the reply's text is shown with highlighting that
  follows the audio.
- **The agent is OpenClaw-like,** reached from the phone through this project.
