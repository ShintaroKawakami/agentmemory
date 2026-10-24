#!/usr/bin/env python3
"""Stop hook: 止まる前の点検（見張りなしの待ち・途中の一言・承認後の聞き直し）。

[2026-10-24][feat] AI が黙って止まる3つの型を、止まる前に1回だけ AI に戻す。
背景:
  - ユーザー依頼意図: 伸太郎さん「勝手に止まるのがすごく嫌」(2026-10-24)。Orca の記録1か月で、
    AI がターンを閉じて黙って止まった型が3つあった。
      (a) 見張りなしの「待ちます／終わったら続けます」 約12回
      (b) 「確認します」「続けます」など途中の一言で終わる 約11回
      (c) 直前に「進めて／お願い／OK」等の承認があるのに「進めてよいですか？」と聞き直す 約9回
  - 守るべき業務ルール:
      * 同じ所では1回だけ止める（stop_hook_active / loop_count>0 は必ず通す）。
      * どんな例外・読めない記録・読めない policy でも通す（fail-open）。迷ったら通す。
      * 人の答え待ち（[明示保留]・選択肢つき質問・本番 GO/外部送信/お金/権限/新しいプランの承認待ち・
        AskUserQuestion）は先に通す。本番 GO・外への送信・お金・権限の止まり所は変えない。
      * ターンの境界は「最新の実ユーザー発言」。<task-notification>・<system-reminder>・
        tool_result・Stop hook feedback などの合成 user 行は境界にしない
        （Tech G-Brain stop-hook-turn-boundary-excludes-synthetic-user-lines）。
      * (a) は文面だけで決めない。裏作業（Bash/Agent の run_in_background、Monitor）のうち
        終了通知が来ていないものか、見張りスクリプトのプロセスが生きていれば「見張りあり」。
        確かめられない時（unknown）は通す。止めるのは「見張りなしと確かめられた」時だけ。
      * (c) の「承認」は新しい承認ではない。範囲内なら進め、範囲外なら理由を1行書いて聞かせる。
      * 発火語・除外語は hook-library/lib/loop-continuity-policy.json に置き、ここへ直書きしない
        （Tech G-Brain hook-policy-registry-json-and-read-gate）。
  - 他案不採用理由:
      1) 文面だけで「待ちます」を止める案は、Monitor/裏作業で正しく待っている時を誤って止めるため不採用。
      2) 全ターンを止めて AI に自己点検させる案は、通常の完了報告まで止めて邪魔になるため不採用。
      3) stop-goal-check.py に同居させる案は、Goal 付きでないセッションにも効かせたいのと、
         既存判定を変えない約束のため不採用（transcript の読み方だけ同じ型に合わせた）。
      4) プロセス一覧だけで見張りを判定する案は、Monitor・サブエージェントの待ちを拾えず、
         他セッションの見張りで誤って「ある」と判定するため単独では不採用（transcript と併用）。
対応: Stop で transcript を読み、人の答え待ちを先に通したうえで (a)(b)(c) のいずれかなら
  {"decision":"block","reason":"止まる前の点検: …"} を1回だけ返す。Cursor 形式など読めない入力は通す。
  LOOP_CONTINUITY_SKIP_PROCESS_CHECK=1 の時は見張りスクリプトのプロセス照合を飛ばし、
  transcript の裏作業だけで見張りの有無を決める（プロセス側は「動いていない」扱い。過去の記録での
  空打ち用。未設定の既定の動きは変えない）。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

POLICY_ENV = "LOOP_CONTINUITY_POLICY"
PS_FILE_ENV = "LOOP_CONTINUITY_PS_FILE"
SKIP_PS_ENV = "LOOP_CONTINUITY_SKIP_PROCESS_CHECK"

_SHELL_LIKE = frozenset({"bash", "sh", "zsh", "python", "python3", "env", "node"})
_NOT_WATCHERS = frozenset({"grep", "rg", "ps", "pgrep", "tail", "cat", "less", "vim", "git", "sed", "awk", "head"})

_CODE_FENCE_RE = re.compile(r"```.*?(?:```|\Z)", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[。！？!?．])\s*|\n+")
_EDGE_TRIM = " \t*_~-・>#"

_TASK_ID_RE = re.compile(r"<task-id>\s*([^<\s]+)\s*</task-id>")
_TOOL_USE_ID_RE = re.compile(r"<tool-use-id>\s*([^<\s]+)\s*</tool-use-id>")
_STATUS_RE = re.compile(r"<status>\s*([^<\s]+)\s*</status>")
_BG_ID_RES = (
    re.compile(r"running in background with ID:\s*([A-Za-z0-9_-]+)"),
    re.compile(r"Monitor started \(task\s+([A-Za-z0-9_-]+)"),
    re.compile(r"agentId:\s*([A-Za-z0-9_-]+)"),
)


# --------------------------------------------------------------------------- policy

def load_policy(path: Path | None = None) -> dict | None:
    """policy JSON を読んで正規表現を組み立てる。読めない・壊れていれば None（呼び出し側は通す）。"""
    try:
        if path is None:
            env = os.environ.get(POLICY_ENV)
            path = Path(env) if env else Path(__file__).resolve().parent.parent / "lib" / "loop-continuity-policy.json"
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            return None

        def comp(key: str, section: dict | None = None) -> list[re.Pattern]:
            src = (section if section is not None else raw).get(key)
            if not isinstance(src, list) or not src:
                raise ValueError(f"policy key missing: {key}")
            return [re.compile(str(p), re.IGNORECASE) for p in src]

        hw = raw.get("human_wait")
        if not isinstance(hw, dict):
            return None
        reasons = raw.get("reasons")
        if not isinstance(reasons, dict) or not all(isinstance(reasons.get(k), str) for k in ("prefix", "wait", "intent", "reconfirm")):
            return None
        return {
            "synthetic_prefixes": [str(s) for s in raw["synthetic_user_prefixes"]],
            "terminal_statuses": frozenset(str(s).lower() for s in raw["terminal_task_statuses"]),
            "watcher_scripts": [str(s) for s in raw["watcher_scripts"]],
            "hw_markers": [str(s) for s in hw["markers"]],
            "hw_choice": comp("choice_patterns", hw),
            "hw_gate": comp("gate_patterns", hw),
            "wait": comp("wait_patterns"),
            "intent": comp("intent_end_patterns"),
            "done": comp("done_patterns"),
            "carryover": comp("carryover_patterns"),
            "approval": comp("approval_words"),
            "approval_neg": comp("approval_negations"),
            "reconfirm": comp("reconfirm_patterns"),
            "scope_reason": comp("scope_reason_patterns"),
            "reasons": reasons,
        }
    except Exception:
        return None


# --------------------------------------------------------------------------- transcript

def _iter_transcript(path: str) -> Iterable[Any]:
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _blocks(entry: dict) -> list[dict]:
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    out: list[dict] = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                out.append({"type": "text", "text": block})
            elif isinstance(block, dict):
                out.append(block)
    return out


def _text_of(blocks: list[dict]) -> str:
    return "\n".join(str(b.get("text", "")) for b in blocks if b.get("type") == "text")


def _result_text(block: dict) -> str:
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
    return ""


def _is_real_user(entry: dict, blocks: list[dict], policy: dict) -> bool:
    """最新の実ユーザー発言か。合成の user 行（通知・system-reminder・tool_result・hook feedback 等）は False。"""
    if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isCompactSummary"):
        return False
    origin = entry.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return False
    if blocks and all(b.get("type") == "tool_result" for b in blocks):
        return False
    text = _text_of(blocks).lstrip()
    if not text:
        return any(b.get("type") == "image" for b in blocks)
    return not any(text.startswith(p) for p in policy["synthetic_prefixes"])


def _entries_in_scope(entries: list[Any]) -> list[dict]:
    return [e for e in entries if isinstance(e, dict) and not e.get("isSidechain")]


def _turn(entries: list[dict], policy: dict) -> tuple[str, list[tuple[str, Any]], list[dict]]:
    """最新の実ユーザー発言の本文と、それより後の assistant ブロック列（text/tool_use）と、後続の全行を返す。"""
    last_user = -1
    user_text = ""
    for i, entry in enumerate(entries):
        blocks = _blocks(entry)
        if _is_real_user(entry, blocks, policy):
            last_user, user_text = i, _text_of(blocks)
    if last_user < 0:
        return "", [], []
    after = entries[last_user + 1:]
    seq: list[tuple[str, Any]] = []
    for entry in after:
        if entry.get("type") != "assistant":
            continue
        for block in _blocks(entry):
            kind = block.get("type")
            if kind == "text" and str(block.get("text", "")).strip():
                seq.append(("text", str(block["text"])))
            elif kind == "tool_use":
                seq.append(("tool_use", block))
    return user_text, seq, after


# --------------------------------------------------------------------------- text

def clean_text(text: str) -> str:
    """コードブロック・引用（> 行）・インラインコードを除く。"""
    text = _CODE_FENCE_RE.sub("\n", text)
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith(">"))
    text = _INLINE_CODE_RE.sub("", text)
    return text.strip()


def sentences(text: str) -> list[str]:
    out = []
    for part in _SENTENCE_SPLIT_RE.split(text):
        part = part.strip(_EDGE_TRIM)
        if part:
            out.append(part)
    return out


def _any(patterns: list[re.Pattern], text: str) -> bool:
    return any(p.search(text) for p in patterns)


def _unanswered_question(after: list[dict]) -> bool:
    """今回のターンで AskUserQuestion を出し、まだ tool_result（回答）が来ていないものがあるか。"""
    # [2026-10-24][fix] 回答済みの質問まで「人の答え待ち」として通していた漏れを直す。
    #   背景: 質問→回答の後に途中の一言で止まった場合も、ターン内に質問が1つでもあれば通っていた。
    #   対応: AskUserQuestion の tool_use の id と tool_result の tool_use_id を照合し、未回答だけを数える。
    asked: set[str] = set()
    answered: set[str] = set()
    for entry in after:
        for block in _blocks(entry):
            if entry.get("type") == "assistant" and block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                asked.add(str(block.get("id")))
            elif block.get("type") == "tool_result":
                answered.add(str(block.get("tool_use_id")))
    return bool(asked - answered)


def is_human_wait(text: str, unanswered_question: bool, policy: dict) -> bool:
    if unanswered_question:
        return True
    if any(m in text for m in policy["hw_markers"]):
        return True
    return _any(policy["hw_choice"], text) or _any(policy["hw_gate"], text)


# --------------------------------------------------------------------------- watcher

def background_state(entries: list[dict], policy: dict) -> str:
    """transcript だけで見た裏作業の状態: "open"（終了通知待ちあり）/ "unknown" / "none"。"""
    starts: dict[str, dict] = {}
    for entry in entries:
        for block in _blocks(entry):
            if entry.get("type") == "assistant" and block.get("type") == "tool_use":
                name, inp = block.get("name"), block.get("input") or {}
                bg = isinstance(inp, dict) and inp.get("run_in_background") is True
                if (name == "Bash" and bg) or (name in ("Agent", "Task") and bg) or name == "Monitor":
                    starts[str(block.get("id"))] = {"name": name, "state": "pending", "task": None}
                elif name in ("TaskStop", "KillShell", "KillBash") and isinstance(inp, dict):
                    target = inp.get("task_id") or inp.get("shell_id") or inp.get("taskId")
                    for info in starts.values():
                        if target and info["task"] == str(target):
                            info["state"] = "closed"
            elif block.get("type") == "tool_result" and str(block.get("tool_use_id")) in starts:
                info = starts[str(block["tool_use_id"])]
                if block.get("is_error") is True:
                    info["state"] = "closed"
                    continue
                result = entry.get("toolUseResult")
                text = _result_text(block)
                task = None
                if isinstance(result, dict):
                    task = result.get("backgroundTaskId") or result.get("taskId") or result.get("agentId")
                if not task:
                    for rx in _BG_ID_RES:
                        m = rx.search(text)
                        if m:
                            task = m.group(1)
                            break
                if info["name"] in ("Agent", "Task"):
                    async_ok = (isinstance(result, dict) and result.get("status") == "async_launched") or "Async agent launched" in text
                    if not async_ok:
                        info["state"] = "closed"
                        continue
                if task:
                    info["task"], info["state"] = str(task), "open"
                else:
                    info["state"] = "unknown"
        if entry.get("type") == "user":
            text = _text_of(_blocks(entry))
            if "<task-notification>" in text:
                status = _STATUS_RE.search(text)
                if not status or status.group(1).lower() not in policy["terminal_statuses"]:
                    continue
                task = _TASK_ID_RE.search(text)
                tuid = _TOOL_USE_ID_RE.search(text)
                for sid, info in starts.items():
                    if (task and info["task"] == task.group(1)) or (tuid and sid == tuid.group(1)):
                        info["state"] = "closed"
    states = {info["state"] for info in starts.values()}
    if "open" in states:
        return "open"
    if states & {"unknown", "pending"}:
        return "unknown"
    return "none"


def process_state(policy: dict) -> str:
    """見張りスクリプトのプロセス: "alive"/"none"/"error"。SKIP 指定時は "none"（動いていない扱い）。"""
    if os.environ.get(SKIP_PS_ENV) == "1":
        return "none"
    lines: list[str]
    ps_file = os.environ.get(PS_FILE_ENV)
    try:
        if ps_file:
            lines = Path(ps_file).read_text(encoding="utf-8", errors="replace").splitlines()
        else:
            res = subprocess.run(["ps", "-u", str(os.getuid()), "-o", "args="],
                                 capture_output=True, text=True, timeout=3)
            if res.returncode != 0:
                return "error"
            lines = res.stdout.splitlines()
    except Exception:
        return "error"
    scripts = set(policy["watcher_scripts"])
    for line in lines:
        tokens = line.split()
        if not tokens:
            continue
        if os.path.basename(tokens[0]) in _NOT_WATCHERS:
            continue
        head = tokens[:2] if os.path.basename(tokens[0]) in _SHELL_LIKE else tokens[:1]
        if any(os.path.basename(t) in scripts for t in head):
            return "alive"
    return "none"


def watcher_state(entries: list[dict], policy: dict) -> str:
    """"running" / "none" / "unknown"。block してよいのは "none" の時だけ。"""
    # [2026-10-24][fix] 別セッションの見張りプロセスで「見張りあり」と誤判定し、待ち文面を通していた漏れを直す。
    #   背景: process_state() は同じOSユーザーの全プロセスを見るため、他セッションの watch-*.sh でも alive になった。
    #   対応: 見張りありの証拠は transcript で見つけた裏作業（open）だけにする。プロセス照合は
    #         transcript に裏作業が無い時の「確かめられない（error）」判定にだけ使い、alive では通さない。
    bg = background_state(entries, policy)
    if bg == "open":
        return "running"
    if bg == "unknown" or process_state(policy) == "error":
        return "unknown"
    return "none"


# --------------------------------------------------------------------------- decision

def decide(entries: list[Any], policy: dict) -> str | None:
    """block する理由文（先頭の「止まる前の点検:」込み）を返す。通す時は None。"""
    scoped = _entries_in_scope(entries)
    user_text, seq, after = _turn(scoped, policy)
    texts = [i for i, (kind, _) in enumerate(seq) if kind == "text"]
    if not texts:
        return None
    last_idx = texts[-1]
    raw_last = seq[last_idx][1]
    text = clean_text(raw_last)
    if not text:
        return None
    if is_human_wait(text, _unanswered_question(after), policy):
        return None
    sents = sentences(text)
    if not sents:
        return None
    last = sents[-1]
    tail = " ".join(sents[-2:])
    tool_after_text = any(kind == "tool_use" for kind, _ in seq[last_idx + 1:])
    reasons = policy["reasons"]
    prefix = reasons["prefix"]

    # (a) 見張りなしの待ち。待ち文面があるなら、見張りの有無だけで決めてここで終える。
    if _any(policy["wait"], tail):
        if _any(policy["carryover"], tail):
            return None
        return prefix + reasons["wait"] if watcher_state(scoped, policy) == "none" else None

    # (c) 承認後の聞き直し
    if (_any(policy["reconfirm"], last)
            and _any(policy["approval"], user_text)
            and not _any(policy["approval_neg"], user_text)
            and not _any(policy["scope_reason"], tail)):
        return prefix + reasons["reconfirm"]

    # (b) 途中の一言
    if (not tool_after_text and _any(policy["intent"], last)
            and not _any(policy["done"], " ".join(sents[-3:]))
            and not _any(policy["carryover"], tail)):
        return prefix + reasons["intent"]
    return None


def _stop_already_active(payload: dict) -> bool:
    if payload.get("stop_hook_active") is True or payload.get("stopHookActive") is True:
        return True
    try:
        return int(payload.get("loop_count", payload.get("loopCount", 0))) > 0
    except (TypeError, ValueError):
        return False


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict) or _stop_already_active(payload):
            return 0
        path = payload.get("transcript_path") or payload.get("transcriptPath")
        if not path:
            return 0
        policy = load_policy()
        if policy is None:
            return 0
        entries = list(_iter_transcript(str(path)))
        if not entries:
            return 0
        reason = decide(entries, policy)
    except Exception:
        return 0
    if reason:
        print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
