#!/bin/bash

# [2026-03-03][feat]
# 背景: 77スキル中2つだけ日付マーカーあり。サブエージェントはコピー時スナップショット。
#   手動チェックは現実的に不可能なため、SessionStart hookで毎セッション自動検出が必要。
#   staleness_check.sh（skill-organizer）は手動実行のみだった。skill-audit は 2026-07-13 に
#   正式スキル化（skills/skill-audit/）し、単一スキルの契約遵守を三値判定する。
# 対応: SessionStart hookで軽量鮮度チェックを実行。
#   (1) hookバージョン差分 (2) スキル鮮度 (3) 依存バージョン乖離を検出。
#
# [2026-03-04][fix]
# 背景: ユーザー意図は「鮮度チェックが安全に動作し、監査時に迂回経路を残さないこと」。
#   業務ルールとして、フック内で外部入力（ファイルパス）をコード文字列に直埋めしてはならない。
#   代替案としてPythonワンライナーへパスを直接埋め込む実装を維持すると、
#   特殊文字を含むパスで任意コード実行に繋がるため不採用。
# 対応: Python呼び出しを引数渡しへ変更し、文字列埋め込みを廃止。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."

extract_last_verified() {
  local skill_md="$1"
  python3 - "$skill_md" <<'PY' 2>/dev/null || true
import re
import sys
from pathlib import Path

skill_path = Path(sys.argv[1])
try:
    text = skill_path.read_text(encoding='utf-8')
except Exception:
    print('')
    raise SystemExit(0)

m = re.search(r'last_verified:\s*(\d{4}-\d{2}-\d{2})', text)
print(m.group(1) if m else '')
PY
}

extract_interval_days() {
  local skill_md="$1"
  python3 - "$skill_md" <<'PY' 2>/dev/null || echo "60"
import re
import sys
from pathlib import Path

skill_path = Path(sys.argv[1])
try:
    text = skill_path.read_text(encoding='utf-8')
except Exception:
    print('60')
    raise SystemExit(0)

m = re.search(r'interval_days:\s*(\d+)', text)
print(m.group(1) if m else '60')
PY
}

# --- hookバージョンチェック ---
check_hook_version() {
  local version_file="$HOOKS_DIR/.hook-library-version"
  local agent_hub_version_file

  # AGENT-HUBのパスを環境変数またはデフォルトから取得
  local agent_hub_path="${AGENT_HUB_PATH:-$HOME/business/AGENT-HUB}"
  agent_hub_version_file="$agent_hub_path/hook-library/VERSION"

  if [ ! -f "$version_file" ]; then
    echo "  - hook-library: バージョン情報なし（未デプロイ or 旧形式）" >&2
    return
  fi

  local deployed_version
  deployed_version="$(head -1 "$version_file" | sed 's/^v//' | cut -d' ' -f1)"

  if [ -f "$agent_hub_version_file" ]; then
    local latest_version
    latest_version="$(cat "$agent_hub_version_file" | tr -d '[:space:]')"

    if [ "$deployed_version" != "$latest_version" ]; then
      echo "  - hook-library: v${latest_version} が利用可能です（現在 v${deployed_version}）" >&2
    fi
  fi
}

