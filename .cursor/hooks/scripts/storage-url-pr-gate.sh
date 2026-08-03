#!/bin/bash

# [2026-03-03][refactor]
# 背景: hook-libraryコンポーネント化。PreToolUseでPR作成前にStorage URL全件検証。
# 対応: jtt-cms storage-url-pr-gate.sh をポート。lib/hook-io.sh + lib/storage-url-common.py を使用。
#
# [2026-03-04][fix]
# 背景: ユーザー意図は「PR作成前ゲートが環境差で無効化されず、常に同じ判定になること」。
#   業務ルールとして、セキュリティ/品質ゲートは fail-open（失敗時素通り）を禁止する。
#   代替案として `origin/main` 固定 + `|| true` を維持すると、
#   ブランチ構成差やremote未設定時に検査がスキップされるため不採用。
# 対応: ベースブランチ解決を動的化し、diff取得や検査失敗時は明示denyに変更。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

resolve_base_ref() {
  local cwd="$1"

  # 1) origin/HEAD を優先
  local remote_head
  remote_head="$(git -C "$cwd" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$remote_head" ]; then
    echo "${remote_head#refs/remotes/}"
    return 0
  fi

  # 2) origin/main または origin/master
  if git -C "$cwd" rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "origin/main"
    return 0
  fi
  if git -C "$cwd" rev-parse --verify origin/master >/dev/null 2>&1; then
    echo "origin/master"
    return 0
  fi

  # 3) 最後のフォールバック: ローカル main/master
  if git -C "$cwd" rev-parse --verify main >/dev/null 2>&1; then
    echo "main"
    return 0
  fi
  if git -C "$cwd" rev-parse --verify master >/dev/null 2>&1; then
    echo "master"
    return 0
  fi

  return 1
}

read_stdin
COMMAND=$(extract_field command)

# [2026-05-27][fix] issue #201
# 背景:
#   ユーザー依頼意図: `gh  pr create`（複数空白）や `gh --repo owner/repo pr create` のように
#     gh のグローバルオプション付き呼び出しが固定文字列 `gh pr create` に一致せず
#     fail-open（ゲートをスルー）する脆弱性を修正したい。
#   守るべき業務ルール: セキュリティ/品質ゲートは fail-open 禁止（2026-03-04 CaD と同型）。
#   他案不採用理由:
#     1) `grep -qF "gh pr create"` を維持しつつ空白を `[[:space:]]*` に変えるだけ → 長形式オプション
#        (--repo, --base 等) を見逃すため不採用。
#     2) コマンド全体を解析する案 → shlex が必要で bash のみより複雑。正規表現の方が保守しやすい。
#   対応: grep -qE で gh のグローバルオプション（短形式 -R / 長形式 --repo 等）と複数空白を許容する正規表現に変更。
#   [2026-05-27][fix] review follow-up:
#     --repo / -R のように値を別トークンで取るグローバルオプションも消費する。値なしオプションだけを
#     許容する旧パターンでは `gh --repo owner/repo pr create` が early exit して fail-open するため不採用。
#   [2026-05-28][fix] issue #210 / v3.5.6 regression fix:
#     gh が許容する連結形式 `-Rowner/repo`（値を別トークンにせず短縮形へ glue）も消費する。
#     #201/#213 hardening で `-R[^[:space:]]+` 分岐が脱落し、`gh -Rowner/repo pr create` が
#     GH_GLOBAL_OPTS にマッチせず early exit → storage URL gate を fail-open する退化が入っていた。
#     `-[A-Za-z]+` 分岐は `-Rowner/repo` の `/` で止まるため連結 repo 値を消費できない。実機検証で
#     gh は `-Rowner/repo` を受理するため（git の連結 `-C/path` は逆に弾かれる）、本分岐の復活が必須。
readonly GH_GLOBAL_OPTS='([[:space:]]+((-R|--repo|--hostname)[[:space:]]+[^[:space:]]+|-R[^[:space:]]+|--repo=[^[:space:]]+|--hostname=[^[:space:]]+|-[A-Za-z]+|--[A-Za-z0-9_-]+))*'
if ! echo "$COMMAND" | grep -qE "gh${GH_GLOBAL_OPTS}[[:space:]]+pr[[:space:]]+create"; then
  exit 0
fi

CWD=$(extract_field cwd)
if [ -z "$CWD" ]; then
  CWD="."
fi

BASE_REF=""
if ! BASE_REF="$(resolve_base_ref "$CWD")"; then
  emit_deny "[hook:storage-url-pr-gate] 比較対象ブランチ（origin/HEAD, main, master）を解決できません。ベースブランチを取得してから再実行してください。"
fi

set +e
CHANGED_FILES=$(git -C "$CWD" diff --name-only --diff-filter=ACMR "$BASE_REF"...HEAD 2>/dev/null)
DIFF_STATUS=$?
set -e

if [ "$DIFF_STATUS" -ne 0 ]; then
  emit_deny "[hook:storage-url-pr-gate] 変更ファイル差分の取得に失敗しました（base: $BASE_REF）。リポジトリ状態を確認してください。"
fi

if [ -z "$CHANGED_FILES" ]; then
  exit 0
fi

MIGRATION_FILES=$(echo "$CHANGED_FILES" | grep -E '^supabase/migrations/.*\.sql$' || true)
if [ -z "$MIGRATION_FILES" ]; then
  exit 0
fi

FILE_ARGS=()
while IFS= read -r mf; do
  FILE_ARGS+=("$CWD/$mf")
done <<< "$MIGRATION_FILES"

set +e
DENY_REASON=$(python3 "$SCRIPT_DIR/../lib/storage-url-common.py" gate "${FILE_ARGS[@]}" 2>/dev/null)
GATE_STATUS=$?
set -e

if [ "$GATE_STATUS" -eq 0 ]; then
  exit 0
fi

if [ "$GATE_STATUS" -eq 1 ] && [ -n "$DENY_REASON" ]; then
  emit_deny "$DENY_REASON"
fi

emit_deny "[hook:storage-url-pr-gate] Storage URL検証処理でエラーが発生しました。ログを確認して再実行してください。"
