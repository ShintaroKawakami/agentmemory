#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/block-unauthorized-docs-file.sh"

# 一時プロジェクトを作成（docs/ 構造・既存ファイル・allowlist を用意）
TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "$TMP_PROJECT"' EXIT
mkdir -p "$TMP_PROJECT/docs/prd/archives" \
  "$TMP_PROJECT/docs/architecture" \
  "$TMP_PROJECT/docs/operation" \
  "$TMP_PROJECT/docs/benchmark" \
  "$TMP_PROJECT/docs/plan" \
  "$TMP_PROJECT/docs/database" \
  "$TMP_PROJECT/src" \
  "$TMP_PROJECT/apps/koban-neko/docs/business" \
  "$TMP_PROJECT/apps/hyoka-wanko/docs/operation" \
  "$TMP_PROJECT/apps/chie-fukuro/docs/architecture" \
  "$TMP_PROJECT/apps/foo/docs/business"
# 既存ファイル（grandfather 対象）
: >"$TMP_PROJECT/docs/prd/prd-active.md"
: >"$TMP_PROJECT/docs/database/LEGACY_NOTES.md" # baseline 外だが既存 → 更新は許可される想定
# allowlist 台帳（承認済みエントリ）
cat >"$TMP_PROJECT/docs/.ssot-allowlist" <<'EOF'
# 伸太郎殿承認済みの追加 SSOT
operation/INCIDENT_LOG.md
architecture/realtime-*.md
EOF

run_hook() {
  local tool_name="$1"
  local file_path="$2" # 絶対パス推奨
  local payload
  payload=$(python3 - "$tool_name" "$file_path" "$TMP_PROJECT" <<'PY'
import json
import sys
tool_name = sys.argv[1]
file_path = sys.argv[2]
tool_input = {}
if tool_name in {"Bash", "Shell"}:
    tool_input["command"] = file_path
    tool_input["cwd"] = sys.argv[3] if len(sys.argv) > 3 else ""
elif file_path:
    tool_input["file_path"] = file_path
print(json.dumps({"tool_name": tool_name, "tool_input": tool_input}), end="")
PY
)
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"
}

run_hook_raw() {
  local payload="$1"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"
}

run_apply_patch_hook() {
  local patch_text="$1"
  local payload
  payload=$(python3 - "$patch_text" <<'PY'
import json
import sys
print(json.dumps({"tool_name": "apply_patch", "tool_input": {"patch": sys.argv[1]}}), end="")
PY
)
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"
}

assert_denied() {
  local output="$1"
  local label="$2"
  if ! OUT="$output" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["OUT"])
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)
payload = data.get("hookSpecificOutput", {})
if payload.get("hookEventName") != "PreToolUse":
    sys.exit(1)
if payload.get("permissionDecision") != "deny":
    sys.exit(1)
if not payload.get("permissionDecisionReason"):
    sys.exit(1)
if "reason" in payload:
    sys.exit(1)
PY
  then
    printf '[FAIL] %s : deny を期待したが:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_allowed() {
  local output="$1"
  local label="$2"
  if [ -n "$output" ]; then
    printf '[FAIL] %s : allow(無出力) を期待したが:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

D="$TMP_PROJECT/docs"

echo "1/21 prd/ への推測ファイル（next-action.md 新規）-> deny"
assert_denied "$(run_hook Write "$D/prd/next-action.md")" "prd/next-action.md"

echo "2/21 prd/ baseline 固定ファイル（prd-future.md 新規）-> allow"
assert_allowed "$(run_hook Write "$D/prd/prd-future.md")" "prd/prd-future.md"

echo "3/21 既存ファイル（prd-active.md 上書き）-> allow"
assert_allowed "$(run_hook Write "$D/prd/prd-active.md")" "prd/prd-active.md(existing)"

echo "4/21 廃止された plan/ への新規 -> deny（docs/plan/ は廃止・~/.claude/plans へ）"
assert_denied "$(run_hook Write "$D/plan/2026-05-26-next-plan.md")" "plan/next-plan.md"

