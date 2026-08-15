#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
HOOK="$SCRIPT_DIR/handover-preflight.sh"

# [2026-08-05][fix] `set -o pipefail` 下の `echo "$x" | grep -q` を here-string へ置換する。
# 背景:
# - ユーザー依頼意図: closeout でこのテストを回したところ、origin/main の時点で
#   「handover preflight が出ない」と落ちた。出力には該当行が含まれており、実際は誤検知だった。
# - 根本原因: `grep -q` は最初の一致で即 exit するため、上流の `echo` が EPIPE(141) で落ちる。
#   `set -o pipefail` があるとパイプライン全体が非ゼロになり、一致しているのに `|| fail` が走る。
#   出力サイズ・実行タイミングで再現が揺れるため、これまで見逃されていた。
# - 守るべき業務ルール: テストは誤検知で落ちない。ここが不安定だと hook の回帰が守れない。
# - 他案不採用理由:
#   1) `set +o pipefail` にする案: 他の本物のパイプ失敗まで握り潰すため不採用。
#   2) `grep -q` を `grep -c` へ変える案: 一致行数の比較が増え、アサーションの意図がぼやける。


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
  grep -Fq "$expected" <<< "$output" \
    || fail "$category が scope と一致しない: $output"
}

assert_claude_memory_path() {
  local output="$1"
  local marker="$2"
  local memory_path

  memory_path="$(extract_field "$output" "claude_memory")"
  [ -n "$memory_path" ] || fail "claude_memory が取得できない: $output"
  case "$memory_path" in
    *"/.claude/projects/"*"/memory/MEMORY.md")
      :
      ;;
    *)
      fail "claude_memory の形式が想定外: $memory_path"
      ;;
  esac
  case "$memory_path" in
    *"$marker"*)
      :
      ;;
    *)
      fail "claude_memory が期待するPJを示していない: $memory_path"
      ;;
  esac
}

run_hook() {
  local prompt="$1"
  local project_dir="${2:-$REPO_ROOT}"
  printf '{"user_prompt": "%s"}' "$prompt" | CLAUDE_PROJECT_DIR="$project_dir" bash "$HOOK"
}

normal_output="$(run_hook "今日は天気だけ確認")"
[ -z "$normal_output" ] || fail "通常プロンプトは無音であるべき: $normal_output"

negative_output="$(run_hook "評価わんこについて。続きではなく概要を教えて")"
[ -z "$negative_output" ] || fail "否定文は無音であるべき: $negative_output"

negative_reflection_output="$(run_hook "ふり返りは不要です")"
[ -z "$negative_reflection_output" ] || fail "否定文は無音であるべき: $negative_reflection_output"

negative_hiragana_reflection_output="$(run_hook "ふりかえりはいらない")"
[ -z "$negative_hiragana_reflection_output" ] || fail "ひらがな否定文は無音であるべき: $negative_hiragana_reflection_output"

hyoka_output="$(run_hook "評価わんこの続き")"
grep -q "handover preflight:" <<< "$hyoka_output" \
  || fail "handover preflight が出ない: $hyoka_output"
assert_scoped_path "$hyoka_output" "handovers"
assert_scoped_path "$hyoka_output" "takeovers"
grep -q "skills/handover-manual/references/handover.md" <<< "$hyoka_output" \
  || fail "handover manual が出ない: $hyoka_output"

admin_output="$(run_hook "引継ぎ書つくって")"
assert_scoped_path "$admin_output" "handovers"

closeout_output="$(run_hook "作業終了。今回の内容を Handover に整理して")"
grep -q "placement-policy" <<< "$closeout_output" \
  || fail "作業終了で placement-policy が出ない: $closeout_output"
grep -q "reflection-policy" <<< "$closeout_output" \
  || fail "作業終了で reflection-policy が出ない: $closeout_output"
grep -q "未完了 / 次回やること / Tech G-Brain候補 / GBrain候補 / SSOT昇格候補" <<< "$closeout_output" \
  || fail "分類分離の案内が出ない: $closeout_output"
grep -q "終了整理のたびに current.md を最新化" <<< "$closeout_output" \
  || fail "handover更新条件の案内が出ない: $closeout_output"

