#!/bin/bash
# UserPromptSubmit hook for gbrain-recall reminders.
# Quiet by default: only prints when the prompt contains a known keyword group
# (bug/investigation or management-consultation/strategy), or when
# GBRAIN_RECALL_PREFLIGHT_FORCE=1 is set.
# Availability is a model/user check. This hook only prints a reminder; it does
# not inspect a catalog or call an MCP tool.
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
#   - tool availability は初期 tool 一覧の欠落を OFF と見なさず、共通 rule の証拠順序を案内する。
# 対応: 新規 hook を追加。settings/gbrain-recall-preflight.json（Claude）と
#   settings-codex/gbrain-recall-preflight.json（Codex）を同一 PR で追加する。

set -euo pipefail

RAW_INPUT="$(cat || true)"

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd || true)"
HOOK_INPUT="$RAW_INPUT" HOOK_LIB_DIR="$HOOK_LIB_DIR" command python3 - <<'PY'
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


# [2026-09-08][feat] 発火語は hook-library/lib/gbrain-recall-policy.json（正本）から読む。
# 背景: 以前は本スクリプトの3配列・registries/gbrain-recall-policy.yaml・rule §1 の3か所に散り、
#   人間の注意書き（「同一 PR で直す」）だけで揃えていた。tests/test_hook_policy_registry.py が
#   ハードコード配列の残存と registry⊆lib のずれを赤にする。
_POLICY_PATH = os.environ.get("GBRAIN_RECALL_POLICY_PATH") or os.path.join(
    os.environ.get("HOOK_LIB_DIR", ""), "gbrain-recall-policy.json"
)
try:
    with open(_POLICY_PATH, encoding="utf-8") as _f:
        _PATTERNS = json.load(_f).get("patterns", {})
except Exception as _exc:  # fail-open だが黙らない
    print("gbrain-recall preflight:")
    print(f"- 台帳 gbrain-recall-policy.json が読めません（{_exc}）。詳細: .claude/rules/general/gbrain-recall.md")
    raise SystemExit(0)


def _words(key: str):
    return [w for w in _PATTERNS.get(key, {}).get("keywords", []) if isinstance(w, str) and w]


CONSULT_BOTH_KEYWORDS = _words("consult_both")
TECH_ONLY_KEYWORDS = _words("tech_only")
BUSINESS_ONLY_KEYWORDS = _words("business_only")

CONSULT_BOTH_RE = re.compile("|".join(re.escape(w) for w in CONSULT_BOTH_KEYWORDS))
TECH_ONLY_RE = re.compile("|".join(re.escape(w) for w in TECH_ONLY_KEYWORDS))
BUSINESS_ONLY_RE = re.compile("|".join(re.escape(w) for w in BUSINESS_ONLY_KEYWORDS))

raw = os.environ.get("HOOK_INPUT", "")
prompt = prompt_from_payload(raw)
forced = os.environ.get("GBRAIN_RECALL_PREFLIGHT_FORCE", "0") == "1"

consult_both_hit = bool(CONSULT_BOTH_RE.search(prompt))
tech_hit = bool(TECH_ONLY_RE.search(prompt))
business_hit = bool(BUSINESS_ONLY_RE.search(prompt))
any_hit = consult_both_hit or tech_hit or business_hit

if not forced and not any_hit:
    raise SystemExit(0)

print("gbrain-recall preflight:")
if not any_hit:
    print("- 該当キーワードなし（FORCE 表示）")
if consult_both_hit:
    # [2026-08-30] jtt-gbrain（3つ目・会社そのもの）は「あるなら追加で見る」。必須2つの検索は止めない。
    # 既存テストが下記の固定文言を grep するため、文言は変えず後ろの行として足すこと。
    print("- shintaro-gbrain と tech-gbrain の両方を検索してから着手（相談・直し・判断）")
    print("- jtt-gbrain（会社そのもの: 人・取引先・PJ）は AVAILABLE なら追加で見る。無ければ飛ばして進む")
elif tech_hit:
    print("- tech-gbrain を検索してから着手（バグ修正・障害調査・回帰）")
elif business_hit:
    print("- shintaro-gbrain を検索してから着手（経営相談・戦略・クレーム対応）")
    print("- jtt-gbrain（会社そのもの: 人・取引先・PJ）は AVAILABLE なら追加で見る")
print("- tool availability: 初期 tool 一覧の欠落だけでは可否を決めない")
print("- status の証拠順序: セッション catalog → 遅延 catalog → 選択状態 → runtime 実測 → 結論")
print("- status: AVAILABLE / NOT_SELECTED / RUNTIME_UNAVAILABLE / UNPROVEN")
print("- hook は案内のみ。catalog 探索・MCP tool 呼出しは自動実行しない")
print("- 詳細: .claude/rules/general/gbrain-recall.md")
print("- 共通ルール: .claude/rules/general/tool-availability-resolution.md")
PY