echo "5/21 prd/archives/ スナップショット新規 -> allow"
assert_allowed "$(run_hook Write "$D/prd/archives/prd-active-2026-05.md")" "prd/archives/snapshot"

echo "6/21 architecture/ baseline 外の新規（new-thing.md）-> deny"
assert_denied "$(run_hook Write "$D/architecture/new-thing.md")" "architecture/new-thing.md"

echo "6a/21 database/ 未承認 root SSOT（NEW_RANDOM.md）-> deny"
assert_denied "$(run_hook Write "$D/database/NEW_RANDOM.md")" "database/NEW_RANDOM.md"

echo "7/21 architecture/ baseline（database-design.md 新規）-> allow"
assert_allowed "$(run_hook Write "$D/architecture/database-design.md")" "architecture/database-design.md"

echo "B1-1 architecture/auth-design.md（条件付きSSOT・不在）-> deny"
assert_denied "$(run_hook Write "$D/architecture/auth-design.md")" "architecture/auth-design.md"

echo "B1-2 operation/PASSWORD_GATES.md（条件付きSSOT・不在）-> deny"
assert_denied "$(run_hook Write "$D/operation/PASSWORD_GATES.md")" "operation/PASSWORD_GATES.md"

echo "B1-3 benchmark/PERFORMANCE_BASELINE.md（条件付きSSOT・不在）-> deny"
assert_denied "$(run_hook Write "$D/benchmark/PERFORMANCE_BASELINE.md")" "benchmark/PERFORMANCE_BASELINE.md"

mkdir -p "$D/benchmark"
: >"$D/architecture/auth-design.md"
: >"$D/operation/PASSWORD_GATES.md"
: >"$D/benchmark/PERFORMANCE_BASELINE.md"

echo "B1-4 architecture/auth-design.md（条件付きSSOT・既存）-> allow"
assert_allowed "$(run_hook Write "$D/architecture/auth-design.md")" "architecture/auth-design.md(existing)"

echo "B1-5 operation/PASSWORD_GATES.md（条件付きSSOT・既存）-> allow"
assert_allowed "$(run_hook Edit "$D/operation/PASSWORD_GATES.md")" "operation/PASSWORD_GATES.md(existing)"

echo "B1-6 benchmark/PERFORMANCE_BASELINE.md（条件付きSSOT・既存）-> allow"
assert_allowed "$(run_hook Write "$D/benchmark/PERFORMANCE_BASELINE.md")" "benchmark/PERFORMANCE_BASELINE.md(existing)"

echo "8/21 docs/ 直下の新規 SSOT（ROADMAP.md）-> deny"
assert_denied "$(run_hook Write "$D/ROADMAP.md")" "docs/ROADMAP.md"

echo "9/21 docs/ 直下 baseline（FEATURE_FLAGS.md 新規）-> allow"
assert_allowed "$(run_hook Write "$D/FEATURE_FLAGS.md")" "docs/FEATURE_FLAGS.md"

echo "9a/21 operation/PERMISSIONS.md（条件付き権限SSOT・不在）-> deny"
assert_denied "$(run_hook Write "$D/operation/PERMISSIONS.md")" "operation/PERMISSIONS.md"

: >"$D/operation/PERMISSIONS.md"
echo "9b/21 operation/PERMISSIONS.md（条件付き権限SSOT・既存）-> allow"
assert_allowed "$(run_hook Edit "$D/operation/PERMISSIONS.md")" "operation/PERMISSIONS.md(existing)"

echo "10/21 docs/ 外（src/foo.ts 新規）-> allow"
assert_allowed "$(run_hook Write "$D/../src/foo.ts")" "src/foo.ts"

echo "11/21 allowlist 完全一致（operation/INCIDENT_LOG.md 新規）-> allow"
assert_allowed "$(run_hook Write "$D/operation/INCIDENT_LOG.md")" "operation/INCIDENT_LOG.md"

