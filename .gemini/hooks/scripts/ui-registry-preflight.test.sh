#!/usr/bin/env bash

# [2026-10-11][feat] ui-registry-preflight.sh の回帰テスト（JTT共通UIレジストリ・P4）。
# workflow-silent-skip-guard.test.sh / asana-call-guard.test.sh と同じ流儀
# （bash + python3 で payload を組み立て、出力の有無と exit 0 を検査）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/ui-registry-preflight.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"
export CLAUDE_PROJECT_DIR="$PROJ"
export UI_REGISTRY_PREFLIGHT_CACHE_DIR="$TMP_ROOT/cache"
export HOOK_LIB_DIR="$SCRIPT_DIR/../lib"

payload() {
  WF_FILE_PATH="$1" WF_SESSION="$2" python3 - <<'PY'
import json
import os

payload = {
    "tool_name": "Write",
    "tool_input": {"file_path": os.environ["WF_FILE_PATH"], "content": "x"},
}
session = os.environ.get("WF_SESSION")
if session:
    payload["session_id"] = session
print(json.dumps(payload), end="")
PY
}

run_hook() {
  local file_path="$1" session="${2:-}"
  payload "$file_path" "$session" | bash "$HOOK_PATH"
}

assert_quiet() {
  local output="$1" label="$2"
  if [ -n "$output" ]; then
    printf 'FAIL: expected quiet but got output (%s):\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_shown() {
  local output="$1" label="$2"
  if ! printf '%s' "$output" | grep -q "部品さがし"; then
    printf 'FAIL: expected 部品さがし message (%s) but got:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

echo "1/10 Write: 新しい画面部品（components/Badge.tsx・未作成）-> 案内が出る"
out="$(run_hook "$PROJ/src/components/Badge.tsx" "session-a")"
assert_shown "$out" "new component"

echo "2/10 Write: 同じセッションの2回目 -> 黙る"
out="$(run_hook "$PROJ/src/components/Card.tsx" "session-a")"
assert_quiet "$out" "second time same session"

echo "3/10 Write: 別セッション -> また出る"
out="$(run_hook "$PROJ/src/components/Card.tsx" "session-b")"
assert_shown "$out" "other session"

echo "4/10 Write: 既存ファイル -> 黙る"
existing="$PROJ/src/components/Existing.tsx"
mkdir -p "$(dirname "$existing")" && printf 'export const x = 1\n' > "$existing"
out="$(run_hook "$existing" "session-c")"
assert_quiet "$out" "existing file"

echo "5/10 Write: 画面部品ではないファイル（scripts/deploy.sh・README.md）-> 黙る"
out="$(run_hook "$PROJ/scripts/deploy.sh" "session-d")"
assert_quiet "$out" "shell script"
out="$(run_hook "$PROJ/docs/README.md" "session-d")"
assert_quiet "$out" "markdown"

echo "6/10 Write: テスト・stories・型定義は外す -> 黙る"
out="$(run_hook "$PROJ/src/components/Badge.test.tsx" "session-e")"
assert_quiet "$out" "test file"
out="$(run_hook "$PROJ/src/components/Badge.stories.tsx" "session-e")"
assert_quiet "$out" "stories file"
out="$(run_hook "$PROJ/src/components/types.d.ts" "session-e")"
assert_quiet "$out" "d.ts file"

echo "7/10 Write: session_id が無くても出る（止めない）"
out="$(run_hook "$PROJ/src/hooks/useFoo.ts" "")"
assert_shown "$out" "no session id"

echo "8/10 Write: file_path なし・壊れた入力 -> 黙って exit 0"
out="$(printf '%s' '{"tool_name":"Write","tool_input":{}}' | bash "$HOOK_PATH")"
assert_quiet "$out" "no file_path"
out="$(printf '%s' 'not json' | bash "$HOOK_PATH")"
assert_quiet "$out" "broken input"

echo "9/10 Write: hooks ディレクトリ直下の新規ファイル -> 出る"
out="$(run_hook "$PROJ/packages/ui/src/hooks/useKeyboardInset.ts" "session-f")"
assert_shown "$out" "hooks dir"

echo "10/10 Write: 他のセッションのマーカーは別セッションを黙らせない"
out="$(run_hook "$PROJ/src/components/Modal.tsx" "session-g")"
assert_shown "$out" "fresh session"

echo "OK: ui-registry-preflight.test.sh"
