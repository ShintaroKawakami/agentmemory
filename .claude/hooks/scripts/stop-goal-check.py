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

[2026-10-15][fix] Issue #3595: タスク道具の無い環境の逃げ道と同一保留の再発火抑制。
背景:
  - jtt-cms で /compact 後に TaskList/TodoWrite/TaskCreate が道具一覧に無い環境では、
    台帳証拠を圧縮要約エントリからしか読まず、「台帳全行照合 + [明示保留] owner=…」を
    返答本文に書いても作業完了後に止め続けた（2026-10-15 実測）。
  - owner=AI（サブエージェント等の完了待ち）でも毎ターン同文面で発火した
    （2026-10-13 実測・十数回）。
守るべき業務ルール:
  - 検査の一律緩和はしない。assistant 本文を証拠に数えるのは
    「同一メッセージ内の2つの形式マーカー」（台帳照合またはタスク化証拠の語
    ＋ 行頭の owner 付き明示保留札）で、かつその領域にタスク道具の呼出しが
    無い時だけ。道具を使った領域は道具の状態が正本（#3604 を維持）。
  - 明示保留を含む阻止状態が直前と同一なら再発火しない。
    札の無い未完了は従来どおり毎回止める（黙らせない）。
他案不採用理由:
  1) 保留札だけ・台帳言及だけで通す案は、単なる宣言で止まらなくなるため不採用。
  2) 道具一覧からタスク道具の有無を読む案は transcript に道具一覧が残らないため不採用。
  3) 全阻止状態を重複抑制する案は、札を書かない未完了作業も黙らせるため不採用。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
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
            user_clear = role == "user" and _is_goal_clear(text)
            user_start = role == "user" and not user_clear and bool(re.match(r"(?i)^\s*(?:/goal\b|Goal[:：])", text)
                                                or re.fullmatch(r"(?:このプランを)?全部[✓✔](?:にして(?:ください)?)?[。!！ \t]*", text.strip())
                                                or re.match(r"^(?:このプランを)?全部[✓✔]にして(?:ください)?(?=$|[。!！\s])", text.strip())
                                                or _wrapped_goal_args(text) is not None)
            if user_clear:
                # [2026-10-17][fix] Issue #4156: /goal clear 以降は Goal なし。clear 前の /goal を拾い続けない。
                active, stopped = False, True
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


# Issue #3595: 台帳の「照合」（全行確認）もタスク化宣言と同じ証拠の語として扱う。
# 「照合する予定」等は NEGATIVE_EVIDENCE_RE で外す（_has_ledger_reference 側）。
LEDGER_CHECK_RE = re.compile(
    r"(?:台帳|ledger)[^\n。]{0,80}"
    r"(?:全行照合|全件照合|照合済み|照合した|照合しました|すべて.{0,4}確認(?:済み|した|しました)|全て.{0,4}確認(?:済み|した|しました))",
    re.IGNORECASE,
)
_TASK_TOOL_NAMES_ALL = TASK_TOOL_NAMES | {"taskupdate"}


def _has_ledger_reference(text: str) -> bool:
    for line in re.split(r"[。\n]", text):
        if NEGATIVE_EVIDENCE_RE.search(line):
            continue
        if PLAN_LEDGER_EVIDENCE_RE.search(line) or LEDGER_CHECK_RE.search(line):
            return True
    return False


