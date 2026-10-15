# parley agent notes

- Two parts: `relay/` (the server, Python) and `ios/` (the SwiftUI app). The
  app talks only to the relay; the relay alone talks to the agent (OpenClaw)
  and to voice-lab.
- The brief, `docs/brief.md`, is fixed; the design is `docs/DESIGN.md`.
- voice-lab's speech API speaks only the owner's own voice release; never
  wire in another voice or TTS service. Its contract is voice-lab
  `docs/SPEECH_API.md`.
- Push payloads carry ids only, never reply text.
- iOS builds need Xcode on macOS: this PC cannot build `ios/`.

<!-- scshafe-dev:begin landing -->
## Verify and landing

Managed by scshafe-dev: `dev adopt` and `dev update` refresh this section from `dev.toml`; change `dev.toml`, not these lines.

Before finishing, both of these must pass:

```sh
./scripts/verify-linux
dev check .
```

How a change lands:

1. Work on a branch and open a PR.
2. Run the two commands above. If the repository is private, GitHub Actions does not run for it: verify locally and say in the PR what you ran. If it is public, wait for CI to be green.
3. Merge your own PR with a merge commit, one change at a time: `gh pr merge <N> --merge --subject "Merge #<N>: <title>"`. Never squash or rebase (both are off on the repository), and pass `--subject`: `gh pr merge` does not make the `Merge #N: <title>` subject by itself.

The project's agent may merge its own PR and push `main`; there is no approval gate.
<!-- scshafe-dev:end landing -->
