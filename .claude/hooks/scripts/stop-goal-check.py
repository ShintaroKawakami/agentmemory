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

# [2026-10-04][fix] 文書名だけの閲覧依頼は Goal 開始の根拠ではない。
# 文書名で起動する案は通常の読取依頼を止めるため採らない。明示のGoal根拠は維持する。
GOAL_ACTIVE_RE = re.compile(
    r"(?im)^[ \t]*(?:compaction summary:[ \t]*)?(?:/goal\b|(?:このプランを)?全部[✓✔](?:にして(?:ください)?(?=$|[。!！\s])|[。!！ \t]*$))"
)

# Goal開始と状態の読取りで同じ見出しを使う。別の広い単語検索は採らない。
SUMMARY_GOAL_RE = re.compile(
    r"(?im)^[ \t]*(?:compaction summary:[ \t]*)?Goal[:：]([^\n]*(?:\n[ \t]*(?:状態|status)[:：][^\n]*)?)"
)

# [2026-10-04][fix] 依頼に台帳という語があるだけでは作成の証拠にならない。
# 完了した操作の明記を使い、user の要求文は should_block 側で除外する。
# 単語追加だけで緩和する案は未作成を見逃すため採らない。
PLAN_LEDGER_EVIDENCE_RE = re.compile(
    r"(?i)(?:台帳|タスク|plan|ledger).{0,80}"
    r"(?:(?:タスク化(?:済み|した|しました|完了)|起票済み|作成済み)(?:です|でした|である)?(?=$|[\s、,。.!）)])|\b(?:was|has been)\s+(?:created|tasked|taskized)\b)"
)
NEGATIVE_EVIDENCE_RE = re.compile(r"まだ|未作成|未起票|していない|してない|\bnot\b|n't|\byet\b|未完了|\b(?:will|would|could|should|never)\b|予定|仮定|場合|したい|ですか|でしょうか|[?？]", re.IGNORECASE)

TASK_TOOL_NAMES = frozenset(
    {"tasklist", "taskcreate", "todowrite", "creategoal", "updategoal"}
)

# [2026-10-04][fix] §6 の明示保留を札として確認する。
# 承認の自然文から状態を推測する案は、否定・予定・条件で誤終了/誤停止が
# 繰り返されたため採らない。未完了のまま、札と owner を明記する契約を使う。
HOLD_RE = re.compile(
    r"^[ \t]*(?:\[明示保留\](?=[ \t]|$)|【明示保留】(?=[ \t]|$)|明示保留[:：])"
    r"[ \t]*owner[ \t]*[=：:][ \t]*(?P<owner>[^\s/]+)"
)


COMPLETED_STATUSES = frozenset(
    {"completed", "complete", "done", "cancelled", "canceled", "closed", "deleted"}
)
PENDING_STATUSES = frozenset({"pending", "in_progress", "todo", "open"})

