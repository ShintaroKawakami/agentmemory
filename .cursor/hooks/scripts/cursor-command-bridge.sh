#!/bin/bash
# [2026-07-24][docs]
# 背景:
#   - ユーザー依頼意図: 生成されたCursor command bridgeだけを見ても責務と正本を判断できるようにしたい。
#   - 守るべき業務ルール: bridgeはClaude hookとのスキーマ差だけを吸収し、この生成テンプレートを正本にする。
#   - 他案不採用理由: 生成先へ説明を手書きすると次回syncで消え、正本との二重管理になるため不採用。
# 対応: 判断理由を生成テンプレートからbridgeへ埋め込む。
# [2026-09-03][fix]
# 背景: Cursor Stop が hook_event_name 欠落 / PascalCase Stop 表記だと Claude の decision:block が
#   followup_message にならず、loop_count が上がらず品質チェックが無限注入された。
# 守るべき業務ルール: Stop 入力は {status, loop_count}。2回目以降は stop_hook_active 相当。
# 他案不採用理由: 配布先 hook の手直しは次回 sync で消える。AI に承認させる文面は hook が読まない。
# 対応: イベント推論・loop_count int 化・変換後 JSON から出力変換する。
set -euo pipefail

RAW_INPUT="$(cat || true)"
COMMAND_STRING="${1:-}"

if [ -z "$COMMAND_STRING" ]; then
  echo "[cursor-command-bridge] command string is required" >&2
  exit 1
fi

extract_field() {
  local field="$1"
  if [ -z "$RAW_INPUT" ]; then
    return 0
  fi

  HOOK_JSON="$RAW_INPUT" PY_FIELD="$field" command python3 - <<'PY' 2>/dev/null || true
import json
import os

field = os.environ.get("PY_FIELD", "")
raw = os.environ.get("HOOK_JSON", "")

aliases = {
    "project_dir": ["project_dir", "projectDir", "projectRoot", "workspace_root", "workspaceRoot", "cwd"],
    "cwd": ["cwd", "workingDirectory", "project_dir", "projectDir", "projectRoot"],
    "tool_command": ["command", "shell_command", "shellCommand"],
    "file_path": ["file_path", "filePath", "path", "target_path"],
    "hook_event_name": ["hook_event_name", "hookEventName"],
}

keys = aliases.get(field, [field])
value = ""

try:
    payload = json.loads(raw)
except Exception:
    payload = {}

def lookup(obj):
    if not isinstance(obj, dict):
        return ""
    for key in keys:
        candidate = obj.get(key, "")
        if isinstance(candidate, str) and candidate:
            return candidate
    tool_input = obj.get("tool_input")
    if isinstance(tool_input, dict):
        for key in keys:
            candidate = tool_input.get(key, "")
            if isinstance(candidate, str) and candidate:
                return candidate
    return ""

value = lookup(payload)
print(value, end="")
PY
}

# --- 入力スキーマ変換: Cursor → Claude Code 互換 ---
# Cursor の stop/subagentStop は hook_event_name 欠落や PascalCase Stop 表記がある。
# 推論して正規化し、loop_count > 0 → stop_hook_active: true を注入する。
transform_input() {
  local input="$1"
  if [ -z "$input" ]; then
    return 0
  fi

  HOOK_JSON="$input" command python3 - <<'PY' 2>/dev/null || printf '%s' "$input"
import json
import os

raw = os.environ.get("HOOK_JSON", "")

try:
    data = json.loads(raw)
except Exception:
    print(raw, end="")
    raise SystemExit(0)

EVENT_ALIASES = {
    "Stop": "stop",
    "stop": "stop",
    "SubagentStop": "subagentStop",
    "subagentStop": "subagentStop",
    "subagent_stop": "subagentStop",
    "PreToolUse": "preToolUse",
    "preToolUse": "preToolUse",
    "pre_tool_use": "preToolUse",
}

def coerce_loop_count(payload):
    raw_count = payload.get("loop_count", payload.get("loopCount", 0))
    try:
        return int(raw_count)
    except (TypeError, ValueError):
        return 0

def resolve_event(payload):
    event = payload.get("hook_event_name") or payload.get("hookEventName") or ""
    if not isinstance(event, str):
        event = ""
    normalized = EVENT_ALIASES.get(event, event)
    if normalized in ("stop", "subagentStop"):
        return normalized
    has_loop = "loop_count" in payload or "loopCount" in payload
    status = payload.get("status", "")
    has_status = status in ("completed", "aborted", "error")
    has_subagent = "subagent_type" in payload or "subagentType" in payload
    has_tool = "tool_name" in payload or "toolName" in payload
    if has_loop or (has_status and not has_tool):
        return "subagentStop" if has_subagent else "stop"
    return normalized

event = resolve_event(data)
if event:
    data["hook_event_name"] = event

if event in ("stop", "subagentStop"):
    loop_count = coerce_loop_count(data)
    data["loop_count"] = loop_count
    data["stop_hook_active"] = loop_count > 0

print(json.dumps(data, ensure_ascii=False), end="")
PY
}

