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
