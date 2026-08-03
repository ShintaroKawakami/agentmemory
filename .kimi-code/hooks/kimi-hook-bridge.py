#!/usr/bin/env python3
"""
Kimi hook stdin JSON を Claude hook 互換 env に変換して既存 hook command を実行する。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a Claude-style hook command from Kimi hook input.")
    parser.add_argument("command", help="Shell command generated from .claude/settings.json")
    return parser.parse_args()


def load_payload() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return {"raw_stdin": raw}
    return payload if isinstance(payload, dict) else {"payload": payload}


def first_string(*values: object) -> str:
    for value in values:
        if isinstance(value, str) and value:
            return value
    return ""


def main() -> int:
    args = parse_args()
    payload = load_payload()
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = payload.get("toolInput")
    if not isinstance(tool_input, dict):
        tool_input = {}

    env = os.environ.copy()
    env["CLAUDE_PROJECT_DIR"] = first_string(payload.get("cwd"), payload.get("project_dir"), env.get("PWD"), os.getcwd())
    env["CLAUDE_FILE_PATH"] = first_string(
        tool_input.get("file_path"),
        tool_input.get("path"),
        tool_input.get("notebook_path"),
        payload.get("file_path"),
        payload.get("path"),
    )
    tool_name = first_string(payload.get("tool_name"), payload.get("toolName"), payload.get("name"))
    env["CLAUDE_TOOL_INPUT"] = json.dumps(tool_input or payload, ensure_ascii=False)
    env.setdefault("CLAUDE_TOOL_NAME", tool_name)

    # Inner Claude-style hooks still read stdin via hook-io.sh. Pass a normalized
    # payload through so hooks do not silently lose file_path, cwd, or tool_name.
    normalized_tool_input = dict(tool_input or payload)
    project_dir = first_string(payload.get("cwd"), payload.get("project_dir"))
    if project_dir and "cwd" not in normalized_tool_input:
        normalized_tool_input["cwd"] = project_dir
    stdin_payload_obj = {"tool_input": normalized_tool_input}
    if tool_name:
        stdin_payload_obj["tool_name"] = tool_name
    if project_dir:
        stdin_payload_obj["cwd"] = project_dir
    stdin_payload = json.dumps(stdin_payload_obj, ensure_ascii=False)
    result = subprocess.run(args.command, shell=True, executable="/bin/bash", env=env, input=stdin_payload, text=True)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