# --- スキル鮮度チェック ---
check_skill_freshness() {
  local skills_dir

  # CLAUDE_PROJECT_DIR が設定されていればそのプロジェクトのスキルをチェック
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    skills_dir="$CLAUDE_PROJECT_DIR/.claude/skills"
  else
    skills_dir="$(pwd)/.claude/skills"
  fi

  if [ ! -d "$skills_dir" ]; then
    return
  fi

  local today_epoch
  today_epoch=$(date +%s)
  local stale_skills=""

  # 各スキルのSKILL.mdからlast_verifiedを抽出
  for skill_dir in "$skills_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_md="$skill_dir/SKILL.md"
    [ -f "$skill_md" ] || continue

    local skill_name
    skill_name="$(basename "$skill_dir")"

    local last_verified
    last_verified="$(extract_last_verified "$skill_md")"

    if [ -z "$last_verified" ]; then
      continue  # last_verified未設定のスキルはスキップ（Phase 2で順次追加）
    fi

    # 経過日数を計算
    local verified_epoch
    verified_epoch=$(date -j -f "%Y-%m-%d" "$last_verified" +%s 2>/dev/null || date -d "$last_verified" +%s 2>/dev/null || echo "0")

    if [ "$verified_epoch" = "0" ]; then
      continue
    fi

    local days_ago=$(( (today_epoch - verified_epoch) / 86400 ))

    # freshness_check.interval_days を取得（デフォルト60日）
    local interval
    interval="$(extract_interval_days "$skill_md")"

    if [ "$days_ago" -gt "$interval" ]; then
      stale_skills="$stale_skills\n  - ${skill_name}: ${days_ago}日前（閾値: ${interval}日）"
    fi
  done

  if [ -n "$stale_skills" ]; then
    echo -e "  スキル鮮度:$stale_skills" >&2
  fi
}

# [2026-05-21][feat] / [2026-05-25][refactor]
# 背景:
# - ユーザー依頼意図: 大原則 A「PWAを消して再登録は絶対にしない」と大原則 B「ネイティブアプリ模倣」の
#   SSOT 文書が欠落している場合に、SessionStart 時に警告して AI セッションへ必読を促す。
#   2026-05-25: jtt-apps ローカル限定だった本チェックを hook-library 正本へ upstream
#   （/insights deep-check の --diff で「full deploy 時に jtt-apps から消える」ローカル限定実装と判明したため）。
# - 守るべき業務ルール: SessionStart hook は常に exit 0（ブロックしない、情報提供のみ）。
#   hook-library は複数 PJ で共有されるため、PWA プロジェクト（public/sw.js または public/manifest.json を持つ）
#   でのみ発火し、非 PWA PJ（jtt-cms 等）では誤警告させない。
# - 他案不採用理由:
#   1) Stop hook で AI 最終出力を grep する案は false positive リスクが高すぎる
#      （正当な「キャッシュクリア」言及まで誤ブロック）ため不採用。
#   2) jtt-apps 限定の無条件チェックのまま据え置く案は、full deploy で hook-library 版に巻き戻り
#      check_pwa_principles が消えるため不採用（2026-05-25 の deploy --diff で検出）。
#   3) 無条件で全 PJ に配布する案は、PWA を持たない PJ で毎セッション誤警告を出すため不採用。
#      PWA 検出ゲートで発火対象を PWA PJ に限定する。
# 対応: PWA 検出（public/sw.js または public/manifest.json）でゲートし、検出時のみ
#   PWA_OPERATION_PRINCIPLE.md / PWA_NATIVE_APP_PARITY_RULE.md の存在を確認。メッセージは PJ 非依存化。
# --- PWA 大原則 SSOT 存在確認（PWA プロジェクトのみ） ---
check_pwa_principles() {
  local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

  # PWA プロジェクト判定: service worker または manifest を持つ場合のみ発火（非 PWA PJ では誤爆させない）
  if [ ! -f "$project_dir/public/sw.js" ] && [ ! -f "$project_dir/public/manifest.json" ]; then
    return
  fi

  local pwa_op_principle="$project_dir/.claude/rules/general/PWA_OPERATION_PRINCIPLE.md"
  local pwa_parity_rule="$project_dir/.claude/rules/general/PWA_NATIVE_APP_PARITY_RULE.md"

  if [ ! -f "$pwa_op_principle" ]; then
    echo "  ⚠️  PWA_OPERATION_PRINCIPLE.md (.claude/rules/general/) が存在しません。PWA 運用大原則 A (「PWAを消して再登録は絶対にしない」) の SSOT が欠落しています。" >&2
  fi

  if [ ! -f "$pwa_parity_rule" ]; then
    echo "  ⚠️  PWA_NATIVE_APP_PARITY_RULE.md (.claude/rules/general/) が存在しません。PWA 大原則 B (「ネイティブアプリ模倣」) の SSOT が欠落しています。" >&2
  fi
}

