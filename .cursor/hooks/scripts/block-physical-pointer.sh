#!/usr/bin/env bash
# PreToolUse: マウス（実カーソル）を実際に動かす道具の許可制（見張り）。
# [2026-11-02][feat]
# 背景: 伸太郎さん 2026-11-02「マウス操作が勝手に使われるのは絶対やりたくない・それを当たり前にしたい」
# 守る: カーソルを動かさない道具は止めない（kimi-cu・agent-desktop の普段の動き・WebBridge）
# 不採用: 文章の決まりのまま（守られる保証が無い）/ 許可の札で通す別の通り道（今回は作らない）
# 対応: computer use と agent-desktop --headed に ask。確認が出ない動かし方
#   （permission_mode が bypassPermissions・dontAsk、または Codex 配線の環境変数）では deny。
#   入力 JSON が読めない時は何も出さず exit 0（通常の許可の流れに任せる）。

set -uo pipefail

input="$(cat)"

HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null || true
import json
import os
import re

FORCE_ENV = "BLOCK_PHYSICAL_POINTER_FORCE_DENY"
FORCE_MODES = ("bypassPermissions", "dontAsk")
COMPUTER_PREFIXES = ("mcp__computer-use__", "mcp__remote-devices__computer_")
HEADED = re.compile(r"(?<![\w-])--headed(?![\w-])")
AGENT_DESKTOP = re.compile(r"(?<![\w.-])agent-desktop(?![\w.-])")
SEPARATOR_OR_SUBSHELL = re.compile(r"[;&|`\n]|\$\(|<\(|>\(")


def pointer_tool_name(tool_name, command):
    """マウスを実際に動かしうる道具なら表示名を返す。対象外は None。"""
    if tool_name.startswith(COMPUTER_PREFIXES):
        return tool_name
    # [2026-11-02] Kimi の配布先は matcher に Shell を含むため、Bash と同じ判定に通す。
    if tool_name in ("Bash", "Shell") and command:
        if AGENT_DESKTOP.search(command) and HEADED.search(command):
            # echo / printf は引数に文字列を並べるだけで、区切り記号や $( ` が無ければ
            # 道具を実行しない。説明文の中の偶然一致を外すために例外にする。
            first_word = command.strip().split(None, 1)[0] if command.strip() else ""
            if first_word in ("echo", "printf") and not SEPARATOR_OR_SUBSHELL.search(command):
                return None
            return "agent-desktop --headed"
    return None


def main():
    try:
        data = json.loads(os.environ.get("HOOK_INPUT", ""))
    except (ValueError, TypeError):
        return
    if not isinstance(data, dict):
        return

    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = data.get("toolInput")
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get("command")
    if not isinstance(command, str):
        command = ""

    tool_name = data.get("tool_name")
    if not isinstance(tool_name, str):
        return

    label = pointer_tool_name(tool_name, command)
    if label is None:
        return

    permission_mode = data.get("permission_mode")
    force_deny = permission_mode in FORCE_MODES or os.environ.get(FORCE_ENV) == "1"

    if force_deny:
        decision = "deny"
        reason = (
            f"マウスを実際に動かす道具（{label}）は本人の許可制です。"
            "今の動かし方では確認画面を出せないので止めました。"
            "必要なら本人に頼んで、確認が出る動かし方（通常モード）で実行してもらってください。"
        )
    else:
        decision = "ask"
        reason = (
            f"マウスを実際に動かす道具（{label}）です。本人の許可が要ります"
            "（kimi-cu・agent-desktop の普段の動き・ブラウザ操作はマウスを動かしません）。"
        )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


main()
PY

exit 0
