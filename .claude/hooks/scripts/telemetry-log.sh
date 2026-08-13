#!/usr/bin/env bash
# telemetry-log.sh — Claude Code hook entry for harness telemetry.
#
# Claude Code の PreToolUse / PostToolUse / SessionStart / Stop / SubagentStop で呼ばれる。
# stdin の hook JSON を読み、ツール名/イベントから event_type を判定して 1 行 JSON を追記する。
#
# 絶対方針: fail-open。
#   - いかなる入力・エラーでも exit 0・ブロックしない・stdout には何も出さない
#     (PreToolUse で空 stdout = 許可継続。テレメトリが原因でツールを止めない)。
#   - AGENT_HUB_TELEMETRY_DISABLE=1 で完全無効化。
#   - 外部ネットワーク不使用。
#
# event_type マッピング:
#   tool_name=Skill                     → skill_fire, name=スキル名
#   tool_name=Task/Agent                → subagent_start, name=subagent_type
#   hook_event=SessionStart             → session_start
#   hook_event=Stop                     → session_stop
#   hook_event=SubagentStop             → subagent_stop
#   その他の tool_name 付きツール       → tool_use, name=tool_name
#   (event/tool ともに取れない場合は記録しない)

# set -e を使わない(fail-open 優先)。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 共有関数を読み込み。lib が無い配布先でも壊れない no-op fallback。
. "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }

# stdin を1回だけ読む(hook JSON)。
input="$(cat 2>/dev/null || true)"

# 無効化フックはここでも早抜け(呼び出しコストを避ける)。
if [ "${AGENT_HUB_TELEMETRY_DISABLE:-0}" = "1" ]; then
  exit 0
fi

# hook JSON を解析して event_type / name / outcome を決定し、lib 関数へ渡す。
# python3 が読めれば解析、なければ何もしない(fail-open)。
parsed="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null || true
import json
import os
import sys


def get_string(data, *keys):
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def get_tool_input(data):
    ti = data.get("tool_input")
    if isinstance(ti, dict):
        return ti
    ti = data.get("toolInput")
    if isinstance(ti, dict):
        return ti
    return {}


raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

hook_event = get_string(data, "hook_event_name", "hookEventName")
tool_name = get_string(data, "tool_name", "toolName")
agent_type = get_string(data, "agent_type", "agentType")
ti = get_tool_input(data)

event_type = ""
name = ""

if hook_event == "SessionStart":
    event_type = "session_start"
    name = "session"
elif hook_event == "Stop":
    event_type = "session_stop"
    name = "session"
elif hook_event == "SubagentStop":
    # [2026-07-04][fix] Codexレビュー対応(PR #670 🟡2):
    #   背景: ファイル冒頭コメントは SubagentStop でも呼ばれる前提だったが、
    #     tool_name を伴わない SubagentStop はどの分岐にも一致せず event_type が
    #     空のまま記録漏れ(サブエージェント終了が観測されない)になっていた。
    #   対応: SubagentStop を明示的に subagent_stop として記録する。
    event_type = "subagent_stop"
    name = "subagent"
elif tool_name == "Skill":
    event_type = "skill_fire"
    # [2026-07-23][fix]
    # 背景: 現行runtimeが tool_input.skill へ変わり、旧nameだけでは空観測になった。
    # 守る契約: skillを正本として読み、旧name/skill_nameは互換入力として維持する。
    # 他案不採用: 旧キー専用へ戻すと現行payloadを再び欠損させるため採らない。
    name = get_string(ti, "skill", "name", "skill_name")
elif tool_name in ("Task", "Agent"):
    event_type = "subagent_start"
    name = get_string(ti, "subagent_type", "subtype") or agent_type
elif tool_name:
    event_type = "tool_use"
    name = tool_name

if not event_type:
    # 記録対象が無い → 何も出力しない
    sys.exit(0)

# タブ区切りで shell へ返す(name にタブが含まれる可能性は低いが、念のため除去)
name = name.replace("\t", " ").replace("\n", " ")
print("\t".join([event_type, name, "ok"]))
PY
)"

# python3 が何も返さなければテレメトリ追記しない(fail-open)。
if [ -n "$parsed" ]; then
  event_type="${parsed%%$'\t'*}"
  rest="${parsed#*$'\t'}"
  name="${rest%%$'\t'*}"
  outcome="${rest#*$'\t'}"
  agent_hub_telemetry_log "$event_type" "$name" "$outcome" 2>/dev/null || true
fi

exit 0
