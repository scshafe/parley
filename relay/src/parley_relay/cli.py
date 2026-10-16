"""``parley-relay``: run the relay. ``--dev`` runs it with the fake agent and
the fake voice-lab in-process, for the app and for trying a turn end to end."""

from __future__ import annotations

import argparse
import ipaddress
import logging
import os
import socket
import sys

import uvicorn

from .server import DEV_TOKEN, ConfigError, Settings, build


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="parley-relay", description=__doc__)
    p.add_argument("--dev", action="store_true", help="fake agent and fake voice-lab, in-process")
    p.add_argument("--host", default="127.0.0.1",
                   help="address to listen on; several, comma-separated (the stack: its upstream address and loopback)")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--data-dir", help="where the database and audio live (PARLEY_DATA_DIR)")
    p.add_argument("--fake-agent-delay", type=float, help="--dev: seconds the fake agent thinks (default 1.0)")
    p.add_argument("--fake-speech-speed", type=float,
                   help="--dev: fake render time as a fraction of the audio's length (default 0.3; 0 is instant)")
    args = p.parse_args(argv)
    try:
        hosts = parse_hosts(args.host)
        if args.dev:
            require_loopback(hosts)
    except ValueError as exc:
        p.error(str(exc))  # exits 2 with the usage line

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
        where = "  ".join(url_for(h, args.port) for h in hosts)
        print(f"parley-relay --dev: {where}  token: {DEV_TOKEN}  data: {os.path.abspath(settings.data_dir)}",
              file=sys.stderr)
        print("  fake agent and fake voice-lab (synthetic tones) run in-process; nothing leaves this machine.",
              file=sys.stderr)
    # No proxy headers: the peer is the door itself (the relay checks it), and
    # nothing a client sends may stand in for it.
    config = uvicorn.Config(relay.app, host=hosts[0], port=args.port, log_level="info", timeout_graceful_shutdown=3,
                            proxy_headers=False, server_header=False)
    server = uvicorn.Server(config)
    if len(hosts) == 1:
        server.run()
    else:
        server.run(sockets=[listen_socket(h, args.port) for h in hosts])
    return 0


def parse_hosts(value: str) -> list[str]:
    """``--host``: one address or name, or several comma-separated IP literals
    (uvicorn binds a name itself; several need sockets made here)."""
    hosts = [h.strip() for h in value.split(",") if h.strip()]
    if not hosts:
        raise ValueError("--host: give an address")
    if len(hosts) > 1:
        for h in hosts:
            try:
                ipaddress.ip_address(h)
            except ValueError:
                raise ValueError(f"--host: with several addresses, each must be an IP address ({h!r} is not)") from None
        if len(set(hosts)) != len(hosts):
            raise ValueError("--host: an address is listed twice")
    return hosts


def require_loopback(hosts: list[str]) -> None:
    """``--dev``: its bearer is a public placeholder, so it listens only on this
    machine (``localhost`` or loopback addresses)."""
    for h in hosts:
        if h.lower() == "localhost":
            continue
        try:
            if ipaddress.ip_address(h).is_loopback:
                continue
        except ValueError:
            pass
        raise ValueError(f"--dev: listens only on loopback (localhost, 127.0.0.1, ::1); {h!r} is not")


def url_for(host: str, port: int) -> str:
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        return f"http://{host}:{port}"
    return f"http://[{host}]:{port}" if literal.version == 6 else f"http://{host}:{port}"


def listen_socket(host: str, port: int) -> socket.socket:
    """A bound TCP socket on one literal address, for a relay that listens on
    several (uvicorn takes one ``host``)."""
    family = socket.AF_INET6 if ipaddress.ip_address(host).version == 6 else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    sock.listen(128)
    sock.set_inheritable(True)
    return sock


if __name__ == "__main__":
    raise SystemExit(main())
