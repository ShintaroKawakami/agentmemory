#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
HOOK="$SCRIPT_DIR/takeover-preflight.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_field() {
  printf "%s\n" "$1" | sed -n "s/^-[[:space:]]*$2: //p"
}

is_agent_hub_source_repo() {
  [ -f "$REPO_ROOT/DISTRIBUTION.yaml" ] && [ -f "$REPO_ROOT/hook-registry.yaml" ]
}

assert_exact_scope() {
  local output="$1"
  local expected="$2"
  local scope

  scope="$(extract_field "$output" "scope")"
  [ -n "$scope" ] || fail "scope が取得できない: $output"
  [ "$scope" = "$expected" ] || fail "scope が期待値と一致しない: $output"
}

assert_scoped_path() {
  local output="$1"
  local category="$2"
  local scope
  local expected

  scope="$(extract_field "$output" "scope")"
  [ -n "$scope" ] || fail "scope が取得できない: $output"
  expected="$HOME/.agent-hub/$category/$scope/current.md"
  printf "%s\n" "$output" | grep -Fq "$expected" \
    || fail "$category が scope と一致しない: $output"
}

run_hook() {
  local prompt="$1"
  printf '{"user_prompt": "%s"}' "$prompt" | CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK"
}

normal_output="$(run_hook "今日は天気だけ確認")"
[ -z "$normal_output" ] || fail "通常プロンプトは無音であるべき: $normal_output"

negative_output="$(run_hook "評価わんこについて。続きではなく概要を教えて")"
[ -z "$negative_output" ] || fail "否定文は無音であるべき: $negative_output"

negative_finish_output="$(run_hook "終了整理は不要です")"
[ -z "$negative_finish_output" ] || fail "否定文は無音であるべき: $negative_finish_output"

negative_closeout_output="$(run_hook "Closeout整理はいらない")"
[ -z "$negative_closeout_output" ] || fail "否定文は無音であるべき: $negative_closeout_output"

negative_work_output="$(run_hook "作業終了ではないです")"
[ -z "$negative_work_output" ] || fail "否定文は無音であるべき: $negative_work_output"

representative_prompt="作業終了。今回の内容を終了整理して。GBrain候補は僕の確認待ち、SSOTとTech G-Brainは自動判定で。未完了がある時だけTakeoverも更新して。"
representative_output="$(run_hook "$representative_prompt")"
echo "$representative_output" | grep -q "handover preflight:" \
  || fail "代表入力文で preflight が出ない: $representative_output"
echo "$representative_output" | grep -q "skills/handover-manual/references/handover.md" \
  || fail "代表入力文で handover manual が出ない: $representative_output"

closeout_word_output="$(run_hook "終了整理")"
echo "$closeout_word_output" | grep -q "handover preflight:" \
  || fail "終了整理単独で preflight が出ない: $closeout_word_output"

closeout_compat_output="$(run_hook "Closeout整理")"
echo "$closeout_compat_output" | grep -q "handover preflight:" \
  || fail "Closeout整理で preflight が出ない: $closeout_compat_output"

hyoka_output="$(run_hook "評価わんこの続き")"
echo "$hyoka_output" | grep -q "handover preflight:" \
  || fail "handover preflight が出ない: $hyoka_output"
echo "$hyoka_output" | grep -q ".agent-hub/handovers/jtt-system/hyoka-wanko/current.md" \
  || fail "評価わんこの handover_path が出ない: $hyoka_output"
echo "$hyoka_output" | grep -q ".agent-hub/takeovers/jtt-system/hyoka-wanko/current.md" \
  || fail "評価わんこの legacy_path が出ない: $hyoka_output"
echo "$hyoka_output" | grep -q "skills/handover-manual/references/handover.md" \
  || fail "handover manual が出ない: $hyoka_output"

admin_output="$(run_hook "引継ぎ書つくって")"
assert_scoped_path "$admin_output" "handovers"

compat_output="$(run_hook "continuation-closeout")"
echo "$compat_output" | grep -q "handover preflight:" \
  || fail "continuation-closeout 互換 trigger が出ない: $compat_output"

force_output="$(printf '{"user_prompt": "ただの相談"}' | TAKEOVER_PREFLIGHT_FORCE=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK")"
echo "$force_output" | grep -q "handover preflight:" || fail "FORCE時の preflight が出ない: $force_output"
echo "$force_output" | grep -q "alias: 未検出" || fail "FORCE時に alias 推定が出ない: $force_output"

compat_force_output="$(printf '{"user_prompt": "ただの相談"}' | AGENT_MEMORY_PREFLIGHT_FORCE=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK")"
echo "$compat_force_output" | grep -q "handover preflight:" || fail "旧AGENT_MEMORY_PREFLIGHT_FORCE 時の preflight が出ない: $compat_force_output"

if is_agent_hub_source_repo; then
  agent_hub_reflection_output="$(run_hook "ふり返りをお願い")"
  assert_exact_scope "$agent_hub_reflection_output" "AGENT-HUB/root"
  assert_scoped_path "$agent_hub_reflection_output" "handovers"
fi

echo "PASS: takeover-preflight"