BLOCK_REASON = (
    "Goal の完了を確認できません。タスクが未完了・確認待ち、または今回の起票証拠が不足しています。"
    " 既存の TaskList と transcript（compaction summary 含む）を確認し、未完了の作業を進めてください。"
    " プラン文書の未起票項目だけを 1行=1タスクで起票してください。"
    " 本人判断などで保留する項目は [明示保留] の札と owner を付けて残してください（§6）。"
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
    return bool(GOAL_ACTIVE_RE.search(text) or SUMMARY_GOAL_RE.search(text))


def _is_compaction_entry(entry: Any) -> bool:
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


def _without_goal_annotations(text: str) -> str | None:
    # [2026-10-05][fix] 括弧内の句読点・別状態はGoalの状態欄ではない。
    # 補足を平文として分割する案は、別作業のcompletedを流用するため採らない。
    pairs = {"(": ")", "（": "）"}
    stack: list[str] = []
    annotation: list[str] = []
    output: list[str] = []
    for char in text:
        if char in pairs:
            if not stack:
                annotation = []
                output.append(char)
            stack.append(pairs[char])
        elif char in pairs.values():
            if not stack or stack.pop() != char:
                return None
            if not stack:
                # 不確実性だけ残し、後段で状態欄の注記に限定して判定する。
                if re.search(r"(?i)未確認|\bnot\s+confirmed\b|[?？]", "".join(annotation)):
                    output.append("?")
                output.append(char)
        elif stack:
            annotation.append(char)
        elif not stack:
            output.append(char)
    return None if stack else "".join(output)




def _normalize_goal_field_format(text: str) -> str:
    text = re.sub(r"[*_`]", "", text)
    text = re.sub(r"(?m)^[ \t]*(?:(?:[-+>•]|#{1,6}|\d+[.)])[ \t]+)+", "", text)
    return re.sub(r"\n(?:[ \t]*\n)+", "\n", text)


def _summary_goal_fields(text: str, *, allow_quoted_state: bool = True) -> str:
    # [2026-10-05][fix] 引用されたGoal宣言・コード例は現在の状態欄ではない。
    # 書式を先に消す案は例のcompletedで現Goalを解除するため採らない。
    # 既存の単独status欄の引用書式は維持し、Goalを含む引用ブロックは全体を除外する。
    # [2026-10-05][fix] 引用フェンス・引用継続・コードスパンの旧状態を解除根拠にしない。
    # 意味語を増やす案は採らず、引用単位を先に除外して実際の状態値書式だけ保持する。
    list_prefix = r"^[ \t]*(?:(?:[-+*•]|\d+[.)])[ \t]+)+"
    lines = text.splitlines()
    output: list[str] = []
    fence = ""
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        # 開いているフェンスは原文の閉じ行を先に読む。外側の字下げ除外で消さない。
        if not fence:
            if line.startswith(("    ", "\t")):
                output.append("")
                continue
            line = re.sub(list_prefix, "", line)
        marker = re.match(r"^[ \t]*(`{3,}|~{3,})", line)
        if marker:
            token = marker.group(1)
            if (not fence and token[0] == "`"
                    and re.search(r"(?<!`)" + re.escape(token) + r"(?!`)", line[marker.end():])):
                output.append(line)
                continue
            if not fence:
                fence = token
            elif (token[0] == fence[0] and len(token) >= len(fence)
                  and not line[marker.end():].strip()):
                fence = ""
            output.append("")
            continue
        if fence:
            continue
        if re.match(r"^[ \t]*>", line):
            quoted = [line]
            quote_fence_re = r"^[ \t]*(?:>[ \t]*)+(`{3,}|~{3,})"
            quote_has_fence = bool(re.match(quote_fence_re, line))
            while index < len(lines) and lines[index].strip():
                continuation = lines[index]
                if (not re.match(r"^[ \t]*>", re.sub(list_prefix, "", continuation))
                        and (quote_has_fence or re.match(r"^[ \t]*(?:#{1,6}\s|[-+*]\s|\d+[.)]\s|`{3,}|~{3,})", continuation))):
                    break
                quoted.append(re.sub(list_prefix, "", continuation))
                quote_has_fence = quote_has_fence or bool(re.match(quote_fence_re, quoted[-1]))
                index += 1
            if (not allow_quoted_state or is_goal_active(_normalize_goal_field_format("\n".join(quoted)))
                    or quote_has_fence):
                output.append("")
                continue
            output.extend(quoted)
        else:
            output.append(line)
    # コードスパンは改行を含めて一単位。状態値のコード書式は値を保持する。
    # 除外跡を残し、引用Goal名の後ろの状態欄だけを現在Goalへ接ぎ木しない。
    return re.sub(r"(`+)(?!`)(.*?)\1(?!`)",
                  lambda match: "[code]: " if (not allow_quoted_state or is_goal_active(_normalize_goal_field_format(match.group(2)))
                                       or re.search(r"(?i)(?:status|状態)[:：]", match.group(2)))
                  else match.group(2), "\n".join(output), flags=re.DOTALL)


def _current_summary_goal_text(text: str) -> str:
    # [2026-10-05][fix] 状態欄と台帳証拠を同じ最新Goal開始位置で区切る。
    # 状態だけ切って全文の旧起票証拠を流用する案は、新Goalの未起票を見逃すため採らない。
    starts = [match.start() for pattern in (SUMMARY_GOAL_RE, GOAL_ACTIVE_RE)
              for match in pattern.finditer(text)]
    return text[max(starts):] if starts else text


def _goal_scope(entries: list[Any]) -> tuple[bool, list[Any], set[str]]:
    # [2026-10-04][fix] 読取結果・操作引数はGoalの指示ではない。
    # 会話全体の単語検索と旧Goalの完了記録流用は採らない。
    # 発言/実際のGoal操作/圧縮要約を区別し、最新開始以降だけを扱う。
    stream: list[Any] = []
    for entry in entries:
        message = entry.get("message", entry) if isinstance(entry, dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(entry, dict) and entry.get("type") in {"user", "assistant"} and isinstance(content, list):
            for block in content:
                stream.append({**entry, "message": {**message, "content": [block]}})
        else:
            stream.append(entry)
    failed_calls: set[str] = set()
    for entry in stream:
        if not isinstance(entry, dict):
            continue
        message = entry.get("message", entry)
        content = message.get("content", []) if isinstance(message, dict) else []
        blocks = [entry] if entry.get("type") == "tool_result" else content if isinstance(content, list) else []
        for block in blocks:
            if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error") is True:
                failed_calls.add(str(block.get("tool_use_id", "")))
    # [2026-10-04][fix] 配布レビューで停止済みGoalと並行更新の誤判定が判明。
    # 成功した状態更新だけ採用し、要求・失敗・古いGoalの応答では解除しない。
    # 応答の最後だけを採る案は並行したpendingを消すため採らない。
    # 空一覧だけでpendingを消さず、矛盾するTodoWriteは再確認まで未確認にする。
    # [2026-10-04][fix] 停止成功後は、圧縮要約のGoal言及だけで再開しない。
    # 空Todoも未完了を消した証拠にしない。別の完了履歴へ寄せる案は採らない。
    goal_updates: dict[str, tuple[str, int]] = {}
    active = False
    stopped = False
    start = 0
    for index, entry in enumerate(stream):
        if not isinstance(entry, dict):
            continue
        if _is_compaction_entry(entry):
            # [2026-10-04][fix] 圧縮要約の停止状態を再開と混同しない。
            # checkerの話題だけで開始する案と、pausedを無視する案は採らない。
            # 要約のMarkdown書式は状態の意味を変えない。書式別の判定追加は採らない。
            summary_text = _current_summary_goal_text(
                _normalize_goal_field_format(_summary_goal_fields(combined_transcript_text([entry]))))
            # 他作業のstatusを現在Goalの状態へ流用しない。
            goal_matches = list(SUMMARY_GOAL_RE.finditer(summary_text))
            goal_text = _without_goal_annotations(goal_matches[-1].group(1)) if goal_matches else None
            goal_parts = re.split(r"[。;\n]|\.(?=\s|$)", goal_text) if goal_text is not None else []
            goal_state = None
            for part_index, part in enumerate(goal_parts):
                # 単語1個の短いGoal名に続く欄、または独立した状態欄だけを採る。
                # 空白を含む説明中のstatusは対象を確定できないため採らない。
                # 過去Goalの見出しと他作業の状態を現在へ流用しない。
                prefix = r"^\s*(?:[^\s:：]+\s+)?" if part_index == 0 else r"^\s*"
                # 状態値は独立した語。後ろの括弧は現在Goalの補足だけで、
                # 括弧内の別状態や疑問形を状態の証拠として採らない。
                pattern = r"(?i)" + prefix + r"(?:状態|status)[:：]\s*(\w+)((?:\s*(?:\([^()]*\)|（[^（）]*）))*)\s*$"
                goal_state = re.search(pattern, part)
                if goal_state:
                    # 完了値の注記は意味を推測しない。注記なしの完了欄/native成功だけを確定根拠にする。
                    # 不確実性の同義語を増やす案は終わりがないため採らない。
                    if ("?" in goal_state.group(2) or
                            (goal_state.group(1).lower() in {"complete", "completed"} and goal_state.group(2).strip())):
                        goal_state = None
                    break
            if goal_state and goal_state.group(1).lower() in {"paused", "blocked", "complete", "completed", "停止中", "保留中"}:
                active, stopped = False, True
            if not active and not stopped and is_goal_active(summary_text):
                active = True
                start = index
            continue
        role = entry.get("type", entry.get("role"))
        message = entry.get("message", entry)
        content = message.get("content", "") if isinstance(message, dict) else ""
        blocks = content if isinstance(content, list) else [content]
        # [2026-10-04][fix] 同じ成功停止結果を直下・入れ子の両native形式で読む。
        # 片方だけ拾う案は、成功したGoal停止を無視するため採らない。
        for block in ([entry] if role in {"tool_use", "tool_result"} else blocks):
            text = block if isinstance(block, str) else block.get("text", "") if isinstance(block, dict) and block.get("type") == "text" else ""
            if role == "assistant" and re.match(r"(?i)^\s*Goal[:：]", text) and not stopped:
                if not active:
                    start = index
                active = True
            user_start = role == "user" and bool(re.match(r"(?i)^\s*(?:/goal\b|Goal[:：])", text)
                                                or re.fullmatch(r"(?:このプランを)?全部[✓✔](?:にして(?:ください)?)?[。!！ \t]*", text.strip())
                                                or re.match(r"^(?:このプランを)?全部[✓✔]にして(?:ください)?(?=$|[。!！\s])", text.strip()))
            if isinstance(block, dict) and block.get("type") == "tool_result":
                update = goal_updates.get(str(block.get("tool_use_id", "")))
                if update and update[1] >= start and block.get("is_error") is not True:
                    stopped = update[0] in {"paused", "complete", "completed", "blocked"}
                    active = not stopped
            name = str(block.get("name", "")) if isinstance(block, dict) else ""
            normalized_name = name.rsplit("__", 1)[-1].rsplit(".", 1)[-1].replace("_", "").lower()
            if isinstance(block, dict) and block.get("type") == "tool_use" and normalized_name == "updategoal":
                arguments = block.get("input", {})
                if isinstance(arguments, dict) and "status" in arguments:
                    goal_updates[str(block.get("id", ""))] = (str(arguments["status"]).lower(), index)
            tool_start = role in {"assistant", "tool_use"} and isinstance(block, dict) and block.get("type") == "tool_use" and name.rsplit("__", 1)[-1].rsplit(".", 1)[-1].replace("_", "").lower() == "creategoal"
            if tool_start and str(block.get("id", "")) in failed_calls:
                tool_start = False
            if user_start or tool_start:
                stopped = False
                active = True
                start = index
    previous_ids: set[str] = set()
    if start:
        _extract_task_state(stream[:start], seen_ids=previous_ids)
    return active, stream[start:], previous_ids


def has_plan_ledger_evidence(text: str) -> bool:
    return any(
        PLAN_LEDGER_EVIDENCE_RE.search(line) and not NEGATIVE_EVIDENCE_RE.search(line)
        for line in re.split(r"[。\n]", text)
    )


def is_explicit_hold(text: str) -> bool:
    """Only an explicit §6 label authorizes a hold; prose is not task state."""
    marker = HOLD_RE.search(text or "")
    return bool(marker and marker.group("owner").strip("\"'"))


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


def _task_text(item: dict) -> list[str]:
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
    return parts


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


def _text_task_list(content: Any) -> Any | None:
    # [2026-10-04][fix] TaskListが行形式になる配布先ではJSON限定で最新状態を読めない。
    # Native TaskListはJSONまたは行形式。全行を一つの一覧として確認し、
    # 認識できた行だけで全件一覧を置換する案（未完了を消す）は採らない。
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = [item if isinstance(item, str) else item.get("text", "")
                 for item in content if isinstance(item, str) or (
                     isinstance(item, dict) and item.get("type") == "text")]
        text = "\n".join(parts)
    else:
        return None
    parsed = _parse_json_blob(text)
    if parsed is not None:
        return parsed
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return None
    tasks = []
    for line in lines:
        match = re.fullmatch(r"[ \t]*#([^\s]+)[ \t]+\[([^\]]+)\][ \t]+(.+)", line)
        if match is None:
            return None
        tasks.append({"id": match[1], "status": match[2].strip().lower(), "subject": match[3]})
    return {"tasks": tasks}


def _walk_objects(obj: Any) -> Iterable[dict]:
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from _walk_objects(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _walk_objects(value)


def _extract_task_state(entries: list[Any], previous_ids: set[str] | None = None,
                        seen_ids: set[str] | None = None) -> tuple[list[dict], bool]:
    """Latest full task-tool snapshot; individual updates preserve other tasks."""
    # [2026-10-04][fix] 過去 pending と最新 completed の併合は停止を妨げる。
    # TaskList/TodoWrite の全件結果だけ置換し、部分結果で未完了を消さない。
    tasks: list[dict] = []
    todos: list[dict] = []
    calls: dict[str, tuple[str, Any, int]] = {}
    last_call_id = ""
    sequence = 0
    task_field_updates: dict[str, dict[str, tuple[Any, int, str, bool]]] = {}
    snapshot_revision = -1
    snapshot_ids: set[str] = set()
    resolved_calls: set[str] = set()
    snapshot_inflight: dict[str, set[str]] = {}
    snapshot_pending_calls: set[str] = set()
    todo_revision = -1
    listing_confirmed = False
    empty_completion_confirmed = False
    task_evidence = False
    previous_ids = previous_ids or set()
    current_ids: set[str] = set()
    created_ids: set[str] = set()
    unresolved_known_ids: dict[str, set[str]] = {}
    create_known_ids: dict[str, set[str]] = {}
    seen_ids = set() if seen_ids is None else seen_ids
    current_activity = False

    def update_task(item: dict, revision: int, call_id: str, initial: bool = False) -> None:
        task_id = str(item.get("id", ""))
        if task_id:
            seen_ids.add(task_id)
        if not task_id or (initial and task_id in snapshot_ids):
            return
        changed = task_field_updates.setdefault(task_id, {})
        # [2026-10-04][fix] 同じ欄の並行更新は開始順だけで確定しない。
        # 逆順応答の古いpendingを捨ててcompletedとする案は採らない。
        # 矛盾する成功更新は、全呼出し後の一覧で確認するまで未確認とする。
        conflicts = [changed[key][1] for key, value in item.items()
                     if not initial and key in changed and revision < changed[key][1]
                     and value != changed[key][0]]
        if conflicts:
            changed["_unconfirmed"] = (True, max(conflicts), call_id, False)
            for old in tasks:
                if str(old.get("id", "")) == task_id:
                    old["_unconfirmed"] = True
        accepted = {key: value for key, value in item.items() if key != "id"
                    and revision >= changed.get(key, (None, -1, "", False))[1]
                    and (revision >= snapshot_revision or call_id in snapshot_pending_calls)}
        if not accepted:
            return
        for key, value in accepted.items():
            changed[key] = (value, revision, call_id, initial)
        for index, old in enumerate(tasks):
            if str(old.get("id", "")) == task_id:
                tasks[index] = {**old, **accepted, "id": task_id}
                return
        tasks.append({**accepted, "id": task_id})

    for entry in entries:
        for node in _walk_objects(entry):
            if node.get("type") == "tool_use":
                sequence += 1
                last_call_id = str(node.get("id", ""))
                # [2026-10-04][fix] 作成前のIDは呼出時に保存する。
                # 並行一覧が先に返ると結果受信時には新IDも既知になるため、
                # 結果時点の集合を使って新しい作成を除外する案は採らない。
                if str(node.get("name", "")).lower() == "taskcreate":
                    create_known_ids[last_call_id] = set(seen_ids)
                if str(node.get("name", "")).lower() == "tasklist":
                    snapshot_inflight[last_call_id] = {cid for cid, (name, _, _) in calls.items()
                                                       if cid not in resolved_calls and name in {"taskcreate", "taskupdate"}}
                calls[last_call_id] = (str(node.get("name", "")).lower(), node.get("input", {}), sequence)
            elif node.get("type") == "tool_result":
                call_id = str(node.get("tool_use_id", last_call_id))
                call = calls.get(call_id)
                resolved_calls.add(call_id)
                if call is None or node.get("is_error") is True:
                    continue
                tool_name, pending_input, revision = call
                before_tasks = [item for item in tasks + todos
                                if not item.get("id") or str(item["id"]) not in previous_ids
                                or str(item["id"]) in current_ids]
                complete_before = (task_list_is_complete(before_tasks)
                                   or (not before_tasks and empty_completion_confirmed)) and (not previous_ids or current_activity)
                strings = list(walk_strings(node.get("content", "")))
                parsed_results = [_text_task_list(node.get("content", ""))] if tool_name == "tasklist" else [_parse_json_blob(raw) for raw in strings]
                if tool_name == "taskcreate" and isinstance(pending_input, dict):
                    task_evidence = True
                    current_activity = True
                    created_id = ""
                    for raw, parsed in zip(strings, parsed_results):
                        item = parsed.get("task", parsed) if isinstance(parsed, dict) else None
                        if isinstance(item, dict) and item.get("id"):
                            created_id = str(item["id"])
                            break
                        match = re.search(r"(?i)\btask\s+#([^\s:]+)\s+created\b", raw)
                        if match:
                            created_id = match.group(1)
                            break
                    if created_id:
                        created_ids.add(created_id)
                    else:
                        unresolved_known_ids["unresolved-create:" + call_id] = create_known_ids.get(call_id, set())
                    current_ids.add(created_id or "unresolved-create:" + call_id)
                    update_task({**pending_input, "id": created_id or "unresolved-create:" + call_id, "status": "pending"}, revision, call_id, initial=True)
                # Successful updates apply only their explicit input fields.
                # A full JSON reply may carry unrelated, older status values.
                elif tool_name == "taskupdate" and isinstance(pending_input, dict):
                    task_id = str(pending_input.get("taskId", pending_input.get("id", "")))
                    if task_id and ("status" in pending_input or any(
                            is_explicit_hold(text) for text in _task_text(pending_input))):
                        current_ids.add(task_id)
                        task_evidence = True
                        current_activity = True
                    update_task({**pending_input, "id": task_id}, revision, call_id)
                elif tool_name == "todowrite" and revision < todo_revision:
                    if _tasks_from_payload(pending_input) != todos:
                        todos = [{**item, "_unconfirmed": True} for item in todos] or [{"_unconfirmed": True}]
                        empty_completion_confirmed = False
                elif tool_name == "todowrite" and revision >= todo_revision:
                    incoming_todos = _tasks_from_payload(pending_input)
                    if incoming_todos or complete_before:
                        todos = incoming_todos
                    seen_ids.update(str(item.get("id", "")) for item in todos)
                    empty_completion_confirmed = not todos and complete_before
                    current_ids.update(str(item["id"]) for item in todos if item.get("id"))
                    task_evidence = task_evidence or bool(todos)
                    current_activity = current_activity or bool(todos)
                    listing_confirmed = True
                    todo_revision = revision
                for parsed in parsed_results:
                    if tool_name in {"tasklist", "todowrite"} and (
                        isinstance(parsed, list) or (isinstance(parsed, dict) and any(
                            isinstance(parsed.get(key), list) for key in ("tasks", "items", "todos")
                        ))
                    ):
                        snapshot = _tasks_from_payload(parsed)
                        seen_ids.update(str(item.get("id", "")) for item in snapshot)
                        if tool_name == "todowrite":
                            current_activity = current_activity or bool(snapshot)
                            current_ids.update(str(item["id"]) for item in snapshot if item.get("id"))
                        task_evidence = task_evidence or any(
                            str(item.get("id", "")) not in previous_ids
                            or str(item.get("id", "")) in current_ids for item in snapshot)
                        listing_confirmed = True
                        if tool_name == "todowrite":
                            if revision >= todo_revision:
                                empty_completion_confirmed = not snapshot and complete_before
                                if snapshot or complete_before:
                                    todos = snapshot
                                todo_revision = revision
                        elif revision >= snapshot_revision:
                            empty_completion_confirmed = not snapshot and complete_before
                            # [2026-10-04][fix] 一覧取得中の作成・更新結果を落とすと
                            # 未完了を見逃す。前から実行中の呼出しも追跡する。
                            # 全項目を保持する案は、件名変更だけで古い completed を
                            # 復活させるため採らない。実際に変更したフィールドだけ重ねる。
                            # 作成時の初期値は一覧にないIDの補完だけに使い、確認済み状態を戻さない。
                            # [2026-10-04][fix] IDなし一覧は同一タスクと証明できない。
                            # 空キーで上書きする案は pending を消すため採らない。
                            anonymous = [dict(item) for item in snapshot if not item.get("id")]
                            indexed = {str(item["id"]): dict(item) for item in snapshot if item.get("id")}
                            # [2026-10-04][fix] 行形式一覧は説明/noteを省く。
                            # 同じIDの確認済み欄だけ保持し、明示の空欄や状態は一覧を優先する。
                            for old in tasks:
                                old_id = str(old.get("id", ""))
                                if old_id in indexed:
                                    for field in ("description", "note"):
                                        if field in old and field not in indexed[old_id]:
                                            indexed[old_id][field] = old[field]
                            # [2026-10-04][fix] 作成成功にIDがない時は仮IDで保留する。
                            # 完全一覧に、旧Goalと異なるID・同じ件名が双方一意にある時だけ対応を確定。
                            # 件名だけで旧完了を流用する案や、曖昧な複数候補を選ぶ案は採らない。
                            # [2026-10-04][fix] 別の作成結果や作成前に既知のIDは対応候補にしない。
                            # 同件名の完了済みAで、ID不明の未完了Bを消す案は採らない。
                            unresolved = [old for old in tasks if str(old.get("id", "")).startswith("unresolved-create:")]
                            for old in unresolved:
                                subject = old.get("subject")
                                candidates = [tid for tid, item in indexed.items()
                                              if tid not in previous_ids and tid not in created_ids
                                              and tid not in unresolved_known_ids.get(str(old.get("id")), set())
                                              and subject and item.get("subject") == subject]
                                peers = [item for item in unresolved if item.get("subject") == subject]
                                if len(candidates) == 1 and len(peers) == 1 and candidates[0] in current_ids:
                                    tasks = [item for item in tasks if item is not old]
                                    current_ids.add(candidates[0])
                            # [2026-10-04][fix] 圧縮後の一覧で確認した未完了も空一覧では消さない。
                            # 新GoalでIDの対応がない一覧を受けても、今回の未完了を消さない。
                            if previous_ids or not snapshot:
                                for old in tasks:
                                    old_id = str(old.get("id", ""))
                                    if ((old_id in current_ids or old_id not in previous_ids)
                                            and old_id not in indexed
                                            and not task_list_is_complete([old])):
                                        indexed[old_id] = dict(old)
                            inflight = snapshot_inflight.get(call_id, set())
                            for task_id, fields in task_field_updates.items():
                                overlay = {key: value for key, (value, updated_at, cid, initial) in fields.items()
                                           if (updated_at > revision or cid in inflight)
                                           and not (initial and task_id in indexed)}
                                if overlay:
                                    indexed[task_id] = {**indexed.get(task_id, {}), **overlay, "id": task_id}
                            tasks = list(indexed.values()) + anonymous
                            snapshot_ids = {str(item.get("id", "")) for item in snapshot}
                            snapshot_revision = revision
                            snapshot_pending_calls = snapshot_inflight.get(call_id, set())
                    elif tool_name == "taskcreate" and isinstance(parsed, dict):
                        item = parsed.get("task", parsed)
                        if isinstance(item, dict):
                            update_task(item, revision, call_id, initial=True)
    # [2026-10-04][fix] 新Goalで一覧を再取得しても旧Goalの項目は新規起票ではない。
    # 全件一覧だけで旧完了を引き継ぐ案は採らない。今回成功した作成・更新は保持する。
    current_tasks = [item for item in tasks + todos
                     if not item.get("id") or str(item["id"]) not in previous_ids
                     or str(item["id"]) in current_ids]
    # 旧一覧がある新Goalは、一覧の再取得だけでは今回の作業を証明しない。
    # IDのない項目も消さず、現在Goalの成功した操作で確認するまで未確認にする。
    if previous_ids and not current_activity:
        current_tasks = [{**item, "_unconfirmed": True} for item in current_tasks]
    return current_tasks, (listing_confirmed and task_evidence
                           and (not previous_ids or current_activity)
                           and (bool(current_tasks) or empty_completion_confirmed))


def extract_tasks(entries: list[Any]) -> list[dict]:
    _, scoped, previous_ids = _goal_scope(entries)
    return _extract_task_state(scoped, previous_ids)[0]


def task_list_is_complete(tasks: list[dict]) -> bool:
    """True when every task is done or a §6 explicit hold."""
    if not tasks:
        return False
    for item in tasks:
        if item.get("_unconfirmed") is True:
            return False
        status = _task_status(item)
        if status in COMPLETED_STATUSES:
            continue
        if any(is_explicit_hold(text) for text in _task_text(item)):
            continue
        # Unknown/failed statuses are not successful completion either.
        return False
    return True


def should_block(entries: list[Any]) -> bool:
    active, scoped, previous_ids = _goal_scope(entries)
    if not active:
        return False
    tasks, confirmed_listing = _extract_task_state(scoped, previous_ids)
    if tasks:
        return not task_list_is_complete(tasks)
    # 空一覧は、現在Goalの起票と、その直前の完了を確認した時だけ終了根拠になる。
    if confirmed_listing:
        return False
    evidence_entries = [entry for entry in scoped if _is_compaction_entry(entry)]
    evidence_text = _normalize_goal_field_format(_summary_goal_fields(
        combined_transcript_text(evidence_entries), allow_quoted_state=False))
    return not has_plan_ledger_evidence(_current_summary_goal_text(evidence_text))


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