def _prose_wait_evidence(scoped: list[Any]) -> tuple[list[str], bool]:
    """圧縮後（圧縮が無ければ scoped 全体）の assistant 本文にある明示保留の行と、
    同一メッセージに台帳照合・タスク化証拠を伴う札があるかを返す。
    領域内にタスク道具の呼出しが1つでもあれば証拠としては採らない
    （道具の状態が正本・Issue #3595）。"""
    last_compact = -1
    for index, entry in enumerate(scoped):
        if _is_compaction_entry(entry):
            last_compact = index
    region = scoped[last_compact + 1:]
    holds: list[str] = []
    paired = False
    tool_used = False
    for entry in region:
        if not isinstance(entry, dict):
            continue
        for node in _walk_objects(entry):
            if node.get("type") != "tool_use":
                continue
            name = str(node.get("name", ""))
            normalized = name.rsplit("__", 1)[-1].rsplit(".", 1)[-1].replace("_", "").lower()
            if normalized in _TASK_TOOL_NAMES_ALL:
                tool_used = True
        if entry.get("type") != "assistant":
            continue
        text = _entry_text(entry)
        if not text:
            continue
        clean = _normalize_goal_field_format(_summary_goal_fields(text, allow_quoted_state=False))
        entry_holds = [line.strip() for line in clean.splitlines() if is_explicit_hold(line)]
        holds.extend(entry_holds)
        if entry_holds and _has_ledger_reference(clean):
            paired = True
    return holds, paired and not tool_used


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


# [2026-10-13][fix] 背景: 伸太郎さん「agent-hub側もなおすこと。それがいい」(2026-10-13)。
#   タスク道具が無い環境では台帳の正本は HTML の ☐/☑（plan-approval）。mixpost 警告修正で
#   台帳 50 行が全 ☑ になった後も、要約に完了が無いため Stop hook が止まらなかった。
#   守るべき業務ルール: #3602〜#3604 の「旧 Goal の証拠を流用しない」「AI の文章を状態にしない」を保つ。
#   読めない・曖昧な時は止める（fail-close）。
#   他案不採用理由: 要約後の AI 発言を証拠にする案は #3604 の穴を開け直すため不採用。
#   ファイル名での照合は別 Goal の台帳を拾うため不採用。data-goal は /goal 行の元データなので完全一致で使う。
#   更新時刻で旧 ☑ の流用を防ぐ案は、再組み立てで時刻が新しくなるため不採用。
# 対応: 既存の3つの判定の後に、data-goal 完全一致の台帳を1組だけ読む。「今回の Goal 中に ☐ が残る台帳を
#   見た」記録（会話ID＋Goal開始 uuid＋プランの組）を残し、その記録がある時だけ全 ☑ を終了の根拠にする。
#   相方（X.src.html と X.html）はファイル名でそろえ、存在する全ファイルの data-goal 一致を要求する。
#   既知の制約: 途中の Stop が一度も無く、初回判定で全 ☑ だと記録が無く止まる（安全側。今と同じ挙動）。
#   Goal 開始時に記録する仕組み（UserPromptSubmit 等）は別 Issue。
LEDGER_PLANS_ENV = "AGENT_HUB_STOP_GOAL_PLANS_DIR"
LEDGER_STATE_ENV = "AGENT_HUB_STOP_GOAL_LEDGER_DIR"
LEDGER_MARKS = ("☐", "☑")
# [2026-10-14][fix] 台帳の最後の列が §6 の明示保留（owner 付き）なら "hold" と分類する。
#   背景: 伸太郎さん「hookも直しましょう」2026-10-14。☑ と [明示保留] だけで作業が全部終わっていても、
#   先頭1文字照合が保留を不明な印として fail-close し、/goal 中に Stop が毎回止めた。
#   他案不採用理由: HOLD_RE をそのまま使う案は owner が札の直後でないと外れる（実台帳は「理由 owner=本人」の形）ので不採用。
#   owner が無い・空の保留は従来どおり不明な印（fail-close）のまま。
#   [2026-10-14] codex レビュー指摘で境界を厳格化: owner の直前が英数字・_・- なら不一致（previous_owner= / backup-owner= を除外）。
LEDGER_HOLD = "hold"
_LEDGER_HOLD_RE = re.compile(
    r"^[ \t]*(?:\[明示保留\]|【明示保留】|明示保留[:：])"
    r".*?(?<![A-Za-z0-9_\-])owner[ \t]*[=：:][ \t]*(?P<owner>[^\s/]+)",
    re.DOTALL,
)
_MAX_PLAN_BYTES = 8 * 1024 * 1024
_GOAL_QUOTES = {'"': '"', "'": "'", "“": "”", "‘": "’", "「": "」", "『": "』"}


