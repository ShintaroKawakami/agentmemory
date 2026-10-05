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

jtt_apps_reflection_output="$(run_hook "jtt-appsにふり返りを依頼" "/Users/shintaro/Herd/jtt-apps")"
grep -q "handover preflight:" <<< "$jtt_apps_reflection_output" \
  || fail "jtt-appsのふり返りで preflight が出ない: $jtt_apps_reflection_output"
grep -q "scope: jtt-apps/root" <<< "$jtt_apps_reflection_output" \
  || fail "jtt-appsのscopeが出ない: $jtt_apps_reflection_output"
assert_claude_memory_path "$jtt_apps_reflection_output" "Herd-jtt-apps"

jtt_apps_hiragana_reflection_output="$(run_hook "jtt-appsのふりかえりをお願い" "/Users/shintaro/Herd/jtt-apps")"
grep -q "scope: jtt-apps/root" <<< "$jtt_apps_hiragana_reflection_output" \
  || fail "jtt-appsのひらがなふりかえりでscopeが出ない: $jtt_apps_hiragana_reflection_output"

# cwd が別 PJ のとき、プロンプトの PJ 名は scope を上書きしない（#3302）
jtt_apps_from_hub_output="$(run_hook "jtt-appsにふり返りを依頼" "$REPO_ROOT")"
if is_agent_hub_source_repo; then
  assert_exact_scope "$jtt_apps_from_hub_output" "AGENT-HUB/root"
  grep -q "cwd と本文の PJ が食い違う" <<< "$jtt_apps_from_hub_output" \
    || fail "cwd と本文の食い違い警告が出ない: $jtt_apps_from_hub_output"
fi

jtt_cms_reflection_output="$(run_hook "ふり返りをお願い" "/Users/shintaro/LLM-Dev/jtt-cms")"
grep -q "handover preflight:" <<< "$jtt_cms_reflection_output" \
  || fail "jtt-cmsのふり返りで preflight が出ない: $jtt_cms_reflection_output"
grep -q "scope: jtt-cms/root" <<< "$jtt_cms_reflection_output" \
  || fail "jtt-cmsのscopeが出ない: $jtt_cms_reflection_output"
assert_scoped_path "$jtt_cms_reflection_output" "handovers"
assert_claude_memory_path "$jtt_cms_reflection_output" "LLM-Dev-jtt-cms"

# [2026-10-02][test] #3302: 終了整理プロンプト本文の PJ 名が cwd を上書きしない。
# 実害: jtt-cms worktree で「業務PJ（jtt-cafe-pj など）」と書くと
# scope=jtt-cafe-pj/root になり、生きている引き継ぎを取り違える。
jtt_cms_prompt_conflict_output="$(run_hook "業務PJ（jtt-cafe-pj など）の終了整理をして" "/Users/shintaro/orca/workspaces/jtt-cms/harlequin")"
assert_exact_scope "$jtt_cms_prompt_conflict_output" "jtt-cms/root"
assert_scoped_path "$jtt_cms_prompt_conflict_output" "handovers"
assert_claude_memory_path "$jtt_cms_prompt_conflict_output" "LLM-Dev-jtt-cms"
grep -q "cwd と本文の PJ が食い違う" <<< "$jtt_cms_prompt_conflict_output" \
  || fail "プロンプト PJ 名との食い違い警告が出ない: $jtt_cms_prompt_conflict_output"
grep -q "prompt=jtt-cafe-pj/root" <<< "$jtt_cms_prompt_conflict_output" \
  || fail "警告に本文側 PJ が出ない: $jtt_cms_prompt_conflict_output"
grep -vq "scope: jtt-cafe-pj/root" <<< "$jtt_cms_prompt_conflict_output" \
  || fail "本文の jtt-cafe-pj で scope が上書きされた: $jtt_cms_prompt_conflict_output"

# 同一 PJ 内のアプリ別名は、従来どおり prompt で scope を絞ってよい
jtt_system_alias_output="$(run_hook "評価わんこの続き" "/Users/shintaro/jtt-system")"
assert_exact_scope "$jtt_system_alias_output" "jtt-system/hyoka-wanko"

jtt_system_reflection_output="$(run_hook "ふり返りをお願い" "/Users/shintaro/jtt-system")"
grep -q "scope: jtt-system/root" <<< "$jtt_system_reflection_output" \
  || fail "jtt-systemのscopeが出ない: $jtt_system_reflection_output"

