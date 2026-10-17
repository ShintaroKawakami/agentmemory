#!/bin/bash
# [2026-10-17][feat]
# 背景: Supabase CLI が 2.119.0 → 2.121.0 に自動更新され、jtt-cms / jtt-system の
#   native runtime 起動が「2.119.0 完全一致」の版数ピンで止まる状態になった（伸太郎殿承認の恒久対策）。
# 対応: 版数判定を「最低版数以上なら通す」に変え、両 PJ が同じ判定を使えるよう hook-library/lib に一元化。
#   deploy-hooks.py が各 PJ の .claude/hooks/lib/ に配布する（PJ 側は source するだけ。複製実装しない）。
# 不採用案: 各 PJ の worktree-supabase-common.sh に個別実装 → 版数更新時の漏れが再発するため不採用。
#
# Usage:
#   . "$REPO_ROOT/.claude/hooks/lib/supabase-cli-version.sh"
#   supabase_cli_require_min || exit 1          # 既定最低版数で判定
#   supabase_cli_version_at_least 2.121.0 2.119.0  # 純粋比較（0=以上）

: "${SUPABASE_CLI_MIN_VERSION:=2.119.0}"

# supabase_cli_extract_version: "Supabase CLI 2.121.0" 等から X.Y.Z を抜き出す
supabase_cli_extract_version() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# supabase_cli_version_at_least <version> <minimum>: version >= minimum なら 0
supabase_cli_version_at_least() {
  local version="$1" minimum="$2" i a b
  local -a va vb
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$minimum" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a va <<<"$version"
  IFS=. read -r -a vb <<<"$minimum"
  for i in 0 1 2; do
    a=$((10#${va[$i]})); b=$((10#${vb[$i]}))
    if [ "$a" -gt "$b" ]; then return 0; fi
    if [ "$a" -lt "$b" ]; then return 1; fi
  done
  return 0
}

# supabase_cli_installed_version: 導入済み CLI の X.Y.Z（取得不可なら空で 1）
supabase_cli_installed_version() {
  local raw version
  raw="$(supabase --version 2>/dev/null || true)"
  version="$(supabase_cli_extract_version "$raw")"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# supabase_cli_require_min [minimum]: 導入済み CLI が最低版数以上か。未満/不明なら理由を stderr に出して 1
supabase_cli_require_min() {
  local minimum="${1:-$SUPABASE_CLI_MIN_VERSION}" version
  if ! version="$(supabase_cli_installed_version)"; then
    echo "[supabase-cli] Supabase CLI の版数を取得できません（必要: ${minimum} 以上）。" >&2
    return 1
  fi
  if ! supabase_cli_version_at_least "$version" "$minimum"; then
    echo "[supabase-cli] Supabase CLI ${version} は古すぎます（必要: ${minimum} 以上）。brew upgrade supabase で更新してください。" >&2
    return 1
  fi
  return 0
}
