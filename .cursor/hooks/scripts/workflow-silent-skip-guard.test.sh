#!/usr/bin/env bash

# [2026-10-09][feat] Issue #1988: workflow-silent-skip-guard.sh の回帰テスト。
# asana-call-guard.test.sh と同じ流儀（bash + python3 で payload を組み立て、
# permissionDecision の有無を検査）。

# [2026-10-21][fix]: 編集前から有った該当パターンで無関係な編集まで止めない回帰テスト（7, 16-21）。
# 新規に持ち込む編集は従来どおり deny する（17-21）。背景は workflow-silent-skip-guard.sh 冒頭の CaD。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/workflow-silent-skip-guard.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

run_hook() {
  local payload="$1"
  printf '%s' "$payload" | bash "$HOOK_PATH"
}

# tool_name / tool_input を python で直接組み立てる（内容はファイルから読む）。
# 使い方: payload_write <tool> <file_path> <content-file>
#         payload_tool <tool> <json-of-tool_input>
payload_write() {
  WF_FILE_PATH="$1" WF_CONTENT_FILE="$2" python3 - <<'PY'
import json
import os

file_path = os.environ["WF_FILE_PATH"]
with open(os.environ["WF_CONTENT_FILE"], encoding="utf-8") as f:
    content = f.read()
print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": file_path, "content": content}}), end="")
PY
}

payload_tool() {
  local tool_name="$1"
  local tool_input_json="$2"
  python3 - "$tool_name" "$tool_input_json" <<'PY'
import json
import sys

tool_name = sys.argv[1]
tool_input = json.loads(sys.argv[2]) if sys.argv[2] else {}
print(json.dumps({"tool_name": tool_name, "tool_input": tool_input}), end="")
PY
}

# Edit / MultiEdit の payload を python で組み立てる（エスケープ事故を避ける）。
# 使い方: payload_edit <file_path> <old> <new>
#         payload_multiedit <file_path> <old1> <new1> <old2> <new2>
payload_edit() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], "old_string": sys.argv[2], "new_string": sys.argv[3]}}), end="")
PY
}

payload_multiedit() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys

edits = [
    {"old_string": sys.argv[2], "new_string": sys.argv[3]},
    {"old_string": sys.argv[4], "new_string": sys.argv[5]},
]
print(json.dumps({"tool_name": "MultiEdit", "tool_input": {"file_path": sys.argv[1], "edits": edits}}), end="")
PY
}

assert_denied() {
  local output="$1"
  if ! printf '%s' "$output" | grep -q '"permissionDecision":"deny"'; then
    printf 'Expected deny but got:\n%s\n' "$output" >&2
    exit 1
  fi
}

assert_allowed() {
  local output="$1"
  if [ -n "$output" ]; then
    printf 'Expected allow but got:\n%s\n' "$output" >&2
    exit 1
  fi
}

WORKFLOW_PATH="$TMP_ROOT/.github/workflows/deploy-production.yml"
mkdir -p "$(dirname "$WORKFLOW_PATH")"

# 反パターン: available=false を出力し、後続を outputs.available == 'true' で skip、fail 経路なし
cat > "$TMP_ROOT/silent-skip.yml" <<'YML'
name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Check SSH secrets availability
        id: check-secrets
        env:
          SSH_KEY: ${{ secrets.SAKURA_VPS_SSH_KEY }}
        run: |
          if [ -n "$SSH_KEY" ]; then
            echo "available=true" >> "$GITHUB_OUTPUT"
          else
            echo "available=false" >> "$GITHUB_OUTPUT"
            echo "SAKURA_VPS_SSH_KEY が未設定のためスキップします"
          fi
      - name: Setup SSH
        if: steps.check-secrets.outputs.available == 'true'
        run: echo "setup"
      - name: Deploy
        if: steps.check-secrets.outputs.available == 'true'
        run: echo "deploy"
YML

# fail-closed 版: 不足分岐で exit 1
cat > "$TMP_ROOT/fail-closed.yml" <<'YML'
name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Check Supabase prerequisites
        run: |
          if [ -z "$TOKEN" ]; then
            echo "::error::settings missing"
            exit 1
          fi
      - uses: actions/checkout@v4
      - run: echo "deploy"
YML

# available 出力を使うが、不足時に専用 fail ステップで落とす版
cat > "$TMP_ROOT/fail-step.yml" <<'YML'
name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Check SSH secrets availability
        id: check-secrets
        run: |
          if [ -n "$SSH_KEY" ]; then
            echo "available=true" >> "$GITHUB_OUTPUT"
          else
            echo "available=false" >> "$GITHUB_OUTPUT"
          fi
      - name: Fail if unavailable
        if: steps.check-secrets.outputs.available != 'true'
        run: exit 1
      - name: Deploy
        if: steps.check-secrets.outputs.available == 'true'
        run: echo "deploy"