echo "12/21 allowlist glob 一致（architecture/realtime-channels.md 新規）-> allow"
assert_allowed "$(run_hook Write "$D/architecture/realtime-channels.md")" "architecture/realtime-channels.md"

echo "13/21 allowlist 台帳の新規/更新 -> deny"
assert_denied "$(run_hook Write "$D/.ssot-allowlist")" "docs/.ssot-allowlist"

echo "13a/21 Kimi MultiEdit で allowlist 編集 -> deny"
assert_denied "$(run_hook MultiEdit "$D/.ssot-allowlist")" "MultiEdit docs/.ssot-allowlist"

echo "13b/21 Kimi 旧 WriteFile で allowlist 編集 -> deny"
assert_denied "$(run_hook WriteFile "$D/.ssot-allowlist")" "WriteFile docs/.ssot-allowlist"

echo "13c/21 Kimi 旧 StrReplaceFile で allowlist 編集 -> deny"
assert_denied "$(run_hook StrReplaceFile "$D/.ssot-allowlist")" "StrReplaceFile docs/.ssot-allowlist"

echo "14/21 未登録 docs/ サブディレクトリへの新規 -> deny"
assert_denied "$(run_hook Write "$D/random/ROADMAP.md")" "docs/random/ROADMAP.md"

echo "15/21 相対パスの既存ファイル更新（hook cwd がPJ外）-> allow"
(cd /tmp && assert_allowed "$(run_hook Write "docs/prd/prd-active.md")" "relative existing path")

echo "16/21 Bash touch で prd/ 推測ファイル新規 -> deny"
assert_denied "$(run_hook Bash "touch docs/prd/bash-next.md")" "bash touch docs/prd/bash-next.md"

echo "17/21 Bash echo で allowlist 編集 -> deny"
assert_denied "$(run_hook Bash "echo architecture/foo.md >> docs/.ssot-allowlist")" "bash allowlist edit"

echo "17a/21 Bash sed -i で allowlist 編集 -> deny"
assert_denied "$(run_hook Bash "sed -i.bak 's/foo/bar/' docs/.ssot-allowlist")" "bash sed allowlist edit"

echo "17b/21 Bash perl -pi で allowlist 編集 -> deny"
assert_denied "$(run_hook Bash "perl -pi -e 's/foo/bar/' docs/.ssot-allowlist")" "bash perl allowlist edit"

echo "17c/21 Bash cp で既存 docs/prd/ ディレクトリへ未承認SSOTコピー -> deny"
assert_denied "$(run_hook Bash "cp tmp-note.md docs/prd/")" "bash cp to docs/prd directory"

echo "17d/21 Bash mv で既存 docs/architecture/ ディレクトリへ未承認SSOT移動 -> deny"
assert_denied "$(run_hook Bash "mv tmp-note.md docs/architecture/")" "bash mv to docs/architecture directory"

echo "17e/21 Bash install で既存 docs/operation/ ディレクトリへ未承認SSOT配置 -> deny"
assert_denied "$(run_hook Bash "install tmp-note.md docs/operation/")" "bash install to docs/operation directory"

mkdir -p "$TMP_PROJECT/tmp"
: >"$TMP_PROJECT/tmp/INCIDENT_LOG.md"
echo "17f/21 Bash install -m 644 で allowlist 済みSSOT配置 -> allow"
assert_allowed "$(run_hook Bash "install -m 644 tmp/INCIDENT_LOG.md docs/operation/")" "bash install mode allowlisted file"

echo "17g/21 Bash install -m 644 で未承認SSOT配置 -> deny"
install_mode_output="$(run_hook Bash "install -m 644 tmp-note.md docs/operation/")"
assert_denied "$install_mode_output" "bash install mode to docs/operation directory"
if printf '%s' "$install_mode_output" | grep -q 'docs/operation/644'; then
  printf '[FAIL] bash install mode option was treated as filename:\n%s\n' "$install_mode_output" >&2
  exit 1
