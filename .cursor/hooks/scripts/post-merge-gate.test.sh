#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/post-merge-gate.sh"
PASS=0
FAIL=0

run_hook() {
  local command="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$command")" | bash "$SCRIPT"
}

run_shell_hook() {
  local command="$1"
  printf '{"tool_name":"Shell","tool_input":{"command":%s}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$command")" | bash "$SCRIPT"
}

expect_block() {
  local name="$1"
  local command="$2"
  local out
  out="$(run_hook "$command" 2>&1)"
  if OUT="$out" python3 - <<'PY'
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
if "[hook:post-merge-gate]" not in payload.get("permissionDecisionReason", ""):
    sys.exit(1)
PY
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_allow() {
  local name="$1"
  local command="$2"
  local out
  out="$(run_hook "$command" 2>&1)"
  if printf '%s' "$out" | grep -q '"continue":true'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_shell_block() {
  local name="$1"
  local command="$2"
  local out
  out="$(run_shell_hook "$command" 2>&1)"
  if OUT="$out" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUT"])
payload = data.get("hookSpecificOutput", {})
if payload.get("permissionDecision") != "deny":
    sys.exit(1)
PY
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_block "direct gh pr merge" "gh pr merge 123 --squash --delete-branch"
expect_block "repo option gh pr merge" "gh --repo owner/repo pr merge 123 --squash"
expect_block "short repo option gh pr merge" "gh -Rowner/repo pr merge 123"
expect_block "pr-level repo option gh pr merge" "gh pr --repo owner/repo merge 123"
expect_block "pr-level short repo option gh pr merge" "gh pr -Rowner/repo merge 123"
expect_block "command prefix gh pr merge" "command gh pr merge 123"
expect_block "shell nested gh pr merge" "bash -lc 'gh pr merge 123 --squash'"
expect_block "wrapper mention does not bypass direct merge" "echo merge-pr.py && gh pr merge 123 --squash"
expect_block "if statement gh pr merge" "if gh pr merge 123 --squash; then echo ok; fi"
expect_block "while statement gh pr merge" "while gh pr merge 123; do break; done"
expect_block "eval gh pr merge" "eval \"gh pr merge 123 --squash\""
expect_block "backtick gh pr merge" "echo \`gh pr merge 123\`"
expect_block "quoted dollar subshell gh pr merge" "echo \"\$(gh pr merge 123)\""
expect_block "double-quoted single-quote dollar subshell bypass" "echo \"'\$(gh pr merge 123)'\""
expect_block "double-quoted single-quote backtick bypass" "echo \"'\`gh pr merge 123\`'\""
expect_block "pipe through xargs gh pr merge" "printf '123\\n' | xargs gh pr merge"
expect_block "xargs with options gh pr merge" "xargs -n1 gh pr merge <<<123"
expect_block "macOS xargs replacement gh pr merge" "xargs -J % gh pr merge % <<<123"
expect_block "macOS xargs size gh pr merge" "xargs -S 255 gh pr merge <<<123"
expect_block "macOS xargs replacements gh pr merge" "xargs -R 1 gh pr merge <<<123"
expect_block "GNU xargs delimiter gh pr merge" "printf '123\\n' | xargs -d '\\n' gh pr merge"
expect_block "newline separated gh pr merge" $'printf ok\ngh pr merge 123'
expect_block "shell generated gh pr merge" "bash -c \"\$(printf 'gh pr merge 123')\""
expect_block "find exec gh pr merge" "find . -exec gh pr merge 123 {} \\;"
expect_block "xargs shell nested gh pr merge" "printf '123\\n' | xargs sh -c 'gh pr merge \"\$0\"'"
expect_block "find shell nested gh pr merge" "find . -exec sh -c 'gh pr merge 123' \\;"
expect_block "variable command gh pr merge" "GH=gh; \"\$GH\" pr merge 123"
expect_block "default parameter expansion gh pr merge" 'GH=gh; "${GH:-gh}" pr merge 123'
expect_block "error parameter expansion gh pr merge" 'GH=gh; "${GH?err}" pr merge 123'
expect_block "command substitution gh pr merge" '$(printf gh) pr merge 123'
expect_block "nohup gh pr merge" "nohup gh pr merge 123"
expect_block "setsid gh pr merge" "setsid -f gh pr merge 123"
expect_block "nice gh pr merge" "nice -n 5 gh pr merge 123"
expect_shell_block "Shell tool gh pr merge" "gh pr merge 123"

expect_allow "pr view allowed" "gh pr view 123"
expect_allow "wrapper allowed" "python3 ~/business/AGENT-HUB/skills/post-merge/scripts/merge-pr.py 123 --confirm-read"
expect_allow "text mention allowed" "echo 'gh pr merge 123 should use wrapper'"
expect_allow "single quoted dollar subshell text allowed" "echo '\$(gh pr merge 123)'"
expect_allow "single quoted backtick text allowed" "echo '\`gh pr merge 123\`'"

# [2026-07-31][test] Issue #1105: deny メッセージが回避策を案内することを固定する。
#   実測の結果、ブロックされるのは二重引用符内の backtick / $()（bash が実際に実行する形＝真陽性）だけで、
#   単一引用符・素のテキスト・--body-file は上の expect_allow 群のとおり通る。よって判定ロジックは変えず、
#   「なぜ止まったか・どう書けば通るか」を案内するメッセージだけを追加した。その回帰を固定する。
expect_deny_message_contains() {
  local name="$1"
  local command="$2"
  local needle="$3"
  local out
  out="$(run_hook "$command" 2>&1)"
  if OUT="$out" NEEDLE="$needle" python3 - <<'PYCHECK'
import json
import os
import sys

try:
    data = json.loads(os.environ["OUT"])
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)
reason = data.get("hookSpecificOutput", {}).get("permissionDecisionReason", "")
sys.exit(0 if os.environ["NEEDLE"] in reason else 1)
PYCHECK
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_deny_message_contains "deny message points at --body-file workaround" "gh pr merge 123" "--body-file"
expect_deny_message_contains "deny message explains single quotes" "gh pr merge 123" "単一引用符"
expect_deny_message_contains "deny message still points at the wrapper" "gh pr merge 123" "merge-pr.py"

printf 'post-merge-gate tests: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
