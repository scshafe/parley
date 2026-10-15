# Parley

Talk with your agent in turns, and hear it answer in your own voice. Parley is
an iOS app and a small relay server: a turn goes to an OpenClaw-like agent
with instructions to answer in a style made for speech; the reply is spoken by
the owner's voice-lab voice release; the phone gets a notification and plays
the reply with follow-along highlighting.

- The owner's brief: [docs/brief.md](docs/brief.md)
- The design: [docs/DESIGN.md](docs/DESIGN.md)

## Build and test

```sh
./scripts/verify-linux
```

The repository's one verify command (`dev.toml [verify]`).