def _default_plans_dir() -> Path:
    return Path(os.environ.get(LEDGER_PLANS_ENV) or Path.home() / ".claude" / "plans")


def _default_state_dir() -> Path:
    return Path(os.environ.get(LEDGER_STATE_ENV) or Path.home() / ".cache" / "agent-hub" / "stop-goal-ledger")


class GoalRun:
    """現在 Goal の原文（/goal 接頭辞と外側の引用符だけ外す）・会話ID・Goal 開始エントリの uuid。"""

    def __init__(self, text: str, conversation_id: str, start_uuid: str) -> None:
        self.text = text
        self.conversation_id = conversation_id
        self.start_uuid = start_uuid  # 圧縮後も前のエントリが残るので元の /goal の uuid が取れる

    def marker_name(self, group: tuple[Path, ...]) -> str:
        names = "|".join(sorted(path.name for path in group))
        digest = hashlib.sha256(
            "\0".join((self.conversation_id, self.start_uuid, names)).encode("utf-8")).hexdigest()
        return digest[:40] + ".seen"


def _entry_text(entry: dict) -> str:
    message = entry.get("message", entry)
    content = message.get("content", "") if isinstance(message, dict) else ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                return block
            if isinstance(block, dict) and block.get("type") == "text":
                return str(block.get("text", ""))
    return ""


# [2026-10-13][fix] 実 transcript の /goal は素の「/goal 文面」ではなく、打ち込み
#   （<command-name>/goal</command-name> … <command-args>）と承認返事の貼り付け
#   （先頭が <pasted_content> で、その最初の空でない行が /goal）の2形式で残る
#   （2026-10-13 実測）。このままでは Goal 開始も台帳経路も働かない。
#   引用・コード例・本文途中の /goal を拾うと #3602〜#3604 の境界が崩れるため、
#   メッセージ先頭がその2形式の時だけ認める。/goal clear・引数なしは開始ではない。
#   Goal 原文は最初の1行（後ろの「# Re: …」本文は data-goal に入らない）。
_GOAL_COMMAND_RE = re.compile(
    r"(?s)\A\s*<command-name>/goal</command-name>.*?<command-args>(.*?)</command-args>")
_GOAL_PASTE_RE = re.compile(r"(?s)\A\s*<pasted_content\b[^>]*>\s*/goal[ \t]+([^\n]*)")


def _wrapped_goal_args(text: str) -> str | None:
    """打ち込み形式・貼り付け形式の /goal から原文の最初の1行を返す。開始でなければ None。"""
    match = _GOAL_COMMAND_RE.match(text) or _GOAL_PASTE_RE.match(text)
    if not match:
        return None
    first = next((line.strip() for line in match.group(1).splitlines() if line.strip()), "")
    return None if first.lower() == "clear" or not first else first


def _is_goal_clear(text: str) -> bool:
    """user の `/goal clear`（打ち込み形式・素の文面）。引数なしや別の引数は clear ではない。"""
    match = _GOAL_COMMAND_RE.match(text)
    if match:
        first = next((line.strip() for line in match.group(1).splitlines() if line.strip()), "")
        return first.lower() == "clear"
    return bool(re.fullmatch(r"\s*/goal[ \t]+clear[ \t]*", text, re.IGNORECASE))


