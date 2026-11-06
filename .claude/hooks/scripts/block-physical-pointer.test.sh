#!/usr/bin/env bash
# [2026-11-02][test] block-physical-pointer.sh の判定表。
# ask（確認を出す）/ deny（確認が出せない動かし方で止める）/ pass（何も出さず exit 0）を固定する。
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/block-physical-pointer.sh"
PASS=0
FAIL=0

# payload 生成: tool_name / tool_input の command（空なら tool_input は {}）/ permission_mode
mk_payload() {
  python3 -c '
import json, sys
tool_name, command, mode = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"tool_name": tool_name, "tool_input": {"command": command} if command else {}}
if mode:
    data["permission_mode"] = mode
print(json.dumps(data, ensure_ascii=False))
' "$1" "$2" "$3"
}

# 判定: $1=名前 $2=期待(ask|deny|pass) $3=payload $4=環境変数の前置き（任意, 例 "BLOCK_PHYSICAL_POINTER_FORCE_DENY=1"）
expect_decision() {
  local name="$1"
  local expect="$2"
  local payload="$3"
  local envset="${4:-}"
  local out rc
  if [ -n "$envset" ]; then
    out="$(printf '%s' "$payload" | env "$envset" bash "$SCRIPT" 2>&1)" || true
    printf '%s' "$payload" | env "$envset" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
  else
    out="$(printf '%s' "$payload" | bash "$SCRIPT" 2>&1)" || true
    printf '%s' "$payload" | bash "$SCRIPT" >/dev/null 2>&1; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] %s: exit %s (%s)\n' "$name" "$rc" "$out"
    FAIL=$((FAIL + 1))
    return
  fi
  if OUT="$out" EXPECT="$expect" python3 - <<'PY'
import json
import os
import sys

out = os.environ["OUT"]
expect = os.environ["EXPECT"]
if expect == "pass":
    sys.exit(0 if out.strip() == "" else 1)

try:
    data = json.loads(out)
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)

payload = data.get("hookSpecificOutput", {})
if payload.get("hookEventName") != "PreToolUse":
    sys.exit(1)
if payload.get("permissionDecision") != expect:
    sys.exit(1)
if not payload.get("permissionDecisionReason", "").strip():
    sys.exit(1)
if "reason" in payload:
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

# --- ask: 確認を出す（通常モード） ---
expect_decision "computer-use left_click default -> ask" ask \
  "$(mk_payload mcp__computer-use__left_click "" default)"
expect_decision "remote-devices computer_screenshot default -> ask" ask \
  "$(mk_payload mcp__remote-devices__computer_screenshot "" default)"
expect_decision "agent-desktop click --headed default -> ask" ask \
  "$(mk_payload Bash "agent-desktop click @e3 --headed" default)"
expect_decision "npx agent-desktop snapshot --headed default -> ask" ask \
  "$(mk_payload Bash "npx agent-desktop snapshot --headed" default)"
expect_decision "agent-desktop after cd && default -> ask" ask \
  "$(mk_payload Bash "cd /tmp && agent-desktop click @e3 --headed" default)"
expect_decision "bash -c quoted agent-desktop --headed default -> ask" ask \
  "$(mk_payload Bash "bash -c \"agent-desktop click @e3 --headed\"" default)"
expect_decision "bash -c unquoted agent-desktop --headed default -> ask" ask \
  "$(mk_payload Bash "bash -c agent-desktop click @e3 --headed" default)"
expect_decision "agent-desktop --headed without permission_mode -> ask" ask \
  "$(mk_payload Bash "agent-desktop click @e3 --headed" "")"

# --- deny: 確認が出せない動かし方（bypassPermissions / dontAsk / Codex 強制） ---
expect_decision "computer-use left_click bypassPermissions -> deny" deny \
  "$(mk_payload mcp__computer-use__left_click "" bypassPermissions)"
expect_decision "computer-use left_click dontAsk -> deny" deny \
  "$(mk_payload mcp__computer-use__left_click "" dontAsk)"