# [2026-08-02][feat] ローカル main の behind をセッション開始時に警告する（issue #1327）。
# 背景:
#   - ユーザー依頼意図: セッション開始時のシステムプロンプトにはローカルの git log が載るため、
#     AI が「最新」と誤認して古いベースにコミットを積み、push 拒否 → worktree 作り直し →
#     幽霊 hook 誤爆（#1230 と重複）の手戻り連鎖が実測された（2026-08-02 jtt-cafe-pj）。
#     `git fetch` を1回打っていれば全て回避できたため、SessionStart で機械化する。
#   - 守るべき業務ルール: 警告のみで block しない（SessionStart は情報提供・常に exit 0）。
#     オフライン・認証不能・遅延時は fail-open（既存チェックと同じ精神）。
#     macOS 標準に GNU timeout が無いため bg + poll + kill で上限を実装し、
#     GIT_TERMINAL_PROMPT=0 / ssh BatchMode で認証プロンプトの hang を封じる。
#   - 他案不採用理由: PreToolUse（add/commit 時）検知の案 B は、警告が作業途中に割り込み
#     ベース選択の時点（worktree 作成）に間に合わない。システムプロンプト側への ahead/behind
#     併記（案 C）は Claude Code 本体の変更で当方から変更不能。
check_main_behind() {
  local repo_root behind fetch_pid waited
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  git -C "$repo_root" rev-parse --verify -q refs/heads/main >/dev/null 2>&1 || return 0
  git -C "$repo_root" remote get-url origin >/dev/null 2>&1 || return 0
  (
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=3"
    exec git -C "$repo_root" fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
  ) >/dev/null 2>&1 &
  fetch_pid=$!
  waited=0
  while kill -0 "$fetch_pid" 2>/dev/null; do
    if [ "$waited" -ge 50 ]; then
      # 5秒（0.1s x 50）で fetch を打ち切り fail-open（オフライン・低速回線）
      kill "$fetch_pid" 2>/dev/null || true
      wait "$fetch_pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$fetch_pid" 2>/dev/null || return 0
  behind="$(git -C "$repo_root" rev-list --count main..origin/main 2>/dev/null)" || return 0
  case "$behind" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$behind" -gt 0 ]; then
    echo "  ⚠ ローカル main が origin/main より ${behind} コミット遅れています（fetch 実行済み）。" >&2
    echo "    冒頭の Recent commits はローカル基準です。古いベースへのコミットを避けるため、" >&2
    echo "    worktree / branch は origin/main から作成してください。" >&2
  fi
  return 0
}

# --- メイン実行 ---
main() {
  local warnings=""

  # 一時ファイルで警告を収集
  local tmp_file
  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  check_hook_version 2>"$tmp_file"
  warnings="$(cat "$tmp_file")"

  check_skill_freshness 2>"$tmp_file"
  warnings="$warnings$(cat "$tmp_file")"

  check_pwa_principles 2>"$tmp_file"
  warnings="$warnings$(cat "$tmp_file")"

  check_main_behind 2>"$tmp_file"
  warnings="$warnings$(cat "$tmp_file")"

  if [ -n "$warnings" ]; then
    echo "" >&2
    echo "🔍 [freshness-gate] 鮮度チェック結果:" >&2
    echo "$warnings" >&2
    echo "" >&2
    echo "  詳細: skills/skill-audit の audit_skill.py または staleness_check.sh で確認してください" >&2
    echo "" >&2
  fi

  # SessionStart hookは常にexit 0（ブロックしない、情報提供のみ）
  exit 0
}

main