# [2026-10-17][fix] Issue #4156: タスク道具が無い環境の台帳は Markdown の表（状態列が ☐/☑/[明示保留] owner=）。
#   背景: 伸太郎さん決定 2026-10-17（振り返り 2A）「台帳ファイルも完了・保留の証拠に読む」。
#   台帳が全部 ☑ か保留でも Stop が10回以上止め続けた（jtt-system 実測）。
#   守るべき業務ルール: 台帳の場所を推測で広げない。今回の Goal 中に assistant が Write/Edit した、
#   または返答本文に絶対パスで書いた「ledger/台帳」を含む .md だけを読む。
#   存在する候補はすべて読めて全行 ☑/保留の時だけ通す。読めない・状態列が無い・不明な印・☐ 残りは従来どおり止める。
#   他案不採用理由: ~/Downloads/AI-Work 等を走査する案は別 Goal の台帳を拾うため不採用。
#   返答本文の宣言だけで通す案は #3604 の穴を開け直すため不採用（ファイルの状態を読む）。
_LEDGER_WRITE_TOOLS = frozenset({"write", "edit", "multiedit"})
_MD_LEDGER_PATH_RE = re.compile(r"(?:~|(?<![\w.~]))/[^\s`\"'|()（）<>\[\]、。,;]*")
_MAX_MD_LEDGER_BYTES = 1024 * 1024


def _is_md_ledger_name(path: str) -> bool:
    name = os.path.basename(path).lower()
    return name.endswith(".md") and ("ledger" in name or "台帳" in name)


def _md_ledger_candidates(scoped: list[Any]) -> list[Path]:
    found: dict[str, None] = {}
    for entry in scoped:
        if not isinstance(entry, dict) or entry.get("type") != "assistant":
            continue
        message = entry.get("message", entry)
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                name = str(block.get("name", "")).rsplit("__", 1)[-1].rsplit(".", 1)[-1].lower()
                args = block.get("input")
                path = args.get("file_path") if isinstance(args, dict) else None
                if name in _LEDGER_WRITE_TOOLS and isinstance(path, str) and os.path.isabs(path) \
                        and _is_md_ledger_name(path):
                    found[path] = None
            elif block.get("type") == "text":
                for raw in _MD_LEDGER_PATH_RE.findall(str(block.get("text", ""))):
                    path = os.path.expanduser(raw.rstrip(".:"))
                    if os.path.isabs(path) and _is_md_ledger_name(path):
                        found[path] = None
    return [Path(path) for path in found]


def _md_ledger_marks(path: Path) -> list[str] | None:
    """Markdown 台帳の「状態」列の分類済みの印。状態列のある表が無い・崩れている時は None。"""
    try:
        if path.stat().st_size > _MAX_MD_LEDGER_BYTES:
            return None
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return None
    marks: list[str] = []
    fence = ""
    index = 0

    def cells(line: str) -> list[str]:
        body = line.strip()
        body = body[1:] if body.startswith("|") else body
        body = body[:-1] if body.endswith("|") else body
        return [cell.strip() for cell in body.split("|")]

    while index < len(lines):
        line = lines[index]
        index += 1
        fence_match = re.match(r"^[ \t]*(`{3,}|~{3,})", line)
        if fence_match:
            token = fence_match.group(1)
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = ""
            continue
        if fence or not line.lstrip().startswith("|"):
            continue
        if index >= len(lines) or "|" not in lines[index] \
                or not re.fullmatch(r"[ \t]*\|?[ \t:|-]*-[ \t:|-]*", lines[index]):
            continue                                   # 区切り行の無い行は表の見出しではない
        header = cells(line)
        index += 1                                     # 区切り行を飛ばす
        column = next((i for i, cell in enumerate(header)
                       if "状態" in cell or cell.lower() == "status"), None)
        rows: list[list[str]] = []
        while index < len(lines) and lines[index].lstrip().startswith("|"):
            rows.append(cells(lines[index]))
            index += 1
        if column is None:
            continue                                   # 状態列の無い表（記録など）は台帳として読まない
        if not rows or any(len(row) != len(header) for row in rows):
            return None                                # 空の台帳・列ずれは読取失敗
        marks.extend(_classify_ledger_cell(row[column]) for row in rows)
    return marks or None


