"""The API's JSON for conversations and turns."""

from __future__ import annotations

import json


def turn_json(t: dict) -> dict:
    base = f"/api/v1/conversations/{t['conversation_id']}/turns/{t['id']}"
    ready = t["state"] == "ready"
    return {
        "id": t["id"],
        "conversation_id": t["conversation_id"],
        "seq": t["seq"],
        "client_turn_id": t["client_turn_id"],
        "state": t["state"],
        "user_text": t["user_text"],
        "reply_text": t["reply_text"],
        "attachment": t["attachment"],
        "style_version": t["style_version"],
        "segments": [
            {**seg, "url": f"{base}/segments/{seg['index']}/audio"}
            for seg in (json.loads(t["segments_json"]) if t.get("segments_json") else [])
        ],
        "audio": (
            {
                "url": f"{base}/audio",
                "content_type": "audio/wav",
                "duration_ms": t["audio_duration_ms"],
                "available": not t["audio_deleted"],
            }
            if ready
            else None
        ),
        "timings_url": f"{base}/timings.json" if ready else None,
        "timings_exact_sentences": bool(t["timings_exact"]) if ready else None,
        "cleanup": json.loads(t["cleanup_json"]) if t["cleanup_json"] else [],
        "error": {"code": t["error_code"], "detail": t["error_detail"] or ""} if t["error_code"] else None,
        "created_at": t["created_at"],
        "updated_at": t["updated_at"],
        "ready_at": t["ready_at"],
    }


def conversation_json(c: dict, turns: list[dict] | None = None) -> dict:
    last = c.get("last_turn")
    out = {
        "id": c["id"],
        "title": c["title"],
        "created_at": c["created_at"],
        "updated_at": c["updated_at"],
        "turn_count": c["turn_count"],
        "last_event_id": c["last_event_id"],
        "last_turn": (
            {"id": last["id"], "state": last["state"], "user_text": last["user_text"], "reply_text": last["reply_text"]}
            if last
            else None
        ),
    }
    if turns is not None:
        out["turns"] = [turn_json(t) for t in turns]
    return out
