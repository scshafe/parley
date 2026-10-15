"""Serving a file with a single byte ``Range`` (RFC 9110), as voice-lab serves its
audio and as the relay serves a turn's audio to the app's player."""

from __future__ import annotations

import hashlib
import re

from starlette.requests import Request
from starlette.responses import Response

_RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")


def parse_range(header: str | None, size: int) -> tuple[int, int] | None | str:
    """``(start, end)`` inclusive for one satisfiable range; ``None`` to answer the
    whole file (no header, several ranges, another unit or a malformed header);
    ``"unsatisfiable"`` for one range that cannot be served."""
    if not header:
        return None
    m = _RANGE.match(header.strip())
    if not m:
        return None
    first, last = m.group(1), m.group(2)
    if not first and not last:
        return None
    if not first:
        length = int(last)
        if length == 0:
            return "unsatisfiable"
        return (max(0, size - length), size - 1) if size else "unsatisfiable"
    start = int(first)
    end = int(last) if last else size - 1
    if last and end < start:
        return None
    if start >= size:
        return "unsatisfiable"
    return start, min(end, size - 1)


def etag_for(data: bytes) -> str:
    return '"' + hashlib.sha256(data).hexdigest() + '"'


def ranged(request: Request, data: bytes, media_type: str, *, etag: str | None = None,
           extra_headers: dict[str, str] | None = None) -> Response:
    size = len(data)
    headers = {"accept-ranges": "bytes", "etag": etag or etag_for(data)}
    if extra_headers:
        headers.update(extra_headers)
    rng = parse_range(request.headers.get("range"), size)
    head = request.method == "HEAD"
    if rng == "unsatisfiable":
        headers["content-range"] = f"bytes */{size}"
        return Response(b"", status_code=416, headers=headers)
    if rng is None:
        headers["content-length"] = str(size)
        return Response(b"" if head else data, status_code=200, media_type=media_type, headers=headers)
    assert isinstance(rng, tuple)
    start, end = rng
    headers["content-range"] = f"bytes {start}-{end}/{size}"
    headers["content-length"] = str(end - start + 1)
    body = b"" if head else data[start : end + 1]
    return Response(body, status_code=206, media_type=media_type, headers=headers)