def _md_ledger_state(scoped: list[Any]) -> str:
    """"complete"（候補がすべて全行 ☑/保留）/ "open"（読めた台帳に未完了・不明な印）/ "none"（証拠なし・読めない）。"""
    states: list[str] = []
    for path in _md_ledger_candidates(scoped):
        try:
            if not path.is_file():
                continue                               # 存在しない候補（例示パス等）は無視
        except OSError:
            continue
        marks = _md_ledger_marks(path)
        if marks is None:
            states.append("unreadable")
        elif all(mark in ("☑", LEDGER_HOLD) for mark in marks):
            states.append("complete")
        else:
            states.append("open")
    if "open" in states or "unreadable" in states:
        return "open"                                  # 読めない台帳は未完了と同じ扱い（本文の宣言で通さない）
    if states and all(state == "complete" for state in states):
        return "complete"
    return "none"


def _goal_run(start_entry: Any, conversation_id: str) -> GoalRun | None:
    """Goal 開始エントリ（user の /goal）から原文を取る。特定できなければ None。"""
    if not conversation_id or not isinstance(start_entry, dict) or start_entry.get("type") != "user":
        return None
    uuid = start_entry.get("uuid")
    if not isinstance(uuid, str) or not uuid:
        return None
    entry_text = _entry_text(start_entry)
    text = _wrapped_goal_args(entry_text)
    if text is None:
        match = re.match(r"(?is)^\s*/goal\b(.*)$", entry_text)
        if not match:
            return None
        text = next((line.strip() for line in match.group(1).splitlines() if line.strip()), "")
    if len(text) >= 2 and _GOAL_QUOTES.get(text[0]) == text[-1]:
        text = text[1:-1].strip()
    return GoalRun(text, conversation_id, uuid) if text else None


class _StopParsing(Exception):
    pass


class _BodyGoalParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.goal: str | None = None

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag == "body":
            for key, value in attrs:
                if key == "data-goal":
                    self.goal = value or ""
            raise _StopParsing


def _read_plan(path: Path) -> str:
    if path.stat().st_size > _MAX_PLAN_BYTES:
        raise ValueError("plan too large")
    return path.read_text(encoding="utf-8")


def _plan_goal(path: Path) -> str | None:
    """body の data-goal（属性は unescape 済み）。読めない・無い時は None。"""
    try:
        parser = _BodyGoalParser()
        try:
            parser.feed(_read_plan(path))
            parser.close()
        except _StopParsing:
            pass
        return parser.goal.strip() if parser.goal is not None else None
    except (OSError, ValueError):
        return None


def _single_plan_group(plans_dir: Path, goal_text: str) -> tuple[Path, ...] | None:
    """Goal 原文と data-goal が完全一致する組（X.src.html と X.html）が1つだけの時のみ返す。"""
    try:
        names = sorted(name for name in os.listdir(plans_dir) if name.endswith(".html"))
    except OSError:
        return None
    groups: dict[str, list[Path]] = {}
    for name in names:
        key = name[: -len(".src.html")] if name.endswith(".src.html") else name[: -len(".html")]
        groups.setdefault(key, []).append(plans_dir / name)
    candidates: list[tuple[Path, ...]] = []
    for files in groups.values():
        goals = [_plan_goal(path) for path in files]
        if any(goal == goal_text for goal in goals):
            if not all(goal == goal_text for goal in goals):
                return None                      # 相方の不一致・読取失敗は不採用（曖昧なので止める）
            candidates.append(tuple(files))
    return candidates[0] if len(candidates) == 1 else None