fi

echo "17h/21 Bash cp -t で既存 docs/prd/ ディレクトリへ未承認SSOTコピー -> deny"
assert_denied "$(run_hook Bash "cp -t docs/prd tmp-note.md")" "bash cp -t docs/prd"

echo "17i/21 Bash cp --target-directory= で既存 docs/prd/ ディレクトリへ未承認SSOTコピー -> deny"
assert_denied "$(run_hook Bash "cp --target-directory=docs/prd tmp-note.md")" "bash cp --target-directory docs/prd"

echo "18/21 tool_name=Read（対象外）-> allow"
assert_allowed "$(run_hook Read "$D/prd/next-action.md")" "Read tool"

echo "19/21 作業用ディレクトリ design/ への新規 -> allow（WORK_DIRS は維持）"
assert_allowed "$(run_hook Write "$D/design/new-mockup.md")" "design/new-mockup.md"

echo "20/21 Bash cd 後の prd/ 推測ファイル新規 -> deny"
assert_denied "$(run_hook Bash "cd docs/prd && touch cd-next.md")" "bash cd docs/prd touch"

echo "21/21 Kimi Shell で prd/ 推測ファイル新規 -> deny"
assert_denied "$(run_hook Shell "touch docs/prd/shell-next.md")" "shell touch docs/prd/shell-next.md"

echo "21a/21 Kimi toolInput camelCase で prd/ 推測ファイル新規 -> deny"
assert_denied "$(run_hook_raw '{"toolName":"Shell","toolInput":{"command":"touch docs/prd/kimi-toolinput-next.md","cwd":"'"$TMP_PROJECT"'"}}')" "kimi toolInput shell docs/prd"

# --- R2 誤検知回帰テスト（2026-05-27）: 説明テキスト中の docs/ 言及を作成ターゲットと誤認しない ---
echo "R2-1 gh pr create の --body に docs/plan/ 言及（touch 含む）-> allow"
assert_allowed "$(run_hook Bash 'gh pr create --title x --body "removes docs/plan/ legacy; touch up wording"')" "R2 gh pr create body docs mention"

echo "R2-2 git commit -m に docs/prd/ 言及（> 含む）-> allow"
assert_allowed "$(run_hook Bash 'git commit -m "drop docs/prd/cleanup-notes.md > archive"')" "R2 git commit msg docs mention"

echo "R2-3 実リダイレクトでの docs/ 新規作成は引き続き deny（保護が残っていること）"
assert_denied "$(run_hook Bash "printf hi > docs/architecture/brand-new.md")" "R2 real redirect still denied"

echo "R2-4 数値付きリダイレクトでの docs/ 新規作成 -> deny"
assert_denied "$(run_hook Bash "printf hi 2> docs/architecture/fd-new.md")" "R2 numeric redirect denied"

echo "R2-5 stdout/stderr リダイレクトでの docs/ 新規作成 -> deny"
assert_denied "$(run_hook Bash "printf hi &> docs/architecture/amp-new.md")" "R2 amp redirect denied"

# --- per-app baseline 新命名テスト（2026-06-26） ---
echo "PA-1/7 per-app 新命名 business 許可: apps/koban-neko/docs/business/koban-neko-business-rules.md"
assert_allowed "$(run_hook Write "$TMP_PROJECT/apps/koban-neko/docs/business/koban-neko-business-rules.md")" "per-app business new naming"

echo "PA-2/7 per-app 新命名 operation 許可: apps/hyoka-wanko/docs/operation/hyoka-wanko-operations.md"
assert_allowed "$(run_hook Write "$TMP_PROJECT/apps/hyoka-wanko/docs/operation/hyoka-wanko-operations.md")" "per-app operation new naming"

