#!/bin/bash

# block-skill-reverse-edit.sh の回帰テスト。
# 模擬 HUB(DISTRIBUTION.yaml + skills/<name> 実体)と模擬 PJ(.claude/skills/<name> が
# HUB 実体への相対symlink)を作り、逆流 deny / 各種許可ケースを検証する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/block-skill-reverse-edit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 模擬 HUB(AGENT-HUB クローン相当) ---
HUB="$TMP/hub"
mkdir -p "$HUB/skills/demo-skill/references" "$HUB/skills/skills-manager"
: >"$HUB/DISTRIBUTION.yaml"
echo "demo" >"$HUB/skills/demo-skill/SKILL.md"
echo "mgr" >"$HUB/skills/skills-manager/SKILL.md"
# HUB 自身の .claude/skills/<name>(skills 実体への相対symlink。bootstrap-skills.py 相当)
mkdir -p "$HUB/.claude/skills"
ln -s ../../skills/demo-skill "$HUB/.claude/skills/demo-skill"

# --- 模擬 PJ(別ルートのプロジェクト) ---
PJ="$TMP/pj"
mkdir -p "$PJ/.claude/skills" "$PJ/src" "$PJ/.agents/skills/ext-skill"
# PJ の .claude/skills/<name> -> HUB の実体への相対symlink(参照一元化)
ln -s ../../../hub/skills/demo-skill "$PJ/.claude/skills/demo-skill"
# スキル名に 'skills' を含むケース(skills-manager)
ln -s ../../../hub/skills/skills-manager "$PJ/.claude/skills/skills-manager"
# PJ_LOCAL_EXCEPTION: 実体コピーのローカルスキル(symlink でない)
mkdir -p "$PJ/.claude/skills/local-skill"
echo "local" >"$PJ/.claude/skills/local-skill/SKILL.md"
# .agents/skills/ 外部管理スキル(DISTRIBUTION.yaml を持たない領域)への symlink
echo "ext" >"$PJ/.agents/skills/ext-skill/SKILL.md"
ln -s ../../.agents/skills/ext-skill "$PJ/.claude/skills/ext-skill"

# --- PJ 自体が DISTRIBUTION.yaml を持つ(別 hub クローン)。HUB の skill を symlink ---
PJCLONE="$TMP/pj-clone"
mkdir -p "$PJCLONE/.claude/skills"
: >"$PJCLONE/DISTRIBUTION.yaml"
ln -s ../../../hub/skills/demo-skill "$PJCLONE/.claude/skills/demo-skill"

# --- 別 hub(hub2, DISTRIBUTION.yaml あり)の skill を指す PJ2 ---
HUB2="$TMP/hub2"
mkdir -p "$HUB2/skills/demo-skill"
: >"$HUB2/DISTRIBUTION.yaml"
echo "demo2" >"$HUB2/skills/demo-skill/SKILL.md"
PJ2="$TMP/pj2"
mkdir -p "$PJ2/.claude/skills"
ln -s ../../../hub2/skills/demo-skill "$PJ2/.claude/skills/demo-skill"

run_hook() {
  # $1=file_path / $2=tool_name(既定 Write) / $3=tool_input のキー(既定 file_path)
  local file_path="$1"
  local tool_name="${2:-Write}"
  local key="${3:-file_path}"
  printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$tool_name" "$key" "$file_path" \
    | bash "$HOOK_PATH"
}

run_hook_no_path() {
  printf '{"tool_name":"Read","tool_input":{}}' | bash "$HOOK_PATH"
}

assert_denied() {
  local output="$1" label="$2"
  # emit_deny_safe は json.dumps(セパレータにスペース)で出力するため空白0/1を許容。
  if ! printf '%s' "$output" | grep -qE '"permissionDecision": ?"deny"'; then
    printf '[FAIL] %s : deny を期待したが:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if ! printf '%s' "$output" | grep -qE '"permissionDecisionReason": ?'; then
    printf '[FAIL] %s : permissionDecisionReason を期待したが:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if printf '%s' "$output" | grep -qE '"reason": ?'; then
    printf '[FAIL] %s : 旧 reason キーが残っている:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_allowed() {
  local output="$1" label="$2"
  if [ -n "$output" ]; then
    printf '[FAIL] %s : allow(無出力) を期待したが:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

echo "1/15 PJ symlink 経由で SKILL.md 編集 -> deny(逆流)"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/SKILL.md")" "pj symlink SKILL.md"

echo "2/15 PJ symlink 経由で新規ファイル作成(未存在) -> deny(逆流)"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/references/new.md")" "pj symlink new file"

echo "3/15 HUB 内で skills/ を直接編集 -> allow(PR運用の本拠地)"
assert_allowed "$(run_hook "$HUB/skills/demo-skill/SKILL.md")" "hub direct skills edit"

echo "4/15 HUB 内で .claude/skills/(自身のsymlink)経由 -> allow(worktree/HUB内)"
assert_allowed "$(run_hook "$HUB/.claude/skills/demo-skill/SKILL.md")" "hub .claude/skills symlink"

echo "5/15 PJ の実体コピースキル(PJ_LOCAL_EXCEPTION) -> allow"
assert_allowed "$(run_hook "$PJ/.claude/skills/local-skill/SKILL.md")" "pj local real skill"

echo "6/15 PJ のソースコード(.claude/skills 外) -> allow"
assert_allowed "$(run_hook "$PJ/src/foo.ts")" "pj source file"

echo "7/15 file_path を持たないツール入力 -> allow(対象外)"
assert_allowed "$(run_hook_no_path)" "no file_path"

echo "8/15 PJ symlink 経由で MultiEdit(file_path キー)の SKILL.md -> deny"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/SKILL.md" MultiEdit)" "pj symlink MultiEdit file_path"

echo "9/15 PJ symlink 経由で Edit 単体 -> deny(matcher Edit カバレッジ)"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/SKILL.md" Edit)" "pj symlink Edit"

echo "10/15 PJ symlink 経由で MultiEdit(path キー) -> deny(実ペイロード形式)"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/SKILL.md" MultiEdit path)" "pj symlink MultiEdit path-key"

echo "11/15 PJ symlink 経由で多段ネスト(references/api/v2/schema.md) -> deny"
assert_denied "$(run_hook "$PJ/.claude/skills/demo-skill/references/api/v2/schema.md")" "pj symlink deep nest"

echo "12/15 PJ 自体が DISTRIBUTION.yaml を持つ(別hubクローン)が HUB の skill を symlink -> deny"
assert_denied "$(run_hook "$PJCLONE/.claude/skills/demo-skill/SKILL.md")" "pj-clone with own DISTRIBUTION.yaml"

echo "13/15 別 hub(hub2)の skill を指す PJ2 symlink -> deny(multi-hub)"
assert_denied "$(run_hook "$PJ2/.claude/skills/demo-skill/SKILL.md")" "pj2 -> hub2 symlink"

echo "14/15 .agents/skills/ 外部管理スキル(DISTRIBUTION.yaml なし) -> allow"
assert_allowed "$(run_hook "$PJ/.claude/skills/ext-skill/SKILL.md")" "pj .agents external skill"

echo "15/15 スキル名に 'skills' を含む(skills-manager) symlink 経由 -> deny"
assert_denied "$(run_hook "$PJ/.claude/skills/skills-manager/SKILL.md")" "pj symlink skills-manager"

echo "block-skill-reverse-edit hook tests passed (15 cases)"