expect_decision "remote-devices computer_screenshot dontAsk -> deny" deny \
  "$(mk_payload mcp__remote-devices__computer_screenshot "" dontAsk)"
expect_decision "agent-desktop click --headed bypassPermissions -> deny" deny \
  "$(mk_payload Bash "agent-desktop click @e3 --headed" bypassPermissions)"
expect_decision "agent-desktop click --headed dontAsk -> deny" deny \
  "$(mk_payload Bash "agent-desktop click @e3 --headed" dontAsk)"
expect_decision "FORCE_DENY=1 agent-desktop --headed default -> deny" deny \
  "$(mk_payload Bash "agent-desktop click @e3 --headed" default)" \
  "BLOCK_PHYSICAL_POINTER_FORCE_DENY=1"
expect_decision "FORCE_DENY=1 computer-use default -> deny" deny \
  "$(mk_payload mcp__computer-use__left_click "" default)" \
  "BLOCK_PHYSICAL_POINTER_FORCE_DENY=1"
# [2026-11-02] Codex レビュー指摘: Kimi の Shell 経路と echo <(...) のすり抜け
expect_decision "Shell agent-desktop --headed default -> ask" ask \
  "$(mk_payload Shell "agent-desktop click @e3 --headed" default)"
expect_decision "FORCE_DENY=1 Shell agent-desktop --headed -> deny" deny \
  "$(mk_payload Shell "agent-desktop click @e3 --headed" default)" \
  "BLOCK_PHYSICAL_POINTER_FORCE_DENY=1"
expect_decision "echo <(agent-desktop --headed) default -> ask" ask \
  "$(mk_payload Bash "echo <(agent-desktop click @e3 --headed)" default)"
expect_decision "FORCE_DENY=1 echo >(agent-desktop --headed) -> deny" deny \
  "$(mk_payload Bash "echo >(agent-desktop click @e3 --headed)" default)" \
  "BLOCK_PHYSICAL_POINTER_FORCE_DENY=1"

# --- pass: カーソルを動かさない道具・文字列は何も出さない ---
expect_decision "kimi-cu click passes" pass \
  "$(mk_payload mcp__kimi-cu__click "" default)"
expect_decision "kimi-cu click bypassPermissions passes" pass \
  "$(mk_payload mcp__kimi-cu__click "" bypassPermissions)"
expect_decision "kimi-webbridge navigate passes" pass \
  "$(mk_payload mcp__kimi-webbridge__navigate "" default)"
expect_decision "agent-desktop click without --headed passes" pass \
  "$(mk_payload Bash "agent-desktop click @e3" default)"
expect_decision "playwright test --headed passes" pass \
  "$(mk_payload Bash "npx playwright test --headed" default)"
expect_decision "echo of agent-desktop --headed text passes" pass \
  "$(mk_payload Bash "echo \"--headed agent-desktop の説明\"" default)"
expect_decision "agent-desktop-like word with --headed passes" pass \
  "$(mk_payload Bash "my-agent-desktop-tool --headed" default)"
expect_decision "non-target Bash passes" pass \
  "$(mk_payload Bash "git status" default)"
expect_decision "unrelated mcp tool passes" pass \
  "$(mk_payload mcp__plugin_chrome-devtools-mcp_chrome-devtools__click "" default)"
expect_decision "broken JSON passes (exit 0, no output)" pass \
  '{not json'
expect_decision "empty stdin passes (exit 0, no output)" pass ""

# --- 設定断片が JSON として読めること ---
for cfg in \
  "$(cd "$(dirname "$0")/.." && pwd)/settings/block-physical-pointer.json" \
  "$(cd "$(dirname "$0")/.." && pwd)/settings-codex/block-physical-pointer.json"; do
  name="settings JSON loads: $(basename "$(dirname "$cfg")")/$(basename "$cfg")"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$cfg" 2>/dev/null; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
done

TOTAL=$((PASS + FAIL))
printf '\n=== block-physical-pointer.test.sh: %d/%d PASS ===\n' "$PASS" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
