#!/usr/bin/env python3
"""Extract, redact, and track user/assistant session text for Status MCP.

Parsers follow the JSONL shapes already used by skill-doctor's collect_sessions
(Claude Code / Codex rollout). Cursor uses ~/.cursor/projects/*/agent-transcripts.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, NamedTuple

CONTENT_LIMIT = 20_000
CONTENT_OMISSION = "…(省略)"
DEFAULT_STATE_PATH = Path.home() / ".cache/agent-hub/session-transcripts/sent-state.json"
DEFAULT_CONFIG_PATH = Path.home() / ".config/agent-hub/session-transcripts.json"
DEFAULT_BATCH = 40
NOT_FOUND_RETRY_CAP = 3
TOOL_NAMES = ("claude", "codex", "cursor")
CODEX_SURFACES = frozenset({"cli", "codex_subagent", "codex_app"})
DEFAULT_SURFACES = {"claude": "code", "codex": "cli", "cursor": "ide"}
# session_meta.originator / source の実測名 → Status MCP surface。
# skill-doctor collect_sessions と Codex rollout の payload が持つ名前。
CODEX_ORIGINATOR_SURFACES = {
    "cli": "cli",
    "codex_cli_rs": "cli",
    "codex_cli": "cli",
    "codex_tui": "cli",
    "codex_app": "codex_app",
    "codex_desktop": "codex_app",
    "desktop": "codex_app",
    "codex_vscode": "codex_app",
    "vscode": "codex_app",
    "codex_subagent": "codex_subagent",
    "subagent": "codex_subagent",
}
CAPPED_MESSAGE_ERRORS = frozenset({"not_found", "ambiguous"})


class MessageSendError(Exception):
    def __init__(self, code: str, *, retryable: bool, details: Any = None):
        super().__init__(code)
        self.code = code
        self.retryable = retryable
        self.details = details


class CodexRolloutIdentity(NamedTuple):
    session_id: str | None
    parent_session_id: str | None
    surface: str | None
    is_subagent: bool

# Client-side redaction. Receiver applies the same patterns again.
_REDACT_PATTERNS = (
    re.compile(r"(?i)\b(authorization\s*:\s*)bearer\s+\S+"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]{8,}"),
    re.compile(r"(?i)\b(api[-_]?key|access[-_]?token|secret[-_]?key|x-api-key)\s*[:=]\s*\S+"),
    re.compile(r"(?i)\bpassword\s*[:=]\s*\S+"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{10,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bxai-[A-Za-z0-9]{10,}\b"),
)


class TranscriptMessage(NamedTuple):
    seq: int
    role: str
    content: str
    message_at: str | None = None


def truncate_content(text: str, limit: int = CONTENT_LIMIT) -> str:
    if len(text) <= limit:
        return text
    keep = max(0, limit - len(CONTENT_OMISSION))
    return text[:keep] + CONTENT_OMISSION


def redact_secrets(text: str) -> str:
    redacted = text
    for pattern in _REDACT_PATTERNS:
        redacted = pattern.sub("[REDACTED]", redacted)
    return redacted


def extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    parts: list[str] = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict):
                if block.get("type") in {"tool_use", "tool_result", "tool_call", "thinking"}:
                    continue
                value = block.get("text") or block.get("content") or ""
                if isinstance(value, str) and value:
                    parts.append(value)
            elif isinstance(block, str):
                parts.append(block)
    elif isinstance(content, dict):
        return extract_text(content.get("text") or content.get("content") or content.get("parts"))
    return "\n".join(parts)


# [2026-11-02][feat]
# 背景: stop-goal-check.py にだけあった「圧縮要約の行の判定」を stop-explain-check.py でも使う
#   （伸太郎さん 2026-11-02「言われないと動かないのはあってはならない」。圧縮要約に写った発火語を
#   本人の発言と数えると、説明の依頼でない回を止めてしまう）。
# 守る: 判定結果は stop-goal-check.py にあった時と同じ（ハイフン名のファイルは import できないため、
#   共通部品の側へ置いて両方が読む）。
# 不採用: stop-explain-check.py へ判定を複写する案（片方だけ直って食い違う）。
def walk_strings(obj: Any) -> Iterable[str]:
    if isinstance(obj, str):
        yield obj
        return
    if isinstance(obj, dict):
        for value in obj.values():
            yield from walk_strings(value)
        return
    if isinstance(obj, list):
        for value in obj:
            yield from walk_strings(value)


def combined_transcript_text(entries: list[Any]) -> str:
    return "\n".join(walk_strings(entries))


def is_compaction_entry(entry: Any) -> bool:
    return isinstance(entry, dict) and (
        entry.get("isCompactSummary") is True
        or entry.get("isSummary") is True
        or entry.get("type") == "summary"
        or (entry.get("type") == "system" and (
            "compactMetadata" in entry
            or re.search(r"(?i)compaction summary|continued from a previous conversation",
                         combined_transcript_text([entry]))
        ))
    )


def looks_injected(text: str) -> bool:
    head = text.lstrip()[:80]
    return head.startswith("<") and any(
        tag in head
        for tag in (
            "environment_context",
            "user_instructions",
            "ENVIRONMENT",
            "system-reminder",
            "permissions",
            "collaboration_mode",
            "recommended_plugins",
            "turn_context",
        )
    )


def _as_role(value: Any) -> str | None:
    if value in {"user", "human"}:
        return "user"
    if value in {"assistant", "ai", "model"}:
        return "assistant"
    return None


def _iso_or_none(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.isdigit():
        try:
            return datetime.fromtimestamp(int(text) / (1000 if len(text) > 10 else 1), tz=timezone.utc).isoformat()
        except (OverflowError, OSError, ValueError):
            return None
    return text


def _finalize(seq: int, role: str, content: str, message_at: str | None) -> TranscriptMessage | None:
    text = content.strip()
    if not text or looks_injected(text):
        return None
    return TranscriptMessage(
        seq=seq,
        role=role,
        content=truncate_content(redact_secrets(text)),
        message_at=message_at,
    )


def parse_claude_jsonl(path: Path) -> tuple[str | None, list[TranscriptMessage]]:
    session_id: str | None = None
    messages: list[TranscriptMessage] = []
    for seq, raw in _iter_json_lines(path):
        if not session_id:
            value = raw.get("sessionId") or raw.get("session_id")
            if isinstance(value, str) and value.strip():
                session_id = value.strip()
        if raw.get("type") not in {"user", "assistant"}:
            continue
        message = raw.get("message")
        if not isinstance(message, dict):
            continue
        role = _as_role(message.get("role") or raw.get("type"))
        if role is None:
            continue
        text = extract_text(message.get("content"))
        item = _finalize(seq, role, text, _iso_or_none(raw.get("timestamp")))
        if item:
            messages.append(item)
    return session_id or path.stem, messages


def parse_codex_jsonl(path: Path) -> tuple[str | None, list[TranscriptMessage]]:
    identity, messages = parse_codex_rollout(path)
    return identity.session_id, messages


def parse_codex_rollout(path: Path) -> tuple[CodexRolloutIdentity, list[TranscriptMessage]]:
    # [2026-09-26][fix]
    # Sub-agent rollout は親の session_meta をコピーする。最初の payload.id を使うと
    # 子の本文が親 session_id に混ざる。filename 末尾 UUID を正とし、不一致の meta id は親参照。
    file_id = _codex_id_from_name(path.name)
    meta_ids: list[str] = []
    surface_token: str | None = None
    messages: list[TranscriptMessage] = []
    for seq, raw in _iter_json_lines(path):
        payload = raw.get("payload") if isinstance(raw.get("payload"), dict) else {}
        if surface_token is None:
            for key in ("surface", "originator", "source", "thread_source"):
                found = _codex_surface_token(payload.get(key) or raw.get(key))
                if found:
                    surface_token = found
                    break
        if raw.get("type") == "session_meta":
            value = payload.get("id") or payload.get("session_id")
            if isinstance(value, str) and value.strip():
                meta_ids.append(value.strip())
            continue
        if raw.get("type") != "response_item" or payload.get("type") != "message":
            continue
        role = _as_role(payload.get("role"))
        if role is None:
            continue
        text = extract_text(payload.get("content"))
        item = _finalize(seq, role, text, _iso_or_none(raw.get("timestamp") or payload.get("timestamp")))
        if item:
            messages.append(item)
    identity = _codex_identity_from_ids(path, file_id, meta_ids, surface_token)
    return identity, messages


def parse_cursor_jsonl(path: Path) -> tuple[str | None, list[TranscriptMessage]]:
    session_id: str | None = path.stem if path.stem else None
    messages: list[TranscriptMessage] = []
    for seq, raw in _iter_json_lines(path):
        for key in ("conversation_id", "sessionId", "session_id"):
            value = raw.get(key)
            if isinstance(value, str) and value.strip():
                session_id = value.strip()
                break
        role = _as_role(raw.get("role") or raw.get("type"))
        if role is None:
            continue
        message = raw.get("message")
        if isinstance(message, dict):
            role = _as_role(message.get("role")) or role
            text = extract_text(message.get("content"))
        else:
            text = extract_text(raw.get("content") or raw.get("text"))
        item = _finalize(
            seq,
            role,
            text,
            _iso_or_none(raw.get("createdAt") or raw.get("timestamp") or raw.get("message_at")),
        )
        if item:
            messages.append(item)
    return session_id, messages


def parse_transcript(tool: str, path: Path) -> tuple[str | None, list[TranscriptMessage]]:
    if tool == "claude":
        return parse_claude_jsonl(path)
    if tool == "codex":
        return parse_codex_jsonl(path)
    if tool == "cursor":
        return parse_cursor_jsonl(path)
    raise ValueError(f"unknown_tool:{tool}")


_CODEX_FILE_UUID = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\.jsonl)?$",
    re.I,
)


def _codex_id_from_name(name: str) -> str | None:
    # rollout-2026-09-25T01-02-03-<uuid>.jsonl — UUID at the end only.
    match = _CODEX_FILE_UUID.search(name)
    return match.group(1) if match else None


def _ids_equal(left: str, right: str) -> bool:
    return left.lower() == right.lower()


def _codex_identity_from_ids(
    path: Path,
    file_id: str | None,
    meta_ids: list[str],
    surface_token: str | None,
) -> CodexRolloutIdentity:
    matching_meta = next((item for item in meta_ids if file_id and _ids_equal(item, file_id)), None)
    copied_parent = next((item for item in meta_ids if file_id and not _ids_equal(item, file_id)), None)
    if file_id:
        session_id = matching_meta or file_id
        is_subagent = copied_parent is not None or surface_token == "codex_subagent"
        parent_id = copied_parent
    else:
        name_l = path.name.lower()
        named = next((item for item in meta_ids if item.lower() in name_l), None)
        session_id = named or (meta_ids[0] if meta_ids else path.stem)
        is_subagent = surface_token == "codex_subagent"
        parent_id = None
    # 親セッションが cli と codex_app の二重登録だと surface 無しは ambiguous。
    # 子は filename UUID で分け、本体は originator 由来、無ければ cli。
    surface = "codex_subagent" if is_subagent else (surface_token or DEFAULT_SURFACES["codex"])
    return CodexRolloutIdentity(
        session_id=session_id,
        parent_session_id=parent_id,
        surface=surface,
        is_subagent=is_subagent,
    )


def inspect_codex_identity(path: Path) -> CodexRolloutIdentity:
    identity, _messages = parse_codex_rollout(path)
    return identity


def _iter_json_lines(path: Path) -> Iterable[tuple[int, dict[str, Any]]]:
    try:
        handle = path.open(encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for index, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(raw, dict):
                yield index, raw


def discover_transcripts(home: Path | None = None) -> list[tuple[str, Path]]:
    root = home or Path.home()
    found: list[tuple[str, Path]] = []
    claude = root / ".claude" / "projects"
    if claude.is_dir():
        found.extend(("claude", path) for path in claude.glob("*/*.jsonl"))
    for sub in ("sessions", "archived_sessions"):
        codex = root / ".codex" / sub
        if codex.is_dir():
            found.extend(("codex", path) for path in codex.rglob("rollout-*.jsonl"))
    cursor = root / ".cursor" / "projects"
    if cursor.is_dir():
        found.extend(("cursor", path) for path in cursor.glob("*/agent-transcripts/*.jsonl"))
    return found


_CWD_IN_TEXT = re.compile(r"<cwd>\s*([^<]+?)\s*</cwd>|(?:^|[\s>])cwd=([^\s<]+)", re.I)


def _cwd_from_mapping(data: dict[str, Any]) -> str | None:
    value = data.get("cwd")
    if isinstance(value, str) and value.strip():
        return value.strip()
    payload = data.get("payload")
    if isinstance(payload, dict):
        nested = payload.get("cwd")
        if isinstance(nested, str) and nested.strip():
            return nested.strip()
    return None


def _cwd_from_injected(text: str) -> str | None:
    match = _CWD_IN_TEXT.search(text)
    if not match:
        return None
    value = (match.group(1) or match.group(2) or "").strip()
    return value or None


# [2026-09-26][fix]
# Codex sub-agent rollout の payload.source は dict。`value in CODEX_SURFACES` は TypeError になる。
# 文字列は originator 実名（codex_cli_rs 等）を surface に写し、dict は入れ子キーだけ見る。
def _map_codex_surface_name(value: str) -> str | None:
    raw = value.strip()
    if not raw:
        return None
    if raw in CODEX_SURFACES:
        return raw
    token = raw.lower().replace("-", "_").replace(" ", "_")
    mapped = CODEX_ORIGINATOR_SURFACES.get(token)
    if mapped:
        return mapped
    if "subagent" in token:
        return "codex_subagent"
    if "desktop" in token or "vscode" in token:
        return "codex_app"
    return None


def _codex_surface_token(value: Any) -> str | None:
    if isinstance(value, str):
        return _map_codex_surface_name(value)
    if isinstance(value, dict):
        for key in ("surface", "originator", "source", "type", "name", "kind", "thread_source"):
            found = _codex_surface_token(value.get(key))
            if found:
                return found
    return None


def canonical_codex_surface(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    return _map_codex_surface_name(value)


def extract_surface(tool: str, path: Path) -> str | None:
    if tool != "codex":
        return None
    return inspect_codex_identity(path).surface


def extract_started_at(path: Path) -> str | None:
    """First timestamp in the transcript JSONL. Used only for register_agent_session."""
    scanned = 0
    for _seq, raw in _iter_json_lines(path):
        scanned += 1
        if scanned > 40:
            break
        found = _iso_or_none(raw.get("timestamp") or raw.get("createdAt") or raw.get("started_at"))
        if found:
            return found
        payload = raw.get("payload")
        if isinstance(payload, dict):
            found = _iso_or_none(payload.get("timestamp") or payload.get("started_at"))
            if found:
                return found
    return None


HOST_ID_ENV = "AGENT_HUB_SESSION_HOST_ID"


def resolve_session_host_id(
    explicit: str | None = None,
    *,
    environ: dict[str, str] | None = None,
    node: str | None = None,
) -> str:
    env = environ if environ is not None else os.environ
    for value in (explicit, env.get(HOST_ID_ENV), node):
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise ValueError("host_id_unavailable")


def register_session_args(
    *,
    tool: str,
    session_id: str,
    host_id: str,
    surface: str | None = None,
    started_at: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "provider": tool,
        "surface": surface if surface else DEFAULT_SURFACES.get(tool, "cli"),
        "host_id": host_id,
        "external_session_id": session_id,
    }
    if started_at:
        payload["started_at"] = started_at
    return payload


def message_call_args(
    *,
    tool: str,
    session_id: str,
    messages: list[dict[str, Any]],
    host_id: str | None,
    cwd: str | None = None,
    surface: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"tool": tool, "session_id": session_id, "messages": messages}
    if host_id and host_id.strip():
        payload["host_id"] = host_id.strip()
    if cwd:
        payload["cwd"] = cwd
    if tool == "codex" and surface in CODEX_SURFACES:
        payload["surface"] = surface
    return payload


def _error_code(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        for key in ("code", "name", "error"):
            found = _error_code(value.get(key))
            if found:
                return found
    return None


def tool_payload(tool_result: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(tool_result, dict):
        return None
    structured = tool_result.get("structuredContent")
    if isinstance(structured, dict):
        return structured
    for block in tool_result.get("content", []):
        if isinstance(block, dict) and block.get("type") == "text":
            try:
                value = json.loads(block.get("text", ""))
            except (ValueError, TypeError):
                continue
            if isinstance(value, dict):
                return value
    return tool_result if "error" in tool_result else None


def _error_candidates(value: Any) -> list[Any]:
    if isinstance(value, dict):
        for key in ("candidates", "sessions", "matches"):
            found = value.get(key)
            if isinstance(found, list) and found:
                return found
        nested = value.get("error")
        if nested is not value:
            return _error_candidates(nested)
    return []


def format_ambiguous_error(*, session_id: str, surface: str | None, details: Any) -> str:
    candidates = _error_candidates(details)
    rendered = json.dumps(candidates, ensure_ascii=False, default=str) if candidates else "[]"
    surface_text = surface or "(none)"
    return (
        f"status-mcp ambiguous session_id={session_id} surface={surface_text} "
        f"candidates={rendered}"
    )


def raise_if_message_failed(tool_result: Any) -> dict[str, Any]:
    if not isinstance(tool_result, dict):
        raise MessageSendError("tool_error", retryable=True)
    payload = tool_payload(tool_result) or {}
    code = None
    if tool_result.get("isError") is True:
        code = _error_code(payload.get("error")) or _error_code(payload) or "tool_error"
    elif payload.get("error") is not None:
        code = _error_code(payload.get("error")) or "error"
    if code:
        raise MessageSendError(code, retryable=code not in CAPPED_MESSAGE_ERRORS, details=payload)
    return payload


def extract_cwd(tool: str, path: Path) -> str | None:
    """First cwd recorded in the transcript JSONL. No git lookup."""
    scanned = 0
    for _seq, raw in _iter_json_lines(path):
        scanned += 1
        if scanned > 40:
            break
        found = _cwd_from_mapping(raw)
        if found:
            return found
        message = raw.get("message")
        if isinstance(message, dict):
            injected = _cwd_from_injected(extract_text(message.get("content")))
            if injected:
                return injected
        injected = _cwd_from_injected(extract_text(raw.get("content") or raw.get("text")))
        if injected:
            return injected
    return None


def find_transcript_path(tool: str, session_id: str, event: dict[str, Any], home: Path | None = None) -> Path | None:
    explicit = event.get("transcript_path")
    if isinstance(explicit, str) and explicit.strip():
        path = Path(explicit.strip())
        if path.is_file():
            return path
    root = home or Path.home()
    if tool == "claude":
        matches = list((root / ".claude" / "projects").glob(f"*/{session_id}.jsonl"))
        return matches[0] if matches else None
    if tool == "codex":
        for sub in ("sessions", "archived_sessions"):
            matches = list((root / ".codex" / sub).rglob(f"rollout-*{session_id}*.jsonl"))
            if matches:
                return matches[0]
        return None
    if tool == "cursor":
        matches = list((root / ".cursor" / "projects").glob(f"*/agent-transcripts/{session_id}.jsonl"))
        return matches[0] if matches else None
    return None


def load_config(path: Path | None = None, environ: dict[str, str] | None = None) -> dict[str, Any]:
    env = environ if environ is not None else os.environ
    config_path = path or Path(env.get("AGENT_HUB_SESSION_TRANSCRIPT_CONFIG") or DEFAULT_CONFIG_PATH)
    data: dict[str, Any] = {}
    try:
        loaded = json.loads(config_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            data = loaded
    except (OSError, ValueError, TypeError):
        data = {}
    try:
        batch_size = int(data.get("batch_size") or DEFAULT_BATCH)
    except (TypeError, ValueError):
        batch_size = DEFAULT_BATCH
    return {"batch_size": batch_size if batch_size > 0 else DEFAULT_BATCH}


def resolve_state_path(environ: dict[str, str] | None = None) -> Path:
    env = environ if environ is not None else os.environ
    override = env.get("AGENT_HUB_SESSION_TRANSCRIPT_STATE")
    return Path(override) if override else DEFAULT_STATE_PATH


def load_state(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {"files": {}, "queue": [], "not_found": {}}
    if not isinstance(data, dict):
        return {"files": {}, "queue": [], "not_found": {}}
    files = data.get("files")
    queue = data.get("queue")
    pending = data.get("pending")
    not_found = data.get("not_found")
    return {
        "files": files if isinstance(files, dict) else {},
        "queue": queue if isinstance(queue, list) else [],
        "pending": pending if isinstance(pending, list) else [],
        "not_found": not_found if isinstance(not_found, dict) else {},
    }


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(state, ensure_ascii=False, indent=2) + "\n"
    fd, tmp = tempfile.mkstemp(prefix="sent-state.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _file_key(path: Path) -> str:
    try:
        return str(path.resolve())
    except OSError:
        return str(path)


def not_found_count(state: dict[str, Any], path: Path) -> int:
    record = state.get("not_found", {}).get(_file_key(path))
    if not isinstance(record, dict):
        return 0
    value = record.get("count")
    return value if isinstance(value, int) and value > 0 else 0


def record_not_found(
    state: dict[str, Any],
    path: Path,
    *,
    tool: str,
    session_id: str,
    reason: str,
) -> int:
    files = state.setdefault("not_found", {})
    key = _file_key(path)
    current = files.get(key)
    count = int(current.get("count") or 0) + 1 if isinstance(current, dict) else 1
    files[key] = {
        "tool": tool,
        "session_id": session_id,
        "reason": reason,
        "count": count,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    return count


def not_found_capped(state: dict[str, Any], path: Path, cap: int = NOT_FOUND_RETRY_CAP) -> bool:
    return not_found_count(state, path) >= cap


def last_sent_seq(state: dict[str, Any], path: Path) -> int:
    record = state.get("files", {}).get(_file_key(path))
    if not isinstance(record, dict):
        return 0
    value = record.get("last_seq")
    return value if isinstance(value, int) and value >= 0 else 0


def mark_sent(
    state: dict[str, Any],
    path: Path,
    *,
    tool: str,
    session_id: str,
    last_seq: int,
    parent_session_id: str | None = None,
    surface: str | None = None,
) -> None:
    files = state.setdefault("files", {})
    current = files.get(_file_key(path))
    record = dict(current) if isinstance(current, dict) else {}
    record.update(
        {
            "tool": tool,
            "session_id": session_id,
            "last_seq": last_seq,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
    )
    if parent_session_id:
        record["parent_session_id"] = parent_session_id
    if surface:
        record["surface"] = surface
    files[_file_key(path)] = record


def enqueue_session(
    state: dict[str, Any],
    path: Path,
    *,
    tool: str,
    session_id: str,
    ended: bool,
) -> None:
    key = _file_key(path)
    files = state.setdefault("files", {})
    current = files.get(key)
    record = dict(current) if isinstance(current, dict) else {}
    record.update(
        {
            "tool": tool,
            "session_id": session_id,
            "ended": bool(ended or record.get("ended")),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
    )
    files[key] = record
    pending = state.setdefault("pending", [])
    if any(isinstance(item, dict) and item.get("path") == key for item in pending):
        for item in pending:
            if isinstance(item, dict) and item.get("path") == key and ended:
                item["ended"] = True
        return
    pending.append({"path": key, "tool": tool, "session_id": session_id, "ended": ended})


def enqueue_retry(state: dict[str, Any], path: Path, reason: str) -> None:
    key = _file_key(path)
    queue = state.setdefault("queue", [])
    if any(isinstance(item, dict) and item.get("path") == key for item in queue):
        return
    queue.append({"path": key, "reason": reason, "at": datetime.now(timezone.utc).isoformat()})


def clear_retry(state: dict[str, Any], path: Path) -> None:
    key = _file_key(path)
    state["queue"] = [
        item for item in state.get("queue", []) if not (isinstance(item, dict) and item.get("path") == key)
    ]


def messages_payload(messages: list[TranscriptMessage]) -> list[dict[str, Any]]:
    payload = []
    for item in messages:
        row: dict[str, Any] = {"seq": item.seq, "role": item.role, "content": item.content}
        if item.message_at:
            row["message_at"] = item.message_at
        payload.append(row)
    return payload


SendFn = Callable[[str, str, list[dict[str, Any]]], dict[str, Any]]
PrepareFn = Callable[[str, Path, str], None]


def send_unsent(
    *,
    tool: str,
    path: Path,
    session_id: str | None,
    state: dict[str, Any],
    send: SendFn,
    batch_size: int = DEFAULT_BATCH,
    prepare: PrepareFn | None = None,
) -> dict[str, Any]:
    parent_session_id: str | None = None
    surface: str | None = None
    if tool == "codex":
        identity, messages = parse_codex_rollout(path)
        parsed_id = identity.session_id
        parent_session_id = identity.parent_session_id
        surface = identity.surface
        resolved_id = parsed_id
    else:
        parsed_id, messages = parse_transcript(tool, path)
        resolved_id = session_id or parsed_id
    if not resolved_id or not messages:
        return {"sent": 0, "skipped": 0, "queued": False}
    if not_found_capped(state, path):
        return {"sent": 0, "skipped": len(messages), "queued": False, "capped": True}
    after = last_sent_seq(state, path)
    pending = [item for item in messages if item.seq > after]
    sent = 0
    try:
        if prepare:
            prepare(tool, path, resolved_id)
        for start in range(0, len(pending), batch_size):
            chunk = pending[start : start + batch_size]
            result = send(tool, resolved_id, messages_payload(chunk))
            if isinstance(result, dict):
                raise_if_message_failed(result)
            mark_sent(
                state,
                path,
                tool=tool,
                session_id=resolved_id,
                last_seq=chunk[-1].seq,
                parent_session_id=parent_session_id,
                surface=surface,
            )
            sent += len(chunk)
        clear_retry(state, path)
        return {"sent": sent, "skipped": len(messages) - len(pending), "queued": False}
    except MessageSendError as exc:
        if exc.code == "ambiguous":
            print(
                format_ambiguous_error(session_id=resolved_id, surface=surface, details=exc.details),
                file=sys.stderr,
            )
            record_not_found(state, path, tool=tool, session_id=resolved_id, reason="ambiguous")
            key = _file_key(path)
            current = state.get("not_found", {}).get(key)
            if isinstance(current, dict):
                current["count"] = NOT_FOUND_RETRY_CAP
                current["candidates"] = _error_candidates(exc.details)
            return {
                "sent": sent,
                "skipped": len(messages) - len(pending) - (len(pending) - sent),
                "queued": False,
                "capped": True,
            }
        if exc.code in CAPPED_MESSAGE_ERRORS:
            count = record_not_found(state, path, tool=tool, session_id=resolved_id, reason=exc.code)
            if count < NOT_FOUND_RETRY_CAP:
                enqueue_retry(state, path, exc.code)
                return {"sent": sent, "skipped": len(messages) - len(pending) - (len(pending) - sent), "queued": True}
            return {"sent": sent, "skipped": len(messages) - len(pending) - (len(pending) - sent), "queued": False, "capped": True}
        enqueue_retry(state, path, exc.code)
        return {"sent": sent, "skipped": len(messages) - len(pending) - (len(pending) - sent), "queued": True}
    except Exception as exc:
        enqueue_retry(state, path, type(exc).__name__)
        return {"sent": sent, "skipped": len(messages) - len(pending) - (len(pending) - sent), "queued": True}


def catch_up(
    *,
    home: Path | None,
    state_path: Path,
    send: SendFn,
    batch_size: int = DEFAULT_BATCH,
    prepare: PrepareFn | None = None,
) -> dict[str, Any]:
    """Send new redacted user/assistant messages. Hooks only enqueue."""
    state = load_state(state_path)
    totals = {"files": 0, "sent": 0, "queued": 0}
    seen: set[str] = set()
    candidates: list[tuple[str, Path, str | None]] = []
    for item in state.get("pending", []):
        if not isinstance(item, dict):
            continue
        path = Path(str(item.get("path") or ""))
        tool = item.get("tool")
        if tool not in TOOL_NAMES or not path.is_file():
            continue
        candidates.append((tool, path, item.get("session_id") if isinstance(item.get("session_id"), str) else None))
    for tool, path in discover_transcripts(home):
        candidates.append((tool, path, None))
    for tool, path, queued_id in candidates:
        key = _file_key(path)
        if key in seen:
            continue
        seen.add(key)
        totals["files"] += 1
        result = send_unsent(
            tool=tool,
            path=path,
            session_id=queued_id,
            state=state,
            send=send,
            batch_size=batch_size,
            prepare=prepare,
        )
        totals["sent"] += int(result["sent"])
        if result["queued"]:
            totals["queued"] += 1
    state["pending"] = []
    save_state(state_path, state)
    return totals


def audit_parent_collisions(
    *,
    home: Path | None,
    parent_ids: list[str] | None = None,
    state_path: Path | None = None,
) -> dict[str, Any]:
    """Dry-run only. Count sub-agent messages that were or would be stored under a parent id."""
    wanted = {item.strip().lower() for item in parent_ids or [] if isinstance(item, str) and item.strip()}
    state = load_state(state_path) if state_path else {"files": {}}
    files_out: list[dict[str, Any]] = []
    parents: dict[str, dict[str, int]] = {}
    for tool, path in discover_transcripts(home):
        if tool != "codex":
            continue
        identity, messages = parse_codex_rollout(path)
        parent_id = identity.parent_session_id
        if not parent_id:
            continue
        if wanted and parent_id.lower() not in wanted:
            continue
        sent_record = state.get("files", {}).get(_file_key(path))
        already = 0
        stored_as_parent = False
        if isinstance(sent_record, dict):
            stored_id = sent_record.get("session_id")
            if isinstance(stored_id, str) and _ids_equal(stored_id, parent_id):
                stored_as_parent = True
                last = sent_record.get("last_seq")
                already = last if isinstance(last, int) and last > 0 else 0
        row = {
            "path": str(path),
            "file_session_id": identity.session_id,
            "parent_session_id": parent_id,
            "surface": identity.surface,
            "message_count": len(messages),
            "already_sent_as_parent": stored_as_parent,
            "already_sent_last_seq": already,
        }
        files_out.append(row)
        bucket = parents.setdefault(parent_id, {"files": 0, "messages": 0})
        bucket["files"] += 1
        bucket["messages"] += len(messages)
    return {
        "dry_run": True,
        "deleted": 0,
        "note": (
            "Local Codex sub-agent files whose copied session_meta id is a parent. "
            "message_count is how many agent_session_messages rows would be (or were) "
            "stored under that parent. This does not query or delete the Status DB."
        ),
        "parents": parents,
        "files": files_out,
    }
