"""``parley-relay``: run the relay. ``--dev`` runs it with the fake agent and
the fake voice-lab in-process, for the app and for trying a turn end to end."""

from __future__ import annotations

import argparse
import logging
import os
import sys

import uvicorn

from .server import DEV_TOKEN, ConfigError, Settings, build


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="parley-relay", description=__doc__)
    p.add_argument("--dev", action="store_true", help="fake agent and fake voice-lab, in-process")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--data-dir", help="where the database and audio live (PARLEY_DATA_DIR)")
    p.add_argument("--fake-agent-delay", type=float, help="--dev: seconds the fake agent thinks (default 1.0)")
    p.add_argument("--fake-speech-speed", type=float,
                   help="--dev: fake render time as a fraction of the audio's length (default 0.3; 0 is instant)")
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        settings = Settings.from_env(dev=args.dev)
    except ConfigError as exc:
        print(f"parley-relay: {exc}", file=sys.stderr)
        return 2
    if args.data_dir:
        from pathlib import Path

        settings.data_dir = Path(args.data_dir)
    if args.fake_agent_delay is not None:
        settings.fake_agent_delay = args.fake_agent_delay
    if args.fake_speech_speed is not None:
        settings.fake_speech_speed = args.fake_speech_speed
    try:
        relay = build(settings)
    except ConfigError as exc:
        print(f"parley-relay: {exc}", file=sys.stderr)
        return 2
    if args.dev:
        where = f"http://{args.host}:{args.port}"
        token_note = DEV_TOKEN if settings.token is None else "(from PARLEY_TOKEN / PARLEY_TOKEN_FILE)"
        print(f"parley-relay --dev: {where}  token: {token_note}  data: {os.path.abspath(settings.data_dir)}",
              file=sys.stderr)
        print("  fake agent and fake voice-lab (synthetic tones) run in-process; nothing leaves this machine.",
              file=sys.stderr)
    uvicorn.run(relay.app, host=args.host, port=args.port, log_level="info", timeout_graceful_shutdown=3)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
