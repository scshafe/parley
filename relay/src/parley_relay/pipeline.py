"""The turn pipeline: agent → speech → (webhook or poll) → timings → push.

A small job runner. Every step reads the turn's recorded state and writes its
result before the next step starts, so a restart resumes each turn where it
stopped:

- ``thinking`` with no reply: ask the agent; store the raw reply, the cleaned
  spoken text, the attachment and the speech-job plan; → ``speaking``.
- ``speaking``: post each planned job not yet posted (its idempotency key,
  ``turn-<turn>-<n>``, makes a repost after a crash answer the same job), then
  wait for every job to end, woken by the webhook and polling as a backstop;
  fetch the audio, join it, compute ``timings.json``; → ``ready``.
- ``ready`` not yet pushed: send the push; mark it pushed.

Failures end the turn ``failed`` with a code; retryable errors (a busy GPU, an
unreachable agent) are retried with backoff first.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
from collections.abc import Callable
from dataclasses import dataclass

from . import audio, style
from .agent import AgentAdapter, AgentConversation, AgentError
from .push import PushSender
from .sentences import split_for_jobs
from .spoken import clean_reply
from .store import Store, now_iso
from .timings import job_sentences, measure
from .views import turn_json
from .voicelab import TERMINAL_STATES, SpeechClient, SpeechError

log = logging.getLogger("parley.pipeline")


@dataclass
class PipelineSettings:
    callback_url: str | None = None
    poll_interval: float = 15.0
    max_attempts: int = 5
    backoff: float = 2.0
    backoff_cap: float = 120.0
    job_deadline: float = 30 * 60.0
    max_sentence_chars: int | None = None
    audio_retention_days: int = 30
    sweep_interval: float = 3600.0
    snapshot_interval: float = 300.0  # a consistent database copy for the stack's backup, when it changed


class EventBus:
    """Wakes each open event stream when its conversation has a new event."""

    def __init__(self) -> None:
        self._events: dict[str, asyncio.Event] = {}

    def waiter(self, cid: str) -> asyncio.Event:
        return self._events.setdefault(cid, asyncio.Event())

    def notify(self, cid: str) -> None:
        ev = self._events.pop(cid, None)
        if ev is not None:
            ev.set()


class Pipeline:
    def __init__(self, store: Store, agent: AgentAdapter, speech: SpeechClient, push: PushSender,
                 settings: PipelineSettings, bus: EventBus | None = None,
                 sleep: Callable[[float], object] = asyncio.sleep) -> None:
        self.store = store
        self.agent = agent
        self.speech = speech
        self.push = push
        self.settings = settings
        self.bus = bus or EventBus()
        self._sleep = sleep
        self._tasks: dict[str, asyncio.Task] = {}
        self._wake: dict[str, asyncio.Event] = {}
        self._conversation_locks: dict[str, asyncio.Lock] = {}
        self._sweeper: asyncio.Task | None = None
        self._snapshotter: asyncio.Task | None = None
        self._snapshot_changes: int | None = None

    # --- lifecycle ------------------------------------------------------------------------------

    async def start(self) -> None:
        for t in self.store.unfinished_turns():
            log.info("resuming turn %s in state %s", t["id"], t["state"])
            self.submit(t["id"])
        self._sweeper = asyncio.get_running_loop().create_task(self._sweep_loop())
        self._snapshotter = asyncio.get_running_loop().create_task(self._snapshot_loop())

    async def stop(self) -> None:
        tasks = list(self._tasks.values())
        if self._sweeper:
            tasks.append(self._sweeper)
        if self._snapshotter:
            tasks.append(self._snapshotter)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    async def idle(self) -> None:
        """Wait until no turn is being worked on (tests)."""
        while self._tasks:
            await asyncio.gather(*list(self._tasks.values()), return_exceptions=True)

    def submit(self, turn_id: str) -> None:
        if turn_id in self._tasks:
            return
        task = asyncio.get_running_loop().create_task(self._run(turn_id), name=f"turn-{turn_id}")
        self._tasks[turn_id] = task
        task.add_done_callback(lambda _t: self._tasks.pop(turn_id, None))

    def wake(self, turn_id: str) -> None:
        ev = self._wake.get(turn_id)
        if ev is not None:
            ev.set()

    # --- the steps -----------------------------------------------------------------------------

    def _publish(self, turn: dict) -> None:
        self.store.add_event(turn["conversation_id"], "turn.updated", turn_json(turn))
        self.bus.notify(turn["conversation_id"])

    def _fail(self, turn_id: str, code: str, detail: str = "") -> None:
        log.warning("turn %s failed: %s", turn_id, code)
        self._publish(self.store.update_turn(turn_id, state="failed", error_code=code, error_detail=detail))

    async def _retrying(self, what: str, fn, *, retryable_exc):  # type: ignore[no-untyped-def]
        delay = self.settings.backoff
        for attempt in range(1, self.settings.max_attempts + 1):
            try:
                return await fn()
            except retryable_exc as exc:
                if not getattr(exc, "retryable", False) or attempt == self.settings.max_attempts:
                    raise
                wait = getattr(exc, "retry_after", None) or delay
                log.info("%s: %s, retry %d in %.1fs", what, getattr(exc, "code", exc), attempt, wait)
                await self._sleep(min(wait, self.settings.backoff_cap))
                delay = min(delay * 2, self.settings.backoff_cap)
        raise AssertionError("unreachable")

    async def _run(self, turn_id: str) -> None:
        try:
            turn = self.store.get_turn(turn_id)
            if turn is None:
                return
            if turn["state"] == "thinking":
                turn = await self._think(turn)
            if turn is not None and turn["state"] == "speaking":
                turn = await self._speak(turn)
            if turn is not None and turn["state"] == "ready" and not turn["pushed"]:
                try:
                    await self.push.reply_ready(turn["conversation_id"], turn["id"])
                except Exception:  # noqa: BLE001 - a push never fails a ready turn
                    log.exception("turn %s: push failed", turn_id)
                self.store.update_turn(turn_id, pushed=1)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - one turn's bug must not stop the runner
            log.exception("turn %s: internal error", turn_id)
            self._fail(turn_id, "internal_error", "The relay hit an internal error.")

    async def _think(self, turn: dict) -> dict | None:
        cid = turn["conversation_id"]
        lock = self._conversation_locks.setdefault(cid, asyncio.Lock())
        async with lock:  # one agent call at a time per conversation, in turn order
            conv = self.store.get_conversation(cid)
            agent_conv = AgentConversation(cid, conv["title"] if conv else None)
            try:
                raw = await self._retrying(
                    f"turn {turn['id']} agent",
                    lambda: self.agent.send_turn(agent_conv, turn["user_text"]),
                    retryable_exc=AgentError,
                )
            except AgentError as exc:
                self._fail(turn["id"], exc.code, "The agent could not answer.")
                return None
        cleaned = clean_reply(raw)
        jobs = [
            {"index": i, "text_start": sp.start, "text_end": sp.end, "job_id": None, "state": None}
            for i, sp in enumerate(split_for_jobs(cleaned.text), start=1)
        ]
        turn = self.store.update_turn(
            turn["id"],
            state="speaking",
            reply_raw=raw,
            reply_text=cleaned.text,
            attachment=cleaned.attachment,
            cleanup_json=json.dumps(cleaned.changes),
            style_version=style.CURRENT,
            jobs_json=json.dumps(jobs),
        )
        self._publish(turn)
        return turn

    async def _speak(self, turn: dict) -> dict | None:
        tid, cid = turn["id"], turn["conversation_id"]
        text = turn["reply_text"] or ""
        jobs = json.loads(turn["jobs_json"] or "[]")
        wake = self._wake.setdefault(tid, asyncio.Event())
        try:
            for job in jobs:
                if job["job_id"]:
                    continue
                chunk = text[job["text_start"] : job["text_end"]]
                ref = f"{cid}/{tid}" if len(jobs) == 1 else f"{cid}/{tid}/{job['index']}"
                try:
                    st = await self._retrying(
                        f"turn {tid} speech",
                        lambda chunk=chunk, ref=ref, job=job: self.speech.create(
                            chunk,
                            idempotency_key=f"turn-{tid}-{job['index']}",
                            client_ref=ref,
                            callback_url=self.settings.callback_url,
                        ),
                        retryable_exc=SpeechError,
                    )
                except SpeechError as exc:
                    self._fail(tid, "speech_refused", f"voice-lab refused the speech request ({exc.code}).")
                    return None
                job["job_id"], job["state"] = st["id"], st["state"]
                self.store.record_job(st["id"], tid, job["index"])
                self.store.update_turn(tid, jobs_json=json.dumps(jobs))

            statuses: dict[int, dict] = {}
            loop = asyncio.get_running_loop()
            deadline = loop.time() + self.settings.job_deadline
            while True:
                wake.clear()  # before polling, so a webhook during the poll is not lost
                for job in jobs:
                    if job["index"] in statuses:
                        continue
                    try:
                        st = await self.speech.status(job["job_id"])
                    except SpeechError as exc:
                        if exc.retryable:
                            continue
                        self._fail(tid, "speech_failed", f"voice-lab lost the speech job ({exc.code}).")
                        return None
                    if st["state"] in TERMINAL_STATES:
                        statuses[job["index"]] = st
                if len(statuses) == len(jobs):
                    break
                if loop.time() > deadline:
                    self._fail(tid, "speech_timeout", "Speech took too long.")
                    return None
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(wake.wait(), self.settings.poll_interval)
        finally:
            self._wake.pop(tid, None)

        for job in jobs:
            st = statuses[job["index"]]
            if st["state"] != "succeeded":
                code = (st.get("error") or {}).get("code") or st["state"]
                self._fail(tid, "speech_failed", f"voice-lab could not speak the reply ({code}).")
                return None

        parts: list[bytes] = []
        sentences = []
        exact = True
        offset = 0
        for job in jobs:
            st = statuses[job["index"]]
            try:
                wav = await self._retrying(f"turn {tid} audio", lambda st=st: self.speech.audio(st["id"]),
                                           retryable_exc=SpeechError)
            except SpeechError as exc:
                self._fail(tid, "speech_failed", f"voice-lab's audio could not be fetched ({exc.code}).")
                return None
            parts.append(wav)
            segs = sorted(st.get("segments") or [], key=lambda s: s["index"])
            job_dur = audio.info(wav).duration_ms
            if segs and sum(int(s.get("duration_ms") or 0) for s in segs) == 0:
                segs = []
            if not segs:
                segs = [{"index": 1, "duration_ms": job_dur}]
            timed, ok = job_sentences(text, job["text_start"], job["text_end"], segs, offset,
                                      max_sentence_chars=self.settings.max_sentence_chars)
            exact = exact and ok
            sentences.extend(timed)
            offset += job_dur
        joined = audio.join(parts)
        timings = measure(text, sentences, audio.levels(joined))
        timings["duration_ms"] = audio.info(joined).duration_ms
        timings["turn_id"] = tid
        timings["exact_sentences"] = exact

        folder = self.store.turn_dir(tid)
        folder.mkdir(parents=True, exist_ok=True)
        _write_atomic(folder / "reply.wav", joined)
        _write_atomic(folder / "timings.json", json.dumps(timings, separators=(",", ":")).encode())
        turn = self.store.update_turn(
            tid,
            state="ready",
            audio_duration_ms=timings["duration_ms"],
            timings_exact=int(exact),
            ready_at=now_iso(),
            jobs_json=json.dumps([{**j, "state": statuses[j["index"]]["state"]} for j in jobs]),
        )
        self._publish(turn)
        return turn

    # --- retention ----------------------------------------------------------------------------

    def sweep(self) -> int:
        """Delete the audio of turns ready longer ago than the retention (P-Q5:
        30 days). Text and timings stay."""
        n = 0
        for t in self.store.expired_audio(self.settings.audio_retention_days):
            with contextlib.suppress(FileNotFoundError):
                (self.store.turn_dir(t["id"]) / "reply.wav").unlink()
            self.store.update_turn(t["id"], audio_deleted=1)
            n += 1
        return n

    def snapshot_if_changed(self) -> bool:
        """Refresh the database snapshot if anything was written since the last
        one (or none was taken yet)."""
        changes = self.store.changes()
        if changes == self._snapshot_changes and self.store.snapshot_path.exists():
            return False
        self.store.snapshot()
        self._snapshot_changes = changes
        return True

    async def _snapshot_loop(self) -> None:
        try:
            while True:
                try:
                    await asyncio.to_thread(self.snapshot_if_changed)
                except Exception:  # noqa: BLE001
                    log.exception("database snapshot failed")
                await asyncio.sleep(self.settings.snapshot_interval)
        except asyncio.CancelledError:
            # Shutting down (a deploy, a restart): one last copy.
            with contextlib.suppress(Exception):
                self.snapshot_if_changed()
            raise

    async def _sweep_loop(self) -> None:
        while True:
            try:
                self.sweep()
            except Exception:  # noqa: BLE001
                log.exception("retention sweep failed")
            await asyncio.sleep(self.settings.sweep_interval)


def _write_atomic(path, data: bytes) -> None:  # type: ignore[no-untyped-def]
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