# [2026-08-05][test] mac-mini-server 配下の repo が non-pj へ落ちないことを固定する。
# 正本 resolve-handover-path.py の MAC_MINI_REPOS と同じ解決になることを回帰で守る
# （closeout で preflight だけ non-pj/root を出し、handover が別 scope へ書かれかけた）。
CANONICAL_RESOLVER="$REPO_ROOT/skills/handover-manual/scripts/resolve-handover-path.py"
# [2026-10-04][fix] 配布先では正本スキルが .claude/skills に配置される。
# HUB と同じ resolver で比較し、参照切れを空の期待値として扱わない。
# 他案不採用: HUB専用パス固定では配布先で参照切れになり、テストの省略では回帰を守れない。
if [ ! -f "$CANONICAL_RESOLVER" ]; then
  CANONICAL_RESOLVER="$REPO_ROOT/.claude/skills/handover-manual/scripts/resolve-handover-path.py"
fi
# [2026-10-04][fix] skill未選択の配布先では上の2参照先が存在しない。
# hookに同梱した同じ正本で検査する。skillを強制追加したり、検査を省略する案は採らない。
if [ ! -f "$CANONICAL_RESOLVER" ]; then
  CANONICAL_RESOLVER="$SCRIPT_DIR/../lib/resolve-handover-path.py"
fi
[ -f "$CANONICAL_RESOLVER" ] || fail "正本 resolver が見つからない: $CANONICAL_RESOLVER"
resolver_scope() {
  # hook は CLAUDE_PROJECT_DIR を Path.resolve() してから正本へ渡す
  # （mac-mini-server/* には mcp-servers への symlink があり、解決前後で project が変わる）。
  # 比較は hook が正本へ渡すのと同じ正規化済み cwd で行う。
  local resolved_cwd
  resolved_cwd="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")"
  python3 "$CANONICAL_RESOLVER" scope --cwd "$resolved_cwd" --prompt "$2" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["project"] + "/" + d["scope"])'
}
for mm_repo in register sales analytics keiei-dashboard cron-dashboard; do
  mm_output="$(run_hook "作業終了。終了整理して" "/Users/shintaro/mac-mini-server/$mm_repo")"
  assert_exact_scope "$mm_output" "$mm_repo/root"
  assert_scoped_path "$mm_output" "handovers"
done

