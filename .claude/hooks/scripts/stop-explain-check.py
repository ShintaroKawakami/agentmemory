#!/usr/bin/env python3
# [2026-11-02][feat] 説明の依頼に「検品済みの説明ページの URL」を付けず返そうとした時、返事の直前で1回だけ止める。
# 背景: 合図（UserPromptSubmit の案内）だけでは、文字で返す道が残る
#   （Sol 敵対的レビュー 致命1・伸太郎さん 2026-11-02「言われないと動かないのはあってはならない」）。
# 守る: 説明の依頼の回だけ止める（最後の本人の発言に台帳の発火語がある時）/ 1回まで
#   （stop_hook_active が真なら通す。通した事実は unchecked.jsonl に残す）/
#   ツールの出力は見ない（返事の本文だけ）/ 台帳・記録・会話記録が読めない時は止めない（fail-open）/
#   発火語の判定と URL の抜き出しは切る前の全文で行う（共通部品の parse_* は2万字で切るため使わない）。
# 不採用: 全返事を止める案（重い・説明でない依頼まで止まる）/ 検品の記録なしで URL の形だけ見る案
#   （検品していないページを通してしまう）。
"""Stop hook: 説明の依頼なのに検品済みページの URL が無い返事を、1回だけ止める。

入力: stdin の JSON（Claude Code / Codex の Stop hook 入力）。
  transcript_path / stop_hook_active / last_assistant_message（あれば）を使う。
台帳: hook-library/lib/explain-visual-policy.json の keywords と stop_reason。
  環境変数 EXPLAIN_VISUAL_POLICY_PATH 優先、無ければこのファイルの ../lib/。
配信の記録: ${SERVE_STATUS_STATE_DIR:-~/.agent-hub/session-status}/state（URL= / STATUS_DIR=）。
検品の記録: ${EXPLAIN_CHECK_RECORD_DIR:-~/.cache/agent-hub/explain-check}/records.jsonl
  （check-explain-html.py が書く。path / sha256 / checked_at）。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any
from urllib.parse import unquote, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_transcript_lib import (  # noqa: E402
    _as_role,
    _iso_or_none,
    extract_text,
    is_compaction_entry,
    looks_injected,
)

_SYSTEM_REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
_URL_RE = re.compile(r"https?://[^\s<>\"'`()（）\[\]「」『』、。，,;；]+")
_USER_SKIP_PREFIXES = ("# AGENTS.md instructions", "[Request interrupted")
_URL_TRAILING = ".:!?*"


# ---------------------------------------------------------------- 台帳・記録

def _script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def load_policy() -> dict[str, Any] | None:
    path = os.environ.get("EXPLAIN_VISUAL_POLICY_PATH") or os.path.join(
        _script_dir(), "..", "lib", "explain-visual-policy.json"
    )
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    keywords = data.get("keywords")
    if not isinstance(keywords, list):
        return None
    keywords = [k for k in keywords if isinstance(k, str) and k]
    if not keywords:
        return None
    reason = data.get("stop_reason")
    if not isinstance(reason, str) or not reason.strip():
        return None
    return {"keywords": keywords, "stop_reason": reason}


def _record_dir() -> str:
    return os.environ.get("EXPLAIN_CHECK_RECORD_DIR") or os.path.expanduser("~/.cache/agent-hub/explain-check")


def _state_dir() -> str:
    return os.environ.get("SERVE_STATUS_STATE_DIR") or os.path.expanduser("~/.agent-hub/session-status")


def read_serve_state() -> tuple[str, str] | None:
    """(URL, STATUS_DIR) を返す。読めなければ None。"""
    values: dict[str, str] = {}
    try:
        with open(os.path.join(_state_dir(), "state"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if "=" not in line or line.startswith("#"):
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip("'\"")
    except OSError:
        return None
    url, status_dir = values.get("URL"), values.get("STATUS_DIR")
    if not url or not status_dir:
        return None
    return url, status_dir


def _to_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def read_check_records() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    try:
        with open(os.path.join(_record_dir(), "records.jsonl"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("path"), str) and isinstance(rec.get("sha256"), str):
                    out.append(rec)
    except OSError:
        pass
    return out


def _sha256(path: str) -> str | None:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


# ---------------------------------------------------------------- 会話記録

def _clean_user_text(content: Any) -> str:
    """本人の発言の全文（差し込み文を除く）。"""
    if isinstance(content, list):
        content = [
            block for block in content
            if not (isinstance(block, dict) and isinstance(block.get("text"), str) and looks_injected(block["text"]))
        ]
    text = extract_text(content)
    text = _SYSTEM_REMINDER_RE.sub("", text).strip()
    if not text or looks_injected(text) or text.startswith(_USER_SKIP_PREFIXES):
        return ""
    return text


def _message_of(raw: dict[str, Any]) -> tuple[str, Any, Any] | None:
    """Claude Code / Codex の1行から (role, content, timestamp) を取る。"""
    kind = raw.get("type")
    if kind in ("user", "assistant"):
        if raw.get("isSidechain") is True or raw.get("isMeta") is True:
            return None
        message = raw.get("message")
        if not isinstance(message, dict):
            return None
        role = _as_role(message.get("role") or kind)
        if role is None:
            return None
        return role, message.get("content"), raw.get("timestamp")
    if kind == "response_item":
        payload = raw.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "message":
            return None
        role = _as_role(payload.get("role"))
        if role is None:
            return None
        return role, payload.get("content"), raw.get("timestamp") or payload.get("timestamp")
    return None


def last_user_turn(transcript_path: str) -> dict[str, Any] | None:
    """最後の本人の発言と、その後の assistant 本文（全文）を一度の走査で集める。"""
    turn: dict[str, Any] | None = None
    try:
        fh = open(transcript_path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
            except ValueError:
                continue
            if not isinstance(raw, dict) or is_compaction_entry(raw):
                continue
            found = _message_of(raw)
            if found is None:
                continue
            role, content, timestamp = found
            if role == "user":
                text = _clean_user_text(content)
                if text:
                    turn = {"text": text, "at": _iso_or_none(timestamp), "reply": []}
            elif turn is not None:
                text = extract_text(content)
                if text:
                    turn["reply"].append(text)
    return turn


# ---------------------------------------------------------------- URL → 手元のファイル

def extract_urls(text: str) -> list[str]:
    urls: list[str] = []
    for match in _URL_RE.finditer(text):
        url = match.group(0).rstrip(_URL_TRAILING)
        if url and url not in urls:
            urls.append(url)
    return urls


def urls_to_files(urls: list[str], serve_url: str, status_dir: str) -> list[str]:
    """配信の記録と同じ場所を指す URL だけを、配信フォルダの中の実ファイルに直す。"""
    try:
        base = urlsplit(serve_url)
        root = os.path.realpath(status_dir)
    except ValueError:
        return []
    files: list[str] = []
    for url in urls:
        try:
            parts = urlsplit(url)
            if (parts.scheme.lower(), (parts.hostname or "").lower(), parts.port) != (
                base.scheme.lower(), (base.hostname or "").lower(), base.port
            ):
                continue
            rel = unquote(parts.path)
        except ValueError:
            continue
        if "\x00" in rel:
            continue
        candidate = os.path.realpath(os.path.join(root, rel.lstrip("/")))
        if candidate != root and not candidate.startswith(root + os.sep):
            continue
        if os.path.isdir(candidate):
            candidate = os.path.realpath(os.path.join(candidate, "index.html"))
            if not candidate.startswith(root + os.sep):
                continue
        if os.path.isfile(candidate) and candidate not in files:
            files.append(candidate)
    return files


def is_checked(files: list[str], user_at: datetime | None) -> bool:
    if user_at is None or not files:
        return False
    records = read_check_records()
    for path in files:
        current = None
        for rec in records:
            if rec["path"] != path:
                continue
            checked_at = _to_utc(rec.get("checked_at") if isinstance(rec.get("checked_at"), str) else None)
            if checked_at is None or checked_at <= user_at:
                continue
            if current is None:
                current = _sha256(path)
            if current is not None and rec["sha256"] == current:
                return True
    return False


def log_unchecked(transcript_path: str, user_text: str, urls: list[str]) -> None:
    try:
        directory = _record_dir()
        os.makedirs(directory, exist_ok=True)
        row = {
            "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "transcript_path": transcript_path,
            "user_head": user_text[:80],
            "urls": urls,
        }
        with open(os.path.join(directory, "unchecked.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- main

def _run() -> int:
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    policy = load_policy()
    transcript_path = payload.get("transcript_path")
    if policy is None or not isinstance(transcript_path, str) or not transcript_path:
        return 0
    turn = last_user_turn(transcript_path)
    if turn is None or not any(word in turn["text"] for word in policy["keywords"]):
        return 0

    user_at = _to_utc(turn["at"])
    reply_parts = list(turn["reply"])
    last_message = payload.get("last_assistant_message")
    if isinstance(last_message, str) and last_message.strip():
        reply_parts.append(last_message)
    urls = extract_urls("\n".join(reply_parts))

    served = read_serve_state()
    files = urls_to_files(urls, served[0], served[1]) if served else []
    if is_checked(files, user_at):
        return 0

    if payload.get("stop_hook_active"):
        log_unchecked(transcript_path, turn["text"], urls)
        return 0
    sys.stdout.write(json.dumps({"decision": "block", "reason": policy["stop_reason"]}, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


def main() -> int:
    try:
        return _run()
    except Exception:  # fail-open: 見張りの不具合で返事を止めない
        return 0


if __name__ == "__main__":
    sys.exit(main())
