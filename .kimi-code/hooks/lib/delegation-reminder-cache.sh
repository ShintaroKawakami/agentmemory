#!/bin/bash
# [2026-08-13][fix]
# 背景:
#   - ユーザー依頼意図: Closeout Debt #1701。`.claude/hooks/.delegation-reminder-cache/` が
#     セッション用マーカーをリポ内に書き、tracked ではないのに `git status` を dirty にする。
#   - 守るべき業務ルール: reminder / backstop / fable-guard のスロットル機能は維持する。
#     closeout の dirty チェックを偽陽性にしない。
#   - 他案不採用理由: PJ ごとの `.gitignore` 追記だけに頼る案は、配布漏れで hermes 等に
#     再発するため不採用。キャッシュ正本をリポ外へ移す。
# 対応: XDG cache（または DELEGATION_REMINDER_CACHE_DIR 上書き）へ集約する共通関数。

resolve_delegation_reminder_cache_dir() {
  local project_dir="${1:-}"
  if [ -n "${DELEGATION_REMINDER_CACHE_DIR:-}" ]; then
    printf '%s\n' "$DELEGATION_REMINDER_CACHE_DIR"
    return 0
  fi

  local key=""
  if command -v shasum >/dev/null 2>&1; then
    key="$(printf '%s' "$project_dir" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    key="$(printf '%s' "$project_dir" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
  if [ -z "$key" ]; then
    key="fallback"
  fi

  local root="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/agent-hub/hooks/delegation-reminder"
  printf '%s\n' "${root}/${key}"
}
