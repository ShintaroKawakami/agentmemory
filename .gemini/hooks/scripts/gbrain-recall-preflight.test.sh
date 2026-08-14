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

fix_both_output="$(run_hook "修正して")"
echo "$fix_both_output" | grep -q "shintaro-gbrain と tech-gbrain の両方を検索してから着手" \
  || fail "修正プロンプトで両方の案内が出ない: $fix_both_output"

think_both_output="$(run_hook "どう思う？")"
echo "$think_both_output" | grep -q "shintaro-gbrain と tech-gbrain の両方を検索してから着手" \
  || fail "どう思うプロンプトで両方の案内が出ない: $think_both_output"

bug_output="$(run_hook "このAPIのバグを直して")"
echo "$bug_output" | grep -q "shintaro-gbrain と tech-gbrain の両方を検索してから着手" \
  || fail "直してを含むバグ修正プロンプトで両方の案内が出ない: $bug_output"

business_output="$(run_hook "この施策について相談したい")"
echo "$business_output" | grep -q "shintaro-gbrain と tech-gbrain の両方を検索してから着手" \
  || fail "相談プロンプトで両方の案内が出ない: $business_output"

tech_only_output="$(run_hook "なぜこのエラーが出るか調べて")"
echo "$tech_only_output" | grep -q "tech-gbrain を検索してから着手" \
  || fail "純粋な障害調査プロンプトで tech-gbrain 案内が出ない: $tech_only_output"
echo "$tech_only_output" | grep -q "両方を検索" \
  && fail "純粋な障害調査プロンプトで両方案内が出てはいけない: $tech_only_output"

force_output="$(printf '{"user_prompt": "ただの雑談"}' | GBRAIN_RECALL_PREFLIGHT_FORCE=1 bash "$HOOK")"
echo "$force_output" | grep -q "gbrain-recall preflight:" || fail "FORCE時の preflight が出ない: $force_output"
echo "$force_output" | grep -q "該当キーワードなし" || fail "FORCE時に無該当メッセージが出ない: $force_output"

echo "PASS: gbrain-recall-preflight"
