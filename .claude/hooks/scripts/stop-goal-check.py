#!/usr/bin/env python3
"""Stop hook: goal / plan-ledger evidence after /compact.

[2026-10-02][fix] #1709 /compact 後にプラン台帳証拠を見失って反復発火する
背景:
  - ユーザー依頼意図: Goal 付きセッションで /compact が走ると、Stop hook の goal
    checker が圧縮後 transcript だけを見て「プラン文書・台帳タスク化の証拠がない」
    と誤判定し、台帳はタスク化済み・残りは owner/日付ゲートなのに毎ターン発火する
    （2026-08-13 hermes/juminzei、2026-10-02 bank-payment-automator 実測）。
  - 守るべき業務ルール: compaction summary 内の台帳・タスク化言及も証拠として扱う。
    TaskList の実状態を照合する。plan-commitment-tracking §6 の明示保留
    （owner / 日付待ち / 本人承認待ち / 別プラン）は全消化に数える。
    stop_hook_active / loop_count>0 では無限ループ防止のため無音。
    transcript が読めない・壊れている場合は fail-open（exit 0）。
  - 他案不採用理由:
    1) 発火条件を一律に緩める案は、本当に未台帳化のセッションまで見逃すため不採用。
    2) ルール文書への追記のみは、機械判定が圧縮後 transcript を見ない限り再発するため不採用。
対応: Stop hook が transcript 全体（compaction summary 含む）と TaskList 結果を見て、
  証拠または §6 明示保留だけで残っているときは発火しない。
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any, Iterable

GOAL_ACTIVE_RE = re.compile(
    r"(?i)(?:^|[\s`])/goal\b|CreateGoal|全部[✓✔]|Goal[:：]|goal checker|"
    r"プラン文書|plan document|コミットメント台帳"
)

PLAN_LEDGER_EVIDENCE_RE = re.compile(
    r"(?i)plan document|プラン文書|コミットメント台帳|"
    r"台帳.{0,40}タスク|タスク化|TaskCreate|"
    r"1行\s*=\s*1タスク|1項目\s*=\s*1タスク"
)

TASK_TOOL_NAMES = frozenset(
    {"tasklist", "taskcreate", "todowrite", "creategoal", "updategoal"}
)

HOLD_RE = re.compile(
    r"明示保留|人間ゲート|owner\s*ゲート|本人承認|承認待ち|日付待ち|"
    r"別プラン|次期プラン|該当なし|ユーザー判断|オーナー(?:実機|承認|操作|ゲート)|"
    r"\d{1,2}/\d{1,2}\s*以降|\d{1,2}/\d{1,2}\s*待ち"
)

COMPLETED_STATUSES = frozenset(
    {"completed", "complete", "done", "cancelled", "canceled", "closed"}
)
PENDING_STATUSES = frozenset({"pending", "in_progress", "todo", "open"})

BLOCK_REASON = (
    "Goal が残っています。プラン文書とコミットメント台帳を 1行=1タスクで起票した証拠が"
    " transcript（compaction summary 含む）にも TaskList にもありません。"
    " 台帳化するか、owner/日付/本人ゲートは明示保留（§6）として残してください。"
)


def _read_stdin_json() -> dict:
    raw = sys.stdin.read()
    return json.loads(raw)


def _iter_transcript_lines(transcript_path: str) -> Iterable[Any]:
    with open(transcript_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


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


def is_goal_active(text: str) -> bool:
    return bool(GOAL_ACTIVE_RE.search(text))


def has_plan_ledger_evidence(text: str) -> bool:
    return bool(PLAN_LEDGER_EVIDENCE_RE.search(text))


def is_explicit_hold(text: str) -> bool:
    return bool(HOLD_RE.search(text or ""))


def _parse_json_blob(text: str) -> Any | None:
    text = text.strip()
    if not text or text[0] not in "[{":
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def _task_status(item: dict) -> str:
    for key in ("status", "state", "taskStatus"):
        value = item.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().lower()
    return ""


def _task_text(item: dict) -> str:
    parts = [
        str(item.get(key, ""))
        for key in (
            "content",
            "subject",
            "title",
            "text",
            "description",
            "owner",
            "note",
            "notes",
            "reason",
        )
    ]
    return " ".join(parts)


def _tasks_from_payload(parsed: Any) -> list[dict]:
    if isinstance(parsed, list):
        candidates = parsed
    elif isinstance(parsed, dict):
        candidates = None
        for key in ("tasks", "items", "todos"):
            if isinstance(parsed.get(key), list):
                candidates = parsed[key]
                break
        if candidates is None:
            return []
    else:
        return []
    return [
        item
        for item in candidates
        if isinstance(item, dict)
        and ("status" in item or "content" in item or "subject" in item or "title" in item)
    ]


def extract_tasks(entries: list[Any]) -> list[dict]:
    """Collect TaskList / TodoWrite items from tool results and explicit task JSON."""
    tasks: list[dict] = []
    saw_task_tool = False
    for entry in entries:
        for raw in walk_strings(entry):
            if raw.lower() in TASK_TOOL_NAMES:
                saw_task_tool = True
            parsed = _parse_json_blob(raw)
            if parsed is None:
                continue
            found = _tasks_from_payload(parsed)
            if found and (saw_task_tool or isinstance(parsed, dict)):
                tasks.extend(found)
    return tasks


def task_list_is_complete(tasks: list[dict]) -> bool:
    """True when every task is done or a §6 explicit hold."""
    if not tasks:
        return False
    for item in tasks:
        status = _task_status(item)
        if status in COMPLETED_STATUSES:
            continue
        if is_explicit_hold(_task_text(item)):
            continue
        if status in PENDING_STATUSES or not status:
            return False
    return True


def should_block(entries: list[Any]) -> bool:
    text = combined_transcript_text(entries)
    if not is_goal_active(text):
        return False
    tasks = extract_tasks(entries)
    if tasks:
        return not task_list_is_complete(tasks)
    if has_plan_ledger_evidence(text):
        return False
    return True


def _stop_already_active(payload: dict) -> bool:
    if payload.get("stop_hook_active") is True or payload.get("stopHookActive") is True:
        return True
    loop_count = payload.get("loop_count", payload.get("loopCount", 0))
    try:
        return int(loop_count) > 0
    except (TypeError, ValueError):
        return False


def main() -> int:
    try:
        payload = _read_stdin_json()
    except Exception:
        return 0

    if _stop_already_active(payload):
        return 0

    transcript_path = payload.get("transcript_path") or payload.get("transcriptPath")
    if not transcript_path:
        return 0

    try:
        entries = list(_iter_transcript_lines(str(transcript_path)))
    except Exception:
        return 0

    if not entries:
        return 0

    if not should_block(entries):
        return 0

    print(json.dumps({"decision": "block", "reason": BLOCK_REASON}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
