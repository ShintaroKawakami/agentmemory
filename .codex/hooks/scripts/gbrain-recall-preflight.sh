#!/bin/bash
# UserPromptSubmit hook for gbrain-recall reminders.
# Quiet by default: only prints when the prompt contains a known keyword group
# (bug/investigation or management-consultation/strategy), or when
# GBRAIN_RECALL_PREFLIGHT_FORCE=1 is set.
#
# [2026-08-04][feat] G-Brain ハーネス Phase 1（gbrain-recall rule と対の hook）
# 背景:
#   - ユーザー依頼意図: .claude/rules/general/gbrain-recall.md の発火条件表（バグ修正/障害調査→
#     tech-gbrain、経営相談/戦略→shintaro-gbrain）を、通常の会話でも軽量に思い出させたい。
#   - 守るべき業務ルール: 重い処理は禁止（軽量 grep のみ）。検索を実行するかどうかの判断はモデル側に
#     残す（rule §2）。既存の agent-memory-preflight.sh / handover-preflight.sh と同型の
#     UserPromptSubmit hook 実装様式に倣う（quiet-by-default・JSON stdin パース・FORCE env）。
#   - 他案不採用理由: hook 側で自動的に search ツールを呼ぶ案は、誤爆時にノイズ・不要な MCP 呼び出しが
#     発生するため不採用（rule §2 のとおりリマインドに留める）。
# 対応: 新規 hook を追加。settings/gbrain-recall-preflight.json（Claude）と
#   settings-codex/gbrain-recall-preflight.json（Codex）を同一 PR で追加する。

set -euo pipefail

RAW_INPUT="$(cat || true)"

HOOK_INPUT="$RAW_INPUT" command python3 - <<'PY'
import json
import os
import re
import sys


def prompt_from_payload(text: str) -> str:
    if not text.strip():
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return text
    if not isinstance(payload, dict):
        return ""
    for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
        value = payload.get(key)
        if isinstance(value, str):
            return value
    nested = payload.get("tool_input")
    if isinstance(nested, dict):
        for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
            value = nested.get(key)
            if isinstance(value, str):
                return value
    return ""


# .claude/rules/general/gbrain-recall.md §1 の発火条件表と同じキーワード群。
# 語の追加・変更はルール本体と同一 PR で行う（二重管理防止）。
TECH_KEYWORDS = [
    "バグ", "直して", "不具合", "障害", "エラー", "直らない", "原因", "回帰",
]
BUSINESS_KEYWORDS = [
    "相談", "戦略", "クレーム", "どうすれば", "オペレーション改善", "施策", "売上",
]

TECH_RE = re.compile("|".join(re.escape(w) for w in TECH_KEYWORDS))
BUSINESS_RE = re.compile("|".join(re.escape(w) for w in BUSINESS_KEYWORDS))

raw = os.environ.get("HOOK_INPUT", "")
prompt = prompt_from_payload(raw)
forced = os.environ.get("GBRAIN_RECALL_PREFLIGHT_FORCE", "0") == "1"

tech_hit = bool(TECH_RE.search(prompt))
business_hit = bool(BUSINESS_RE.search(prompt))

if not forced and not (tech_hit or business_hit):
    raise SystemExit(0)

print("gbrain-recall preflight:")
if not (tech_hit or business_hit):
    print("- 該当キーワードなし（FORCE 表示）")
if tech_hit:
    print("- tech-gbrain を検索してから着手（バグ修正・障害調査・回帰）")
if business_hit:
    print("- shintaro-gbrain を検索してから着手（経営相談・戦略・クレーム対応）")
print("- 詳細: .claude/rules/general/gbrain-recall.md")
PY