echo "PA-3/7 per-app 新命名 architecture 許可: apps/chie-fukuro/docs/architecture/chie-fukuro-rag-design.md"
assert_allowed "$(run_hook Write "$TMP_PROJECT/apps/chie-fukuro/docs/architecture/chie-fukuro-rag-design.md")" "per-app architecture new naming"

echo "PA-4/7 per-app prd 既存パターン許可: apps/foo/docs/prd/foo-prd-active.md"
assert_allowed "$(run_hook Write "$TMP_PROJECT/apps/foo/docs/prd/foo-prd-active.md")" "per-app prd pattern"

echo "PA-5/7 per-app 旧 business 命名 grandfather 許可: apps/foo/docs/business/BUSINESS_RULES.md"
assert_allowed "$(run_hook Write "$TMP_PROJECT/apps/foo/docs/business/BUSINESS_RULES.md")" "per-app old business naming grandfather"

echo "PA-6/7 per-app 任意名 docs ファイルはブロック維持: apps/foo/docs/business/random-notes.md"
assert_denied "$(run_hook Write "$TMP_PROJECT/apps/foo/docs/business/random-notes.md")" "per-app arbitrary name blocked"

echo "PA-7/7 per-app app 名不一致はブロック: apps/koban-neko/docs/business/hyoka-wanko-business-rules.md"
assert_denied "$(run_hook Write "$TMP_PROJECT/apps/koban-neko/docs/business/hyoka-wanko-business-rules.md")" "per-app app name mismatch blocked"

# --- Codex apply_patch hook 配線（2026-07-16） ---
echo "CX-1/5 Codex apply_patch で未承認 docs/prd 新規 -> deny"
assert_denied "$(run_apply_patch_hook $'*** Begin Patch\n*** Add File: docs/prd/codex-next.md\n+new\n*** End Patch')" "Codex apply_patch unauthorized docs"

echo "CX-2/5 Codex apply_patch で docs/.ssot-allowlist 更新 -> deny"
assert_denied "$(run_apply_patch_hook $'*** Begin Patch\n*** Update File: docs/.ssot-allowlist\n@@\n+prd/codex-next.md\n*** End Patch')" "Codex apply_patch allowlist self-approval"

echo "CX-3/5 Codex apply_patch で既存 docs/prd 更新 -> allow"
assert_allowed "$(run_apply_patch_hook $'*** Begin Patch\n*** Update File: docs/prd/prd-active.md\n@@\n+updated\n*** End Patch')" "Codex apply_patch existing docs"

echo "CX-4/5 Codex apply_patch で src 新規 -> allow"
assert_allowed "$(run_apply_patch_hook $'*** Begin Patch\n*** Add File: src/codex.ts\n+export {};\n*** End Patch')" "Codex apply_patch non-docs"

echo "CX-5/5 Codex apply_patch の対象欠損 -> deny"
assert_denied "$(run_hook_raw '{"tool_name":"apply_patch","tool_input":{}}')" "Codex apply_patch missing target"

CODEX_HOOKS_JSON="$(cd "$SCRIPT_DIR/../.." && pwd)/hooks.json"
if [ -f "$CODEX_HOOKS_JSON" ]; then
  echo "CX-REG Codex hooks.json で cross-runtime matcher 配線済み -> pass"
  python3 - "$CODEX_HOOKS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    hooks = json.load(handle).get("hooks", {}).get("PreToolUse", [])
expected_tools = {"Bash", "Edit", "MultiEdit", "Shell", "StrReplaceFile", "Write", "WriteFile"}
registered = any(
    expected_tools.issubset(set(entry.get("matcher", "").split("|")))
    and any(
        "block-unauthorized-docs-file.sh" in hook.get("command", "")
        for hook in entry.get("hooks", [])
    )
    for entry in hooks
)
if not registered:
    raise SystemExit("Codex hooks.json lacks the cross-runtime docs guard matcher set")
PY
fi

echo "block-unauthorized-docs-file hook tests passed"
