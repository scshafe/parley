"""Secret files, read when they are needed.

Every secret the relay holds is a file (the stack mounts them at
``/run/secrets``). A :class:`SecretFile` re-reads its file whenever the file
changes, so a secret placed or rotated on the host takes effect without a
restart, and a file that is not there yet is simply "not configured". Values
are never logged; only the setting's name is.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable
from typing import Generic, TypeVar

T = TypeVar("T")

MAX_SECRET_BYTES = 64 * 1024


class SecretFileError(Exception):
    """A secret file that exists but cannot be used (unreadable, empty, too
    large, or not in the expected form). The message names the setting only."""


class SecretFile(Generic[T]):
    """A file whose (stripped) text is parsed by ``parse`` into a value.

    ``get()`` answers ``None`` while the file does not exist, and raises
    :class:`SecretFileError` when it exists but is not usable."""

    def __init__(self, path: str, what: str, parse: Callable[[str], T] = lambda s: s) -> None:  # type: ignore[assignment,return-value]
        self.path = path
        self.what = what
        self._parse = parse
        self._lock = threading.Lock()
        self._stamp: tuple[int, int, int] | None = None
        self._value: T | None = None

    def exists(self) -> bool:
        return os.path.exists(self.path)

    def get(self) -> T | None:
        with self._lock:
            try:
                st = os.stat(self.path)
            except FileNotFoundError:
                self._stamp, self._value = None, None
                return None
            except OSError as exc:
                raise SecretFileError(f"{self.what}: the configured file cannot be read") from exc
            stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
            if stamp == self._stamp:
                return self._value
            if st.st_size > MAX_SECRET_BYTES:
                raise SecretFileError(f"{self.what}: the configured file is too large")
            try:
                with open(self.path, encoding="utf-8") as fh:
                    text = fh.read().strip()
            except (OSError, UnicodeDecodeError) as exc:
                raise SecretFileError(f"{self.what}: the configured file cannot be read") from exc
            if not text:
                raise SecretFileError(f"{self.what}: the configured file is empty")
            try:
                value = self._parse(text)
            except ValueError as exc:
                raise SecretFileError(f"{self.what}: the configured file is not in the expected form") from exc
            self._stamp, self._value = stamp, value
            return value

    def require(self) -> T:
        value = self.get()
        if value is None:
            raise SecretFileError(f"{self.what}: the configured file does not exist")
        return value