class _LedgerParser(HTMLParser):
    """table[data-commitment-ledger] の項目行（thead と colspan 区分行を除く）の最後の列を集める。

    [2026-10-13][fix] 開始タグ欠け・閉じ忘れの入れ子・対応しない終了タグ・列ずれは、項目行の ☐ を
    読み飛ばして全項目完了に見せる（codex レビュー 1〜4 回目）。構造検査をまとめて fail-close にし、
    台帳表の中で崩れを1つでも見たら invalid（台帳経路不採用）にする。場当たりに1件ずつ塞ぐ案は
    採らない。build-plan 出力は全タグを閉じているため、正常なプランは通る。
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ledger_tables = 0
        self.invalid = False
        self.last_cells: list[str] = []
        self.widths: list[int] = []
        self._tables: list[bool] = []
        self._in_thead = False
        self._in_tbody = False
        self._row: list[str] | None = None
        self._row_section = False
        self._cell: list[str] | None = None

    @property
    def _in_ledger(self) -> bool:
        # 台帳表だけが開いている状態（入れ子の表の中では構造タグを読まない）。
        return self._tables == [True]

    @property
    def unclosed(self) -> bool:
        return bool(self._tables) or self._row is not None or self._cell is not None \
            or self._in_thead or self._in_tbody

    def _close_cell(self) -> None:
        if self._cell is not None and self._row is not None:
            self._row.append("".join(self._cell).strip())
        self._cell = None

    def _close_row(self) -> None:
        self._close_cell()
        row, section = self._row, self._row_section
        self._row, self._row_section = None, False
        if row is None or self._in_thead:
            return
        if not row:
            self.invalid = True                  # thead 外の項目領域にセルの無い tr
            return
        # 区分見出し行はセルが1つだけで colspan>1 の行に限る。複数セルの colspan は読取失敗。
        if section and len(row) > 1:
            self.invalid = True
        elif not section:
            self.last_cells.append(row[-1])
            self.widths.append(len(row))

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag == "table":
            ledger = any(key == "data-commitment-ledger" for key, _ in attrs)
            # [2026-10-13][fix] 拒否は「台帳表の内側に別の表」「台帳表自体が別の表の内側」の2つだけ。
            #   台帳の外で完結する補足表の入れ子は台帳判定に影響させない（codex レビュー 4 回目）。
            if any(self._tables) or (ledger and self._tables):
                self.invalid = True
            if ledger:
                self.ledger_tables += 1
            self._tables.append(ledger)
            return
        if not self._in_ledger:
            return
        if tag in ("thead", "tbody"):
            if self._in_thead or self._in_tbody or self._row is not None:
                self.invalid = True
            if tag == "thead":
                self._in_thead = True
            else:
                self._in_tbody = True
        elif tag == "tr":
            if self._row is not None:
                self.invalid = True              # tr の中で tr が開く（閉じ忘れ）
                self._close_row()
            self._row = []
        elif tag in ("td", "th"):
            if self._row is None or self._cell is not None:
                self.invalid = True              # 開いた tr が無い、または td の入れ子
                if self._row is None:
                    self._row = []
            self._close_cell()
            self._cell = []
            for key, value in attrs:
                if key == "colspan":
                    try:
                        self._row_section = self._row_section or int(value or "1") > 1
                    except ValueError:
                        self.invalid = True

    def handle_endtag(self, tag: str) -> None:
        if not self._tables:
            return
        if tag == "table":
            if self._in_ledger and (
                    self._row is not None or self._cell is not None or self._in_thead or self._in_tbody):
                self.invalid = True              # 閉じていない行・セル・thead/tbody
                self._close_row()
                self._in_thead = self._in_tbody = False
            self._tables.pop()
            return
        if not self._in_ledger:
            return
        if tag in ("thead", "tbody"):
            open_flag = self._in_thead if tag == "thead" else self._in_tbody
            if not open_flag or self._row is not None:
                self.invalid = True              # 対応しない終了タグ、または行が開いたまま
                self._close_row()
            if tag == "thead":
                self._in_thead = False
            else:
                self._in_tbody = False
        elif tag == "tr":
            if self._row is None or self._cell is not None:
                self.invalid = True
            self._close_row()
        elif tag in ("td", "th"):
            if self._cell is None:
                self.invalid = True
            self._close_cell()

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)
        elif self._in_ledger and data.strip():
            self.invalid = True                  # セルの外の文字は項目行として読めない


def _ledger_item_marks(path: Path) -> list[str] | None:
    """各項目行の最後の列の分類済みの印（☐ / ☑ / hold / 不明は先頭1文字）。表が1つでない・読めない時は None。"""
    try:
        parser = _LedgerParser()
        parser.feed(_read_plan(path))
        parser.close()
    except (OSError, ValueError):
        return None
    # [2026-10-13][fix] 途中で切れた HTML は close() でもエラーにならず、閉じていない最後の行が
    #   落ちて全項目完了に見える（codex レビュー）。表・行・セルが閉じていなければ読取失敗にする。
    if parser.ledger_tables != 1 or parser.invalid or parser.unclosed:
        return None
    if len(set(parser.widths)) > 1:
        return None                              # 項目行のセル数が揃わない（列ずれ）
    return [_classify_ledger_cell(cell) for cell in parser.last_cells]


def _classify_ledger_cell(cell: str) -> str:
    """最後の列を "☐" / "☑" / "hold"（owner 付き明示保留）/ それ以外は先頭1文字（空欄は ""）に分類する。"""
    if cell[:1] in LEDGER_MARKS:
        return cell[:1]
    if _LEDGER_HOLD_RE.search(cell):
        return LEDGER_HOLD
    return cell[:1]


def _touch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()


def _ledger_file_complete(goal: GoalRun | None, plans_dir: Path, state_dir: Path,
                          project_dir: Path | None = None) -> bool:
    if goal is None:
        return False                                   # 今の Goal を特定できなければ使わない
    group = _single_plan_group(plans_dir, goal.text)   # 名前で相方をそろえ、全ファイルの data-goal 一致・1組だけ
    # [2026-10-14][fix] worktree で作業すると台帳はその作業フォルダの claude-plans/（gitignore 済み）にあり、
    #   ~/.claude/plans だけでは見つからず Stop が止め続けた（伸太郎さん「hookも直しましょう」2026-10-14）。
    #   既定の場所で1組見つからない時だけ project_dir/claude-plans を試す（両方を合わせて曖昧にしない）。
    #   他案不採用理由: 両方を集めて1組判定する案は、同じ Goal が両方にあると曖昧で止まり続けるため不採用。
    if group is None and project_dir is not None:
        group = _single_plan_group(project_dir / "claude-plans", goal.text)
    if group is None:
        return False
    statuses = [_ledger_item_marks(path) for path in group]
    if any(not marks or any(mark not in LEDGER_MARKS and mark != LEDGER_HOLD for mark in marks)
           for marks in statuses):
        return False                                   # 空欄・不明な印（owner 無しの保留を含む）は記録も作らず止める
    marker = state_dir / goal.marker_name(group)
    try:
        if any("☐" in marks for marks in statuses):
            _touch(marker)                             # 既知の印だけで ☐ が残る時だけ「今回見た」と記録して止める
            return False
        # ☐ が無く ☑ と有効な保留だけ（全行が保留で ☑ が0の場合も同じ扱い）でも、
        # 今回 ☐ を見た記録がある時だけ通す（記録は自動で消さない）。記録が無ければ止める（安全側）。
        return marker.exists()
    except OSError:
        return False


def _block_fingerprint(phase: str, pending: list[str], holds: list[str]) -> str:
    """阻止状態の同一性を調べる指紋。pending/保留の内容が同じなら同じ値になる。"""
    payload = json.dumps(
        {"phase": phase, "pending": sorted(set(pending)), "holds": sorted(set(holds))},
        ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _blocked_marker_path(state_dir: Path, conversation_id: str) -> Path:
    digest = hashlib.sha256((conversation_id or "unknown").encode("utf-8")).hexdigest()
    return state_dir / f"blocked-{digest[:40]}.txt"


def _evaluate(entries: list[Any], *, conversation_id: str = "",
              plans_dir: Path | None = None, state_dir: Path | None = None,
              project_dir: Path | None = None) -> tuple[bool, str, bool]:
    """(阻止するか, 阻止状態の指紋, 明示保留を含むか) を返す。"""
    active, scoped, previous_ids = _goal_scope(entries)
    if not active:
        return False, "", False
    tasks, confirmed_listing = _extract_task_state(scoped, previous_ids)
    prose_holds, prose_paired = _prose_wait_evidence(scoped)
    task_holds = [
        text.strip()
        for item in tasks
        for text in _task_text(item)
        if is_explicit_hold(text)
    ]
    holds = prose_holds + task_holds
    has_hold = bool(holds)
    if tasks:
        if task_list_is_complete(tasks):
            return False, "", has_hold
        pending = sorted({
            "|".join((
                str(item.get("id", "")),
                _task_status(item),
                str(item.get("subject", item.get("content", "")))[:80],
            ))
            for item in tasks
            if _task_status(item) not in COMPLETED_STATUSES
            and not any(is_explicit_hold(text) for text in _task_text(item))
        })
        return True, _block_fingerprint("tasks", pending, holds), has_hold
    # 空一覧は、現在Goalの起票と、その直前の完了を確認した時だけ終了根拠になる。
    if confirmed_listing:
        return False, "", has_hold
    evidence_entries = [entry for entry in scoped if _is_compaction_entry(entry)]
    evidence_text = _normalize_goal_field_format(_summary_goal_fields(
        combined_transcript_text(evidence_entries), allow_quoted_state=False))
    if has_plan_ledger_evidence(_current_summary_goal_text(evidence_text)):
        return False, "", has_hold
    # 4つ目の終了根拠: HTML 台帳ファイル（既存3判定が止める時だけ確かめる）。
    # 環境変数 AGENT_HUB_STOP_GOAL_PLANS_DIR が設定されている時（テスト）は従来どおりそれだけを見る。
    if _ledger_file_complete(
            _goal_run(scoped[0] if scoped else None, conversation_id),
            plans_dir or _default_plans_dir(), state_dir or _default_state_dir(),
            None if os.environ.get(LEDGER_PLANS_ENV) else project_dir):
        return False, "", has_hold
    # 6つ目（Issue #4156）: 今回の Goal 中に書いた/示した Markdown 台帳ファイルの状態列を読む。
    #   全行 ☑/保留なら通す。読めた台帳に ☐ や不明な印が残るなら、本文の宣言（5つ目）より台帳を優先して止める。
    md_state = _md_ledger_state(scoped)
    if md_state == "complete":
        return False, "", has_hold
    # 5つ目の終了根拠: タスク道具を使っていない領域で、同一 assistant メッセージに
    # 「台帳照合・タスク化証拠 + owner 付き明示保留」がある時だけ通す（Issue #3595）。
    if prose_paired and md_state != "open":
        return False, "", True
    return True, _block_fingerprint("evidence", [], holds), has_hold


def should_block(entries: list[Any], *, conversation_id: str = "",
                 plans_dir: Path | None = None, state_dir: Path | None = None,
                 project_dir: Path | None = None) -> bool:
    return _evaluate(
        entries, conversation_id=conversation_id, plans_dir=plans_dir,
        state_dir=state_dir, project_dir=project_dir)[0]


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

    conversation_id = str(payload.get("session_id") or payload.get("sessionId") or transcript_path)
    # payload の cwd（無ければ CLAUDE_PROJECT_DIR）をプロジェクトの作業フォルダとして台帳探索に渡す。
    project_raw = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR")
    project_dir = Path(str(project_raw)) if project_raw else None
    state_dir = _default_state_dir()
    blocked, fingerprint, has_hold = _evaluate(
        entries, conversation_id=conversation_id,
        state_dir=state_dir, project_dir=project_dir)
    marker = _blocked_marker_path(state_dir, conversation_id)
    if not blocked:
        try:
            marker.unlink(missing_ok=True)
        except OSError:
            pass
        return 0

    # 明示保留を含む阻止状態が直前と同一なら再発火しない（Issue #3595）。
    # 札の無い未完了は抑制対象にしない（止め続ける）。
    if has_hold and fingerprint:
        try:
            if marker.is_file() and marker.read_text(encoding="utf-8") == fingerprint:
                return 0
        except OSError:
            pass
        try:
            _touch(marker)
            marker.write_text(fingerprint, encoding="utf-8")
        except OSError:
            pass

    print(json.dumps({"decision": "block", "reason": BLOCK_REASON}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