jtt_apps_reflection_output="$(run_hook "jtt-appsにふり返りを依頼")"
grep -q "handover preflight:" <<< "$jtt_apps_reflection_output" \
  || fail "jtt-appsのふり返りで preflight が出ない: $jtt_apps_reflection_output"
grep -q "scope: jtt-apps/root" <<< "$jtt_apps_reflection_output" \
  || fail "jtt-appsのscopeが出ない: $jtt_apps_reflection_output"
assert_claude_memory_path "$jtt_apps_reflection_output" "Herd-jtt-apps"

jtt_apps_hiragana_reflection_output="$(run_hook "jtt-appsのふりかえりをお願い")"
grep -q "scope: jtt-apps/root" <<< "$jtt_apps_hiragana_reflection_output" \
  || fail "jtt-appsのひらがなふりかえりでscopeが出ない: $jtt_apps_hiragana_reflection_output"

jtt_cms_reflection_output="$(run_hook "ふり返りをお願い" "/Users/shintaro/LLM-Dev/jtt-cms")"
grep -q "handover preflight:" <<< "$jtt_cms_reflection_output" \
  || fail "jtt-cmsのふり返りで preflight が出ない: $jtt_cms_reflection_output"
grep -q "scope: jtt-cms/root" <<< "$jtt_cms_reflection_output" \
  || fail "jtt-cmsのscopeが出ない: $jtt_cms_reflection_output"
assert_scoped_path "$jtt_cms_reflection_output" "handovers"
assert_claude_memory_path "$jtt_cms_reflection_output" "LLM-Dev-jtt-cms"

jtt_system_reflection_output="$(run_hook "ふり返りをお願い" "/Users/shintaro/jtt-system")"
grep -q "scope: jtt-system/root" <<< "$jtt_system_reflection_output" \
  || fail "jtt-systemのscopeが出ない: $jtt_system_reflection_output"

# [2026-08-05][test] mac-mini-server 配下の repo が non-pj へ落ちないことを固定する。
# 正本 resolve-handover-path.py の MAC_MINI_REPOS と同じ解決になることを回帰で守る
# （closeout で preflight だけ non-pj/root を出し、handover が別 scope へ書かれかけた）。
for mm_repo in register sales analytics keiei-dashboard cron-dashboard; do
  mm_output="$(run_hook "作業終了。終了整理して" "/Users/shintaro/mac-mini-server/$mm_repo")"
  assert_exact_scope "$mm_output" "$mm_repo/root"
  assert_scoped_path "$mm_output" "handovers"
done

# 台帳外の mac-mini-server 直下は non-pj ではなく mac-mini-server 扱い（正本と同じ）
mm_unknown_output="$(run_hook "作業終了。終了整理して" "/Users/shintaro/mac-mini-server/not-a-registered-repo")"
assert_exact_scope "$mm_unknown_output" "mac-mini-server/root"

if is_agent_hub_source_repo; then
  agent_hub_reflection_output="$(run_hook "ふり返りをお願い" "$REPO_ROOT")"
  assert_exact_scope "$agent_hub_reflection_output" "AGENT-HUB/root"
  assert_scoped_path "$agent_hub_reflection_output" "handovers"
fi

compat_output="$(run_hook "continuation-closeout")"
grep -q "handover preflight:" <<< "$compat_output" \
  || fail "continuation-closeout 互換 trigger が出ない: $compat_output"

handover_output="$(run_hook "handover")"
grep -q "handover preflight:" <<< "$handover_output" \
  || fail "handover trigger が出ない: $handover_output"

force_output="$(printf '{"user_prompt": "ただの相談"}' | HANDOVER_PREFLIGHT_FORCE=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK")"
grep -q "handover preflight:" <<< "$force_output" || fail "FORCE時の preflight が出ない: $force_output"
grep -q "alias: 未検出" <<< "$force_output" || fail "FORCE時に alias 推定が出ない: $force_output"

compat_force_output="$(printf '{"user_prompt": "ただの相談"}' | TAKEOVER_PREFLIGHT_FORCE=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK")"
grep -q "handover preflight:" <<< "$compat_force_output" || fail "旧TAKEOVER_PREFLIGHT_FORCE時の preflight が出ない: $compat_force_output"

echo "PASS: handover-preflight"