YML

# emit 後ろの同じ else 分岐に exit 1 がある版
cat > "$TMP_ROOT/emit-with-exit.yml" <<'YML'
name: deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - id: check-secrets
        run: |
          if [ -n "$SSH_KEY" ]; then
            echo "available=true" >> "$GITHUB_OUTPUT"
          else
            echo "available=false" >> "$GITHUB_OUTPUT"
            echo "::error::SAKURA_VPS_SSH_KEY 未設定"
            exit 1
          fi
      - if: steps.check-secrets.outputs.available == 'true'
        run: echo "deploy"
YML

cat > "$TMP_ROOT/no-gate.yml" <<'YML'
name: w
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "available=false" >> "$GITHUB_OUTPUT"
YML

cat > "$TMP_ROOT/alt-name.yml" <<'YML'
name: w
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - id: chk
        run: |
          echo "has_secrets=false" >> "$GITHUB_OUTPUT"
      - if: steps.chk.outputs.has_secrets == 'true'
        run: echo x
YML

echo "1/21 Write: 反パターン workflow -> deny"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/silent-skip.yml")"
output="$(run_hook "$p")"
assert_denied "$output"
printf '%s' "$output" | grep -q 'Issue #1988' || { printf 'deny 理由に Issue #1988 が無い: %s\n' "$output" >&2; exit 1; }

echo "2/21 Write: fail-closed 版（check で exit 1・出力なし）-> allow"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/fail-closed.yml")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "3/21 Write: != true の fail ステップ付き -> allow"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/fail-step.yml")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "4/21 Write: emit 後の else 内に exit 1 -> allow"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/emit-with-exit.yml")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "5/21 Write: workflow 以外のパスなら反パターンでも対象外 -> allow"
p="$(payload_write "$TMP_ROOT/deploy.yml" "$TMP_ROOT/silent-skip.yml")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "6/21 Write: emit はあるが gate が無い（出力未使用）-> allow"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/no-gate.yml")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "7/21 Edit: 編集前から反パターンがあるファイルへの無関係な編集 -> allow（誤検知の修正・旧仕様は deny）"
cp "$TMP_ROOT/silent-skip.yml" "$WORKFLOW_PATH"
p="$(payload_tool "Edit" "{\"file_path\":\"$WORKFLOW_PATH\",\"old_string\":\"Setup SSH\",\"new_string\":\"Setup SSH v2\"}")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "8/21 Edit: emit 行を消す修正なら -> allow"
p="$(payload_tool "Edit" "{\"file_path\":\"$WORKFLOW_PATH\",\"old_string\":\"echo \\\"available=false\\\" >> \\\"\$GITHUB_OUTPUT\\\"\",\"new_string\":\"exit 1\"}")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "9/21 Bash: heredoc で反パターン workflow を生成 -> deny"
cat > "$TMP_ROOT/heredoc.txt" <<'TXT'
cat > .github/workflows/x.yml <<'EOF'
      - run: |
          echo "available=false" >> "$GITHUB_OUTPUT"
      - if: steps.c.outputs.available == 'true'
        run: echo x
EOF
TXT
p="$(BASH_CMD_FILE="$TMP_ROOT/heredoc.txt" python3 - <<'PY'
import json
import os

with open(os.environ["BASH_CMD_FILE"], encoding="utf-8") as f:
    cmd = f.read()
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}), end="")
PY
)"
output="$(run_hook "$p")"
assert_denied "$output"

echo "10/21 Bash: workflow 非言及のコマンド -> allow"
p="$(payload_tool "Bash" '{"command":"ls -la && echo done"}')"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "11/21 apply_patch: 反パターン追加 -> deny"
cat > "$TMP_ROOT/patch-add.txt" <<'TXT'
*** Begin Patch
*** Update File: .github/workflows/x.yml
@@
+      - run: |
+          echo "available=false" >> "$GITHUB_OUTPUT"
+      - if: steps.c.outputs.available == 'true'
+        run: echo x
*** End Patch
TXT
p="$(BASH_CMD_FILE="$TMP_ROOT/patch-add.txt" python3 - <<'PY'
import json
import os

with open(os.environ["BASH_CMD_FILE"], encoding="utf-8") as f:
    patch = f.read()
print(json.dumps({"tool_name": "Bash", "tool_input": {"patch": patch}}), end="")
PY
)"
output="$(run_hook "$p")"
assert_denied "$output"

echo "12/21 apply_patch: 反パターン削除（修正）-> allow"
cat > "$TMP_ROOT/patch-remove.txt" <<'TXT'
*** Begin Patch
*** Update File: .github/workflows/x.yml
@@
-          echo "available=false" >> "$GITHUB_OUTPUT"
+          exit 1
*** End Patch
TXT
p="$(BASH_CMD_FILE="$TMP_ROOT/patch-remove.txt" python3 - <<'PY'
import json
import os

