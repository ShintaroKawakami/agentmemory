#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

RUNTIME_SPEC = { 'before': { 'generic_hooks': [ 'block-destructive-git.sh',
                                 'block-main-commit.sh',
                                 'post-merge-gate.sh',
                                 'storage-url-pr-gate.sh'],
              'pre_pr_check_on_git_push': False},
  'after': { 'write_edit': { 'auto_catalog': False,
                             'check_frontmatter': False,
                             'validate_skills': False,
                             'validate_ssot': False,
                             'validate_prompt_ssot': False}},
  'agent': {'pre_implementation_check': True}}
PROJECT_ROOT = Path(os.environ.get("GEMINI_PROJECT_DIR", ".")).resolve()


def read_payload():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def write_json(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))


def run_process(command, args, *, stdin_text="", env=None, cwd=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [command, *args],
        input=stdin_text,
        text=True,
        capture_output=True,
        cwd=str(cwd or PROJECT_ROOT),
        env=merged_env,
    )


def combined_output(result):
    return "\n".join(part.strip() for part in [result.stdout, result.stderr] if part.strip()).strip()


def parse_claude_deny(output_text):
    if not output_text.strip():
        return None
    try:
        payload = json.loads(output_text)
    except json.JSONDecodeError:
        return None
    hook_output = payload.get("hookSpecificOutput", {})
    if not isinstance(hook_output, dict):
        return None
    if hook_output.get("permissionDecision") == "deny":
        return str(hook_output.get("permissionDecisionReason") or hook_output.get("reason") or "blocked by Claude-compatible hook")
    return None


