#!/usr/bin/env bash
# telemetry-log.test.sh — telemetry-log.sh のフックエントリ専用回帰テスト。
#
# 背景（jtt-apps PR #964 の Codex レビュー起点）:
#   telemetry-log.sh / telemetry-lib.sh 自体の網羅テストは scripts/test-telemetry-hook.sh
#   （AGENT-HUB 自身の CI・.github/workflows/ci.yml「Hook integration tests」で実行）が担う。
#   一方、hook-library/scripts/*.test.sh は「配布先 PJ に script_map 経由で同梱し、配布後の
#   hook 単体を再検証できる」サイドカーの規約（block-main-commit.test.sh 等と同型）。
#   telemetry-log だけこのサイドカーが無く、配布先で telemetry-log.sh 単体の動作を
#   再確認する手段が欠けていたため新設する。
#
# 検証内容（3点。scripts/test-telemetry-hook.sh の該当項目のサブセット）:
#   1. Skill ツールの hook JSON を stdin に与えると JSONL が1行増える
#   2. AGENT_HUB_TELEMETRY_DISABLE=1 で何も書かず exit 0
#   3. 壊れた JSON 入力でも exit 0（fail-open）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/telemetry-log.sh"

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# telemetry-lib.sh の出力先は AGENT_HUB_TELEMETRY_DIR で上書き可能(テスト用)。
# 本物の ~/.agent-hub/telemetry/ を汚さないよう一時ディレクトリへ差し替える。
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export AGENT_HUB_TELEMETRY_DIR="$TEST_TMP/telemetry"
unset AGENT_HUB_TELEMETRY_DISABLE || true
unset AGENT_HUB_TELEMETRY_PJ || true

count_lines() {
  local files
  files="$(ls -1 "$AGENT_HUB_TELEMETRY_DIR"/*.jsonl 2>/dev/null || true)"
  if [ -z "$files" ]; then
    echo 0
    return
  fi
  cat $files 2>/dev/null | wc -l | tr -d '[:space:]'
}

last_line() {
  local files
  files="$(ls -1 "$AGENT_HUB_TELEMETRY_DIR"/*.jsonl 2>/dev/null || true)"
  if [ -z "$files" ]; then
    echo ""
    return
  fi
  cat $files 2>/dev/null | tail -n1
}

# ── 1/3: Skill ツールの hook JSON → JSONL が1行増える ────────────────
BEFORE=$(count_lines)
printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"name":"plan-approval"}}' \
  | bash "$HOOK" 2>/dev/null
AFTER=$(count_lines)
if [ "$AFTER" -gt "$BEFORE" ]; then
  LAST_LINE="$(last_line)"
  if printf '%s' "$LAST_LINE" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["event_type"]=="skill_fire" and d["name"]=="plan-approval"' 2>/dev/null; then
    pass "Skill発火のhook JSONでJSONLが1行増える"
  else
    fail "Skill発火のJSONL内容" "想定外の内容: $LAST_LINE"
  fi
else
  fail "Skill発火でJSONLが増える" "行数が増えなかった(before=$BEFORE after=$AFTER)"
fi

# [2026-10-06][feat] skill_fire の診断情報（meta）と AI 名（T_TOOL）の回帰テスト。
# 背景: 名前が空の skill_fire が約2割残り原因不明だったため、発火イベント名を meta に残し、
#   名前が空のときだけ受け取った項目の「名前」を残す（値は残さない）。AI別の集計表のため T_TOOL を尊重する。
# ── 1-b: skill_fire の meta に発火イベント名が残る ─────────────────────
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"resend"}}' \
  | bash "$HOOK" 2>/dev/null
if last_line | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["name"]=="resend" and d["meta"]=={"hook_event":"PostToolUse"}' 2>/dev/null; then
  pass "skill_fireのmetaに発火イベント名が残る（名前あり）"
else
  fail "skill_fireのmeta" "想定外の内容: $(last_line)"
fi

# ── 1-c: 名前が空でも記録し、受け取った項目の名前だけを meta に残す（値は残さない）──
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"secret_value":"SHOULD-NOT-BE-LOGGED","args":"x"}}' \
  | bash "$HOOK" 2>/dev/null
EMPTY_LINE="$(last_line)"
if printf '%s' "$EMPTY_LINE" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["meta"]; assert d["event_type"]=="skill_fire" and d["name"]=="" and m["tool_input_keys"]==["args","secret_value"] and "tool_input" in m["payload_keys"] and m["hook_event"]=="PostToolUse"' 2>/dev/null \
   && ! printf '%s' "$EMPTY_LINE" | grep -q 'SHOULD-NOT-BE-LOGGED'; then
  pass "名前が空のskill_fireは項目名だけをmetaに残し値は残さない"
else
  fail "名前が空のskill_fire" "想定外の内容: $EMPTY_LINE"
fi

# ── 1-d: T_TOOL で AI 名を指定できる（Kimi / Cursor の中継が使う）──────────
printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"brainstorm"}}' \
  | T_TOOL=kimi-code bash "$HOOK" 2>/dev/null
if last_line | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["tool"]=="kimi-code" and d["name"]=="brainstorm"' 2>/dev/null; then
  pass "T_TOOLでAI名を指定できる"
else
  fail "T_TOOL" "想定外の内容: $(last_line)"
fi

# ── 2/3: AGENT_HUB_TELEMETRY_DISABLE=1 で何も書かず exit 0 ───────────
BEFORE=$(count_lines)
DISABLE_OUT="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"name":"nope"}}' \
  | AGENT_HUB_TELEMETRY_DISABLE=1 bash "$HOOK" 2>/dev/null; echo "rc=$?")"
AFTER=$(count_lines)
if [ "$BEFORE" = "$AFTER" ] && printf '%s' "$DISABLE_OUT" | grep -q 'rc=0'; then
  pass "AGENT_HUB_TELEMETRY_DISABLE=1で何も書かずexit 0"
else
  fail "AGENT_HUB_TELEMETRY_DISABLE=1" "行数変化(before=$BEFORE after=$AFTER) または非0終了: $DISABLE_OUT"
fi

# ── 3/3: 壊れた JSON でも exit 0(fail-open) ───────────────────────────
BROKEN_OUT="$(printf 'not json at all {{{' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
if printf '%s' "$BROKEN_OUT" | grep -q 'rc=0'; then
  pass "壊れたJSON入力でもexit 0(fail-open)"
else
  fail "壊れたJSON入力" "exit 0 にならなかった: $BROKEN_OUT"
fi

# 空 stdin も fail-open で exit 0 であることも併せて確認(壊れたJSON系の代表的な派生形)。
EMPTY_OUT="$(printf '' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
if printf '%s' "$EMPTY_OUT" | grep -q 'rc=0'; then
  pass "空stdinでもexit 0(fail-open)"
else
  fail "空stdin" "exit 0 にならなかった: $EMPTY_OUT"
fi

echo ""
echo "=== telemetry-log.test.sh: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
