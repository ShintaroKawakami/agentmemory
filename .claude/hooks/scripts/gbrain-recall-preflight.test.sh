#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/gbrain-recall-preflight.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_hook() {
  local prompt="$1"
  printf '{"user_prompt": "%s"}' "$prompt" | bash "$HOOK"
}

normal_output="$(run_hook "今日は天気だけ確認")"
[ -z "$normal_output" ] || fail "通常プロンプトは無音であるべき: $normal_output"

bug_output="$(run_hook "このAPIのバグを直して")"
echo "$bug_output" | grep -q "tech-gbrain を検索してから着手" \
  || fail "バグ修正プロンプトで tech-gbrain 案内が出ない: $bug_output"

business_output="$(run_hook "この施策について相談したい")"
echo "$business_output" | grep -q "shintaro-gbrain を検索してから着手" \
  || fail "経営相談プロンプトで shintaro-gbrain 案内が出ない: $business_output"

force_output="$(printf '{"user_prompt": "ただの雑談"}' | GBRAIN_RECALL_PREFLIGHT_FORCE=1 bash "$HOOK")"
echo "$force_output" | grep -q "gbrain-recall preflight:" || fail "FORCE時の preflight が出ない: $force_output"
echo "$force_output" | grep -q "該当キーワードなし" || fail "FORCE時に無該当メッセージが出ない: $force_output"

echo "PASS: gbrain-recall-preflight"
