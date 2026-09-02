#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/block-unauthorized-docs-file.sh"
TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "$TMP_PROJECT"' EXIT
mkdir -p "$TMP_PROJECT/docs/prd" "$TMP_PROJECT/docs/architecture" "$TMP_PROJECT/apps/demo/docs/prd"
: >"$TMP_PROJECT/docs/prd/prd-active.md"
: >"$TMP_PROJECT/docs/.ssot-allowlist"
run_raw() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"; }
json_payload() { python3 - "$@" <<'PY2'
import json, sys
mode, patch = sys.argv[1], sys.argv[2]
if mode == "tool_input": data = {"tool_name":"apply_patch", "tool_input":{"patch":patch}}
elif mode == "tool_input_command": data = {"tool_name":"apply_patch", "tool_input":{"command":patch}}
elif mode == "arguments_string": data = {"tool_name":"apply_patch", "arguments":patch}
elif mode == "arguments_object": data = {"tool_name":"apply_patch", "arguments":{"patch":patch}}
else: raise SystemExit(mode)
print(json.dumps(data), end="")
PY2
}
run_json() { json_payload "$1" "$2" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"; }
run_hook() {
  local tool_name="$1" command="$2" payload
  payload=$(python3 - "$tool_name" "$command" "$TMP_PROJECT" <<'PY2'
import json,sys
print(json.dumps({'tool_name':sys.argv[1], 'tool_input':{'command':sys.argv[2], 'cwd':sys.argv[3]}}), end='')
PY2
)
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK_PATH"
}
PYTHON_ONLY_BIN="$TMP_PROJECT/python-only"; mkdir -p "$PYTHON_ONLY_BIN"
for utility in python3 dirname cat; do ln -s "$(command -v "$utility")" "$PYTHON_ONLY_BIN/$utility"; done
run_python_fallback_hook() { printf '%s' "$1" | PATH="$PYTHON_ONLY_BIN" CLAUDE_PROJECT_DIR="$TMP_PROJECT" /bin/bash "$HOOK_PATH"; }
run_json_python() { json_payload "$1" "$2" | PATH="$PYTHON_ONLY_BIN" CLAUDE_PROJECT_DIR="$TMP_PROJECT" /bin/bash "$HOOK_PATH"; }
assert_allowed() { [ -z "$1" ] || { printf '[FAIL] %s expected allow, got: %s\n' "$2" "$1" >&2; exit 1; }; }
assert_denied() { OUT="$1" python3 - <<'PY2'
import json, os, sys
try: payload=json.loads(os.environ["OUT"])["hookSpecificOutput"]
except Exception: sys.exit(1)
sys.exit(0 if payload.get("permissionDecision") == "deny" and payload.get("permissionDecisionReason") else 1)
PY2
  [ $? -eq 0 ] || { printf '[FAIL] %s expected deny, got: %s\n' "$2" "$1" >&2; exit 1; }; }
RAW_ALLOWED=$'*** Begin Patch\n*** Update File: docs/prd/prd-active.md\n@@\n+updated\n*** End Patch'
RAW_DOC_CREATE=$'*** Begin Patch\n*** Add File: docs/architecture/new-design.md\n+new\n*** End Patch'
RAW_ALLOWLIST_UPDATE=$'*** Begin Patch\n*** Update File: docs/.ssot-allowlist\n@@\n+architecture/new-design.md\n*** End Patch'
RAW_ALLOWLIST_ADD=$'*** Begin Patch\n*** Add File: docs/.ssot-allowlist\n+entry\n*** End Patch'
RAW_ALLOWLIST_DELETE=$'*** Begin Patch\n*** Delete File: docs/.ssot-allowlist\n*** End Patch'
RAW_ALLOWLIST_MOVE=$'*** Begin Patch\n*** Update File: docs/prd/prd-active.md\n*** Move to: docs/.ssot-allowlist\n@@\n-old\n+new\n*** End Patch'
assert_allowed "$(run_raw "$RAW_ALLOWED")" "raw allowed existing docs update"
assert_allowed "$(run_raw "$RAW_DOC_CREATE")" "raw ordinary docs creation"
assert_denied "$(run_raw "$RAW_ALLOWLIST_UPDATE")" "raw allowlist update"
assert_denied "$(run_raw "$RAW_ALLOWLIST_ADD")" "raw allowlist add"
assert_denied "$(run_raw "$RAW_ALLOWLIST_DELETE")" "raw allowlist delete"
assert_denied "$(run_raw "$RAW_ALLOWLIST_MOVE")" "raw allowlist move"
assert_allowed "$(run_raw 'ordinary non-json text')" "arbitrary raw text is not apply_patch"
assert_denied "$(run_raw $'*** Begin Patch\n*** End Patch')" "recognized malformed raw patch"
for route in tool_input tool_input_command arguments_string arguments_object; do
 assert_allowed "$(run_json "$route" "$RAW_ALLOWED")" "JSON $route preserves allowed update"
 assert_denied "$(run_json "$route" "$RAW_ALLOWLIST_UPDATE")" "JSON $route protects allowlist"
done
assert_denied "$(run_json tool_input_command 'ordinary command text')" "arbitrary command is not a patch"
for route in tool_input tool_input_command arguments_string arguments_object; do
 assert_allowed "$(run_json_python "$route" "$RAW_ALLOWED")" "Python fallback $route preserves allowed update"
 assert_denied "$(run_json_python "$route" "$RAW_ALLOWLIST_UPDATE")" "Python fallback $route protects allowlist"
done
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
python3 - "$ROOT/hook-library/settings/block-unauthorized-docs-file.json" "$ROOT/hook-library/settings-codex/block-unauthorized-docs-file.json" <<'PY2'
import json, sys
for path in sys.argv[1:]:
 data=json.load(open(path, encoding='utf-8')); hooks=data.get('PreToolUse', [])
 assert hooks and 'block-unauthorized-docs-file.sh' in hooks[0]['hooks'][0]['command'], path
PY2

# Every patch operation is checked on every JSON route, not only Update.
RAW_ALLOWLIST_ADD=$'*** Begin Patch\n*** Add File: docs/.ssot-allowlist\n+entry\n*** End Patch'
RAW_ALLOWLIST_DELETE=$'*** Begin Patch\n*** Delete File: docs/.ssot-allowlist\n*** End Patch'
RAW_ALLOWLIST_MOVE=$'*** Begin Patch\n*** Update File: docs/prd/prd-active.md\n*** Move to: docs/.ssot-allowlist\n@@\n-old\n+new\n*** End Patch'
for route in tool_input tool_input_command arguments_string arguments_object; do
  assert_allowed "$(run_json "$route" "$RAW_DOC_CREATE")" "JSON $route ordinary docs create"
  for patch in "$RAW_ALLOWLIST_ADD" "$RAW_ALLOWLIST_DELETE" "$RAW_ALLOWLIST_MOVE"; do
    assert_denied "$(run_json "$route" "$patch")" "JSON $route allowlist operation"
  done
done
# Raw transport has the same result without Node, via Python fallback.
assert_allowed "$(run_python_fallback_hook "$RAW_ALLOWED")" "Python fallback raw ordinary update"
assert_allowed "$(run_python_fallback_hook "$RAW_DOC_CREATE")" "Python fallback raw ordinary docs create"
for patch in "$RAW_ALLOWLIST_ADD" "$RAW_ALLOWLIST_UPDATE" "$RAW_ALLOWLIST_DELETE" "$RAW_ALLOWLIST_MOVE"; do
  assert_denied "$(run_python_fallback_hook "$patch")" "Python fallback raw allowlist operation"
done
# Shell operations that alter the protected file are denied; normal docs still pass.
for command in 'rm docs/.ssot-allowlist' 'mv docs/.ssot-allowlist tmp' 'mv tmp docs/.ssot-allowlist' 'mv -t tmp docs/.ssot-allowlist' 'mv --target-directory=tmp docs/.ssot-allowlist' ': > docs/.ssot-allowlist' 'truncate -s 0 docs/.ssot-allowlist' 'cp tmp docs/.ssot-allowlist' 'install tmp docs/.ssot-allowlist'; do
  assert_denied "$(run_hook Bash "$command")" "Bash protected allowlist: $command"
done
assert_allowed "$(run_hook Bash 'touch docs/architecture/ordinary.md')" "Bash ordinary docs create"
# Exercise both runtime materializations, not just their configuration strings.
for runtime in .claude .codex; do
  mkdir -p "$TMP_PROJECT/$runtime/hooks/scripts" "$TMP_PROJECT/$runtime/hooks/lib"
  cp "$HOOK_PATH" "$TMP_PROJECT/$runtime/hooks/scripts/block-unauthorized-docs-file.sh"
  cp "$SCRIPT_DIR/../lib/hook-io.sh" "$TMP_PROJECT/$runtime/hooks/lib/hook-io.sh"
  assert_allowed "$(printf '%s' "$RAW_ALLOWED" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$TMP_PROJECT/$runtime/hooks/scripts/block-unauthorized-docs-file.sh")" "$runtime materialized ordinary docs"
  assert_denied "$(printf '%s' "$RAW_ALLOWLIST_UPDATE" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$TMP_PROJECT/$runtime/hooks/scripts/block-unauthorized-docs-file.sh")" "$runtime materialized allowlist"
done

printf '%s\n' 'block-unauthorized-docs-file hook tests passed'