def extract_path(tool_input):
    if not isinstance(tool_input, dict):
        return ""
    for key in ("file_path", "path", "filePath", "absolute_path", "absolutePath"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def run_generate_catalog(target_path):
    if not RUNTIME_SPEC["after"]["write_edit"]["auto_catalog"]:
        return
    normalized = str(target_path or "")
    if normalized == "CLAUDE.md" or normalized.startswith(".claude/rules/"):
        result = run_process("bash", [str(PROJECT_ROOT / "scripts" / "generate-agents-md.sh")])
        if result.returncode != 0:
            raise RuntimeError(combined_output(result) or "generate-agents-md.sh failed")
    elif normalized.startswith("skills/") and normalized.endswith("/SKILL.md"):
        result = run_process("bash", [str(PROJECT_ROOT / "scripts" / "generate-catalog.sh")])
        if result.returncode != 0:
            raise RuntimeError(combined_output(result) or "generate-catalog.sh failed")


def validate_path(target_path):
    normalized = str(target_path or "")
    if not normalized:
        return

    run_generate_catalog(normalized)

    shared_env = {
        "CLAUDE_FILE_PATH": normalized,
        "GEMINI_FILE_PATH": normalized,
        "CLAUDE_PROJECT_DIR": str(PROJECT_ROOT),
        "GEMINI_PROJECT_DIR": str(PROJECT_ROOT),
    }

    if RUNTIME_SPEC["after"]["write_edit"]["check_frontmatter"] and re_matches("skills/.*/SKILL\\.md$", normalized):
        run_or_raise("python3", [str(PROJECT_ROOT / "scripts" / "check_frontmatter.py"), "--warn", normalized], shared_env)
    if RUNTIME_SPEC["after"]["write_edit"]["validate_skills"] and re_matches("skills/.*/SKILL\\.md$", normalized):
        run_or_raise("bash", [str(PROJECT_ROOT / "scripts" / "validate-skills.sh"), "--warn", normalized], shared_env)
    if RUNTIME_SPEC["after"]["write_edit"]["validate_ssot"] and re_matches("(DISTRIBUTION\\.yaml|project-registry\\.yaml|hook-registry\\.yaml|agents\\.yaml)$", normalized):
        run_or_raise("bash", [str(PROJECT_ROOT / "scripts" / "validate-ssot-consistency.sh")], shared_env)
    if RUNTIME_SPEC["after"]["write_edit"]["validate_prompt_ssot"] and re_matches("snippet-prompts/.*\\.md$", normalized):
        run_or_raise("bash", [str(PROJECT_ROOT / "scripts" / "validate-prompt-ssot-consistency.sh"), "--warn", normalized], shared_env)


def run_or_raise(command, args, env):
    result = run_process(command, args, env=env)
    if result.returncode != 0:
        raise RuntimeError(combined_output(result) or f"{command} failed")


def re_matches(pattern, value):
    import re
    return re.search(pattern, value) is not None


def get_tool_input(payload):
    # [2026-06-28][fix]
    # 背景: Antigravity/Kimi は camelCase toolInput を送ることがあり、snake_case だけだと
    # command が空になって main 保護 hook が fail-open する。逆に snake_case がある場合に
    # camelCase が上書きして危険なコマンドを消せると fail-closed 要件を満たせない。
    # 他案不採用理由:
    # - tool_input と toolInput の単純な camelCase 優先 / last-writer-wins 方針は、片側の
    #   安全な値で危険コマンドを隠せるため不採用（fail-closed 破壊）。
    # 守るべき業務ルール: main 直書き系操作はどの CLI 派生でも fail-closed。
    # 対応: tool_input/toolInput を正規化しつつ、command は両値を失わず結合して返す。
    value = payload.get("tool_input", {})
    camel = payload.get("toolInput", {})
    if not isinstance(value, dict):
        value = {}
    if not isinstance(camel, dict):
        camel = {}
    merged = {}
    merged.update(value)
    merged.update(camel)

    snake_command = value.get("command")
    camel_command = camel.get("command")
    commands = []
    for command in (snake_command, camel_command):
        if isinstance(command, str):
            command = command.strip()
            if command and command not in commands:
                commands.append(command)
    if commands and (snake_command is not None or camel_command is not None):
        merged["command"] = " && ".join(commands)

    if (
        isinstance(payload, dict)
        and "tool_input" not in payload
        and "toolInput" not in payload
    ):
        for key in ("file_path", "path", "filePath", "absolute_path", "absolutePath"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                merged[key] = value

    return merged


def get_shell_tool_inputs(payload):
    # [2026-07-02][fix]
    # 背景: tool_input と toolInput を merge した 1 入力だけで検査すると、command は結合される一方で
    # cwd は last-writer-wins になり、main 上の commit が別 worktree の cwd として判定される。
    # 守るべき業務ルール: command/cwd の組み合わせを失わず、曖昧な混在 payload は fail-closed。
    # 対応: snake/camel の個別入力に加え、存在する command と cwd の組み合わせを検査候補にする。
    candidates = []
    if not isinstance(payload, dict):
        return [{"command": "", "cwd": str(PROJECT_ROOT)}]

    wrappers = []
    for key in ("tool_input", "toolInput"):
        value = payload.get(key)
        if isinstance(value, dict):
            wrappers.append(value)

    if not wrappers:
        tool_input = get_tool_input(payload)
        return [tool_input] if isinstance(tool_input, dict) else [{"command": "", "cwd": str(PROJECT_ROOT)}]

    commands = []
    cwds = []
    for wrapper in wrappers:
        command = wrapper.get("command")
        if isinstance(command, str):
            command = command.strip()
            if command and command not in commands:
                commands.append(command)
        cwd = wrapper.get("cwd")
        if isinstance(cwd, str):
            cwd = cwd.strip()
            if cwd and cwd not in cwds:
                cwds.append(cwd)
        candidates.append(dict(wrapper))

    for command in commands:
        for cwd in cwds or [str(PROJECT_ROOT)]:
            candidates.append({"command": command, "cwd": cwd})

    deduped = []
    seen = set()
    for candidate in candidates:
        marker = json.dumps(candidate, sort_keys=True, ensure_ascii=False)
        if marker in seen:
            continue
        seen.add(marker)
        deduped.append(candidate)
    return deduped or [{"command": "", "cwd": str(PROJECT_ROOT)}]


def get_tool_inputs_for_path_validation(payload):
    candidates = []
    if not isinstance(payload, dict):
        return candidates

    for key in ("tool_input", "toolInput"):
        value = payload.get(key)
        if isinstance(value, dict):
            candidates.append(value)
    if not candidates:
        tool_input = get_tool_input(payload)
        if isinstance(tool_input, dict):
            return [tool_input]
    return candidates


def resolve_hook_script(name):
    candidates = [
        Path(__file__).resolve().parent / name,
        PROJECT_ROOT / ".claude" / "hooks" / "scripts" / name,
        PROJECT_ROOT / "hook-library" / "scripts" / name,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def handle_before_tool_run_shell():
    payload = read_payload()
    for tool_input in get_shell_tool_inputs(payload):
        command_text = str(tool_input.get("command", ""))
        cwd = Path(str(tool_input.get("cwd", PROJECT_ROOT))).resolve()
        claude_payload = json.dumps({"tool_input": {"command": command_text, "cwd": str(cwd)}}, ensure_ascii=False)

        for hook_name in RUNTIME_SPEC["before"]["generic_hooks"]:
            result = run_process(
                "bash",
                [str(resolve_hook_script(hook_name))],
                stdin_text=claude_payload,
                env={
                    "CLAUDE_PROJECT_DIR": str(PROJECT_ROOT),
                    "GEMINI_PROJECT_DIR": str(PROJECT_ROOT),
                },
                cwd=cwd,
            )
            deny_reason = parse_claude_deny(result.stdout)
            if deny_reason:
                write_json({"decision": "deny", "reason": deny_reason})
                return
            if result.returncode != 0:
                write_json({"decision": "deny", "reason": combined_output(result) or f"{hook_name} failed"})
                return

        if RUNTIME_SPEC["before"]["pre_pr_check_on_git_push"] and "git push" in command_text:
            result = run_process(
                "bash",
                [str(PROJECT_ROOT / "scripts" / "pre-pr-check.sh")],
                env={
                    "CLAUDE_PROJECT_DIR": str(PROJECT_ROOT),
                    "GEMINI_PROJECT_DIR": str(PROJECT_ROOT),
                },
                cwd=cwd,
            )
            if result.returncode != 0:
                write_json({"decision": "deny", "reason": combined_output(result) or "pre-pr-check failed"})
                return

    write_json({})


def handle_after_tool_write_edit():
    payload = read_payload()
    for tool_input in get_tool_inputs_for_path_validation(payload):
        validate_path(extract_path(tool_input))
    write_json({})


def handle_before_agent_prompt():
    if not RUNTIME_SPEC["agent"]["pre_implementation_check"]:
        write_json({})
        return

    result = run_process(
        "bash",
        [str(resolve_hook_script("pre-implementation-check.sh"))],
        env={
            "CLAUDE_PROJECT_DIR": str(PROJECT_ROOT),
            "GEMINI_PROJECT_DIR": str(PROJECT_ROOT),
        },
    )
    if result.returncode != 0:
        write_json({"decision": "deny", "reason": combined_output(result) or "pre-implementation-check failed"})
        return

    additional_context = result.stdout.strip()
    if additional_context:
        write_json({"hookSpecificOutput": {"additionalContext": additional_context}})
        return

    write_json({})


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if mode == "before_tool_run_shell":
            handle_before_tool_run_shell()
        elif mode == "after_tool_write_edit":
            handle_after_tool_write_edit()
        elif mode == "before_agent_prompt":
            handle_before_agent_prompt()
        else:
            write_json({})
    except Exception as exc:  # noqa: BLE001
        write_json({"decision": "deny", "reason": str(exc)})


if __name__ == "__main__":
    main()