with open(os.environ["BASH_CMD_FILE"], encoding="utf-8") as f:
    patch = f.read()
print(json.dumps({"tool_name": "Bash", "tool_input": {"patch": patch}}), end="")
PY
)"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "13/21 別名の出力（has_secrets=false）でも -> deny"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/alt-name.yml")"
output="$(run_hook "$p")"
assert_denied "$output"

echo "14/21 AGENT_HUB_ALLOW_WORKFLOW_SILENT_SKIP_GUARD=1 -> allow（バイパス）"
p="$(payload_write "$WORKFLOW_PATH" "$TMP_ROOT/silent-skip.yml")"
output="$(AGENT_HUB_ALLOW_WORKFLOW_SILENT_SKIP_GUARD=1 run_hook "$p")"
assert_allowed "$output"

echo "15/21 壊れた入力 -> allow（fail-open）"
output="$(run_hook 'not-json-at-all')"
assert_allowed "$output"

echo "16/21 MultiEdit: 編集前から反パターンがあるファイルへの無関係な 2 箇所編集 -> allow"
cp "$TMP_ROOT/silent-skip.yml" "$WORKFLOW_PATH"
p="$(payload_multiedit "$WORKFLOW_PATH" "name: deploy" "name: deploy v2" "Setup SSH" "Setup SSH v2")"
output="$(run_hook "$p")"
assert_allowed "$output"

echo "17/21 Edit: 反パターンの無いファイルへ該当パターンを新規に足す -> deny（検知は弱めない）"
cp "$TMP_ROOT/fail-closed.yml" "$WORKFLOW_PATH"
new_block='run: |
          echo "available=false" >> "$GITHUB_OUTPUT"
      - if: steps.c.outputs.available == '"'"'true'"'"'
        run: echo x'
p="$(payload_edit "$WORKFLOW_PATH" 'run: echo "deploy"' "$new_block")"
output="$(run_hook "$p")"
assert_denied "$output"
printf '%s' "$output" | grep -q 'available=false' || { printf '17: deny 理由に available が無い: %s\n' "$output" >&2; exit 1; }

echo "18/21 Edit: 既存パターン(available)があるファイルへ別名(has_secrets)を新規に足す -> deny（新しい名前だけ報告）"
cp "$TMP_ROOT/silent-skip.yml" "$WORKFLOW_PATH"
new_block='run: |
          echo "has_secrets=false" >> "$GITHUB_OUTPUT"
      - if: steps.c.outputs.has_secrets == '"'"'true'"'"'
        run: echo x'
p="$(payload_edit "$WORKFLOW_PATH" 'run: echo "deploy"' "$new_block")"
output="$(run_hook "$p")"
assert_denied "$output"
printf '%s' "$output" | grep -q 'has_secrets=false' || { printf '18: deny 理由に has_secrets が無い: %s\n' "$output" >&2; exit 1; }
if printf '%s' "$output" | grep -q 'available=false'; then
  printf '18: 編集前から有った available まで報告している: %s\n' "$output" >&2
  exit 1
fi

echo "19/21 MultiEdit: 既存パターンがあるファイルで 1 箇所は無関係・1 箇所は別名を新規に足す -> deny"
cp "$TMP_ROOT/silent-skip.yml" "$WORKFLOW_PATH"
p="$(payload_multiedit "$WORKFLOW_PATH" "name: deploy" "name: deploy v2" 'run: echo "deploy"' "$new_block")"
output="$(run_hook "$p")"
assert_denied "$output"
printf '%s' "$output" | grep -q 'has_secrets=false' || { printf '19: deny 理由に has_secrets が無い: %s\n' "$output" >&2; exit 1; }

echo "20/21 Edit: fail 経路を壊して既存の安全な名前を新規に offender 化する -> deny"
cp "$TMP_ROOT/fail-step.yml" "$WORKFLOW_PATH"
p="$(payload_edit "$WORKFLOW_PATH" "run: exit 1" "run: echo skipped")"
output="$(run_hook "$p")"
assert_denied "$output"

echo "21/21 Edit: 編集前ファイルが無い（新規作成相当）で該当パターンを持ち込む -> deny（従来どおり）"
MISSING_PATH="$TMP_ROOT/.github/workflows/not-yet-created.yml"
rm -f "$MISSING_PATH"
new_block='run: |
          echo "available=false" >> "$GITHUB_OUTPUT"
      - if: steps.c.outputs.available == '"'"'true'"'"'
        run: echo x'
p="$(payload_edit "$MISSING_PATH" "" "$new_block")"
output="$(run_hook "$p")"
assert_denied "$output"

echo "all workflow-silent-skip-guard tests passed"