# --- 出力スキーマ変換: Claude Code → Cursor 形式 ---
# フックスクリプトの出力を hook_event_name に応じて Cursor 形式に変換する
transform_output() {
  local output="$1"
  local event="$2"
  if [ -z "$output" ]; then
    return 0
  fi

  HOOK_OUTPUT="$output" HOOK_EVENT="$event" command python3 - <<'PY' 2>/dev/null || printf '%s' "$output"
import json
import os

raw = os.environ.get("HOOK_OUTPUT", "")
event = os.environ.get("HOOK_EVENT", "")
event_aliases = {
    "Stop": "stop",
    "stop": "stop",
    "SubagentStop": "subagentStop",
    "subagentStop": "subagentStop",
    "subagent_stop": "subagentStop",
    "PreToolUse": "preToolUse",
    "preToolUse": "preToolUse",
    "pre_tool_use": "preToolUse",
}
event = event_aliases.get(event, event)

try:
    data = json.loads(raw)
except Exception:
    print(raw, end="")
    raise SystemExit(0)

decision = data.get("decision", "")
reason = data.get("reason", "")
hook_specific = data.get("hookSpecificOutput")
if not isinstance(hook_specific, dict):
    hook_specific = {}
permission_decision = hook_specific.get("permissionDecision", "")
permission_reason = hook_specific.get("permissionDecisionReason", "") or hook_specific.get("reason", "")
if permission_reason and not reason:
    reason = permission_reason

if event in ("stop", "subagentStop"):
    if (decision == "block" or permission_decision == "deny") and reason:
        print(json.dumps({"followup_message": reason}, ensure_ascii=False), end="")
    else:
        print("{}", end="")
elif event in ("preToolUse",):
    if permission_decision == "deny" or decision == "block":
        perm = "deny"
    elif permission_decision == "allow" or decision == "approve" or data.get("continue") is True:
        perm = "allow"
    else:
        perm = "allow"
    result = {"permission": perm}
    if perm == "deny" and reason:
        result["agent_message"] = reason
        result["user_message"] = reason
    print(json.dumps(result, ensure_ascii=False), end="")
else:
    print(raw, end="")
PY
}

PROJECT_DIR="${CURSOR_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(extract_field project_dir)"
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

TOOL_COMMAND="$(extract_field tool_command)"
FILE_PATH="$(extract_field file_path)"
HOOK_CWD="$(extract_field cwd)"

export CURSOR_PROJECT_DIR="$PROJECT_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
export CURSOR_HOOK_INPUT="$RAW_INPUT"

if [ -n "$TOOL_COMMAND" ]; then
  export CLAUDE_TOOL_INPUT="$TOOL_COMMAND"
fi

if [ -n "$FILE_PATH" ]; then
  export CLAUDE_FILE_PATH="$FILE_PATH"
fi

if [ -n "$HOOK_CWD" ]; then
  cd "$HOOK_CWD" 2>/dev/null || cd "$PROJECT_DIR"
else
  cd "$PROJECT_DIR"
fi

# 入力変換を適用してからフックスクリプトに渡し、出力変換を適用。
# hook_event_name は変換後 JSON（推論・正規化済み）から取る。欠落 payload でも stop 変換する。
TRANSFORMED_INPUT="$(transform_input "$RAW_INPUT")"
_BRIDGE_RAW_SAVE="$RAW_INPUT"
if [ -n "$TRANSFORMED_INPUT" ]; then
  RAW_INPUT="$TRANSFORMED_INPUT"
fi
HOOK_EVENT="$(extract_field hook_event_name)"
RAW_INPUT="$_BRIDGE_RAW_SAVE"
unset _BRIDGE_RAW_SAVE

if [ -n "$TRANSFORMED_INPUT" ]; then
  HOOK_OUTPUT="$(printf '%s' "$TRANSFORMED_INPUT" | bash -lc "$COMMAND_STRING")"
else
  HOOK_OUTPUT="$(bash -lc "$COMMAND_STRING")"
fi

if [ -n "$HOOK_EVENT" ] && [ -n "$HOOK_OUTPUT" ]; then
  transform_output "$HOOK_OUTPUT" "$HOOK_EVENT"
else
  printf '%s' "$HOOK_OUTPUT"
fi