# [2026-10-04][test] #1501: hook と正本 resolver が同じ scope を返すことを
# mac-mini-server 配下の実在 repo 全件で回帰する（二重管理の再発検知）。
for mm_dir in /Users/shintaro/mac-mini-server/*/; do
  [ -d "$mm_dir" ] || continue
  mm_output="$(run_hook "作業終了。終了整理して" "$mm_dir")"
  assert_exact_scope "$mm_output" "$(resolver_scope "$mm_dir" "作業終了。終了整理して")"
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

# [2026-10-03][test] #1479: non-pj へ落ちた時は「cwd から PJ を特定できなかった」旨を出す。
# preflight を信じて書くと個人コンテキストの current.md を汚染するため黙らせない。
non_pj_output="$(run_hook "作業終了。終了整理して" "/private/tmp/handover-preflight-non-pj-cwd")"
assert_exact_scope "$non_pj_output" "non-pj/root"
grep -q "cwd から PJ を特定できませんでした" <<< "$non_pj_output" \
  || fail "non-pj 落下時の警告が出ない: $non_pj_output"

# [2026-10-03][test] #1479: scope 解決は正本 resolve-handover-path.py へ委譲する。
# 内蔵判定が non-pj と返す mcp-servers 配下でも、正本経由なら mcp-servers/<repo> になる。
if is_agent_hub_source_repo && [ -d "/Users/shintaro/mcp-servers/jtt-smaregi-mcp" ]; then
  resolver_delegated_output="$(printf '{"user_prompt": "作業終了。終了整理して"}' | \
    HANDOVER_RESOLVER_PATH="$REPO_ROOT/skills/handover-manual/scripts/resolve-handover-path.py" \
    CLAUDE_PROJECT_DIR="/Users/shintaro/mcp-servers/jtt-smaregi-mcp" bash "$HOOK")"
  assert_exact_scope "$resolver_delegated_output" "mcp-servers/jtt-smaregi-mcp"
  grep -q "resolver: " <<< "$resolver_delegated_output" \
    || fail "正本 resolver が使われていない: $resolver_delegated_output"
fi

# [2026-10-04][test] #1501: 正本がどこにも見つからない時は scope を推定せず
# unresolved + warn で黙らない（hook に写像の複製は残さない）。
if is_agent_hub_source_repo; then
  fallback_output="$(printf '{"user_prompt": "作業終了。終了整理して"}' | \
    HANDOVER_RESOLVER_PATH="/nonexistent/resolve-handover-path.py" \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK")"
  assert_exact_scope "$fallback_output" "unresolved/unresolved"
  grep -q "正本 resolve-handover-path.py が見つかりません" <<< "$fallback_output" \
    || fail "正本不在時の警告が出ない: $fallback_output"
fi

# [2026-10-04][test] #1501: skill が配布されていない配布先（PJ 内 skills 無し）でも、
# hook 同梱の ../lib/resolve-handover-path.py で正本と同一の scope 解決ができる。
# mktemp の cwd は PJ マーカーを持たないため正本仕様どおり non-pj/root になる。
dist_sim_dir="$(mktemp -d)"
dist_output="$(run_hook "作業終了。終了整理して" "$dist_sim_dir")"
assert_exact_scope "$dist_output" "non-pj/root"
grep -q "resolver: .*lib/resolve-handover-path.py" <<< "$dist_output" \
  || fail "skill 非配置の配布先で hook 同梱 resolver が使われていない: $dist_output"
rm -rf "$dist_sim_dir"

# [2026-10-04][test] #1501: 配布物どうし（PJ 内 skill 配置 vs hook 同梱）の
# resolver が食い違う時、hook が版ずれを自己申告する。
drift_dir="$(mktemp -d)"
mkdir -p "$drift_dir/.claude/skills/handover-manual/scripts"
cp "$CANONICAL_RESOLVER" "$drift_dir/.claude/skills/handover-manual/scripts/resolve-handover-path.py"
printf '\n# drifted copy\n' >> "$drift_dir/.claude/skills/handover-manual/scripts/resolve-handover-path.py"
drift_output="$(run_hook "作業終了。終了整理して" "$drift_dir")"
grep -q "別候補の resolver と内容が異なります" <<< "$drift_output" \
  || fail "resolver 版ずれの自己申告が出ない: $drift_output"
rm -rf "$drift_dir"

# [2026-10-05][test] #1516: ローカル main が origin/main より遅れている repo では
# 「hook / 条項台帳が古い可能性」の警告を出す（キャッシュ済み ref のみ・network 不要）。
# hook は project_dir を Path.resolve() するので、比較は realpath 済みパスで行う。
stale_dir="$(mktemp -d)"
git -C "$stale_dir" init -b main >/dev/null
git -C "$stale_dir" -c user.email=test@example.com -c user.name=test commit --allow-empty -m v1 >/dev/null
git -C "$stale_dir" -c user.email=test@example.com -c user.name=test commit --allow-empty -m v2 >/dev/null
git -C "$stale_dir" update-ref refs/remotes/origin/main HEAD
git -C "$stale_dir" reset --hard HEAD~1 >/dev/null
stale_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$stale_dir")"
stale_output="$(run_hook "作業終了。終了整理して" "$stale_dir")"
grep -q "warn: ${stale_real} のローカル main は origin/main より 1 コミット遅れています" <<< "$stale_output" \
  || fail "local main 停滞の警告が出ない: $stale_output"
rm -rf "$stale_dir"

# 遅れていない repo では当該パスの警告を出さない
fresh_dir="$(mktemp -d)"
git -C "$fresh_dir" init -b main >/dev/null
git -C "$fresh_dir" -c user.email=test@example.com -c user.name=test commit --allow-empty -m v1 >/dev/null
git -C "$fresh_dir" update-ref refs/remotes/origin/main HEAD
fresh_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$fresh_dir")"
fresh_output="$(run_hook "作業終了。終了整理して" "$fresh_dir")"
if grep -q "warn: ${fresh_real} のローカル" <<< "$fresh_output"; then
  fail "遅れの無い repo で停滞警告が出た: $fresh_output"
fi
rm -rf "$fresh_dir"

echo "PASS: handover-preflight"
