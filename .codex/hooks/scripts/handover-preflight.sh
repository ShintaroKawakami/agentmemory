#!/bin/bash
# UserPromptSubmit hook for Handover hints.
# Quiet by default. Prints only when the prompt asks for
# "続き", "引き継ぎ書つくって", "引き継ぎ", "作業終了", "終了整理", "Closeout整理",
# "ふり返り", "振り返り", "ふりかえり",
# "handover", compatibility "takeover", or when HANDOVER_PREFLIGHT_FORCE=1 is set.
#
# [2026-06-30][refactor]
# 背景:
#   - ユーザー依頼意図: ユーザー向けの引き継ぎ名を Takeover から Handover へ寄せ、
#     plan / Typinator / hook の入口名を揃えたい。
#   - 守るべき業務ルール: 旧 `takeover` / `continuation` 発話、旧 env、旧
#     `~/.agent-hub/takeovers` の保存済みデータは壊さず、互換入口として残す。
#   - 他案不採用理由: 旧 hook を即削除する案は既存 settings の command を壊す。
#     新旧を同格にする案は正本名が再び揺れるため不採用。
# 対応: `handover-preflight` を正本にし、旧 `takeover-preflight` は wrapper から本ファイルを呼ぶ。

set -euo pipefail

RAW_INPUT="$(cat || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

HOOK_INPUT="$RAW_INPUT" command python3 - "$PROJECT_DIR" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
raw = os.environ.get("HOOK_INPUT", "")


def prompt_from_payload(text: str) -> str:
    if not text.strip():
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return text
    if not isinstance(payload, dict):
        return ""
    for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
        value = payload.get(key)
        if isinstance(value, str):
            return value
    nested = payload.get("tool_input")
    if isinstance(nested, dict):
        for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
            value = nested.get(key)
            if isinstance(value, str):
                return value
    return ""


def unquote_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def candidate_alias_paths() -> list[Path]:
    paths: list[Path] = []
    env_path = os.environ.get("HANDOVER_ALIASES_PATH", "").strip()
    if env_path:
        paths.append(Path(env_path).expanduser())
    compat_env = os.environ.get("TAKEOVER_ALIASES_PATH", "").strip()
    if compat_env:
        paths.append(Path(compat_env).expanduser())
    legacy_env = os.environ.get("AGENT_MEMORY_ALIASES_PATH", "").strip()
    if legacy_env:
        paths.append(Path(legacy_env).expanduser())
    paths.append(project_dir / "agent-memory" / "aliases.yaml")
    paths.append(Path("/Users/shintaro/business/AGENT-HUB/agent-memory/aliases.yaml"))
    return paths


def load_apps(aliases_path: Path) -> list[dict[str, object]]:
    apps: list[dict[str, object]] = []
    current_project: str | None = None
    current: dict[str, object] | None = None
    in_aliases = False

    for raw_line in aliases_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        project_match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if project_match:
            current_project = project_match.group(1)
            current = None
            in_aliases = False
            continue

        app_match = re.match(r"^      ([A-Za-z0-9_-]+):\s*$", line)
        if app_match and current_project:
            current = {
                "project": current_project,
                "canonical_name": app_match.group(1),
                "aliases": [],
            }
            apps.append(current)
            in_aliases = False
            continue

        if current is None:
            continue

        kv_match = re.match(r"^        ([A-Za-z0-9_]+):\s*(.*)$", line)
        if kv_match:
            key = kv_match.group(1)
            value = unquote_scalar(kv_match.group(2))
            in_aliases = key == "aliases"
            if key != "aliases":
                current[key] = value
            continue

        alias_match = re.match(r"^          -\s*(.+?)\s*$", line)
        if in_aliases and alias_match:
            aliases = current.setdefault("aliases", [])
            if isinstance(aliases, list):
                aliases.append(unquote_scalar(alias_match.group(1)))

    return apps


def find_aliases_path() -> Path | None:
    for path in candidate_alias_paths():
        if path.is_file():
            return path
    return None


TRIGGER_RE = re.compile(
    r"(続き|終了整理|Closeout整理|ふり返り|振り返り|ふりかえり|引継ぎ書つくって|引き継ぎ|作業終了|handover|takeover|continuation|continuation-closeout)",
    re.IGNORECASE,
)
NEGATED_CONTINUATION_RE = re.compile(
    r"続き\s*(?:ではなくて|ではなく|ではない|でなく|でない|じゃなくて|じゃなく|じゃない|"
    r"はなく|はない|は不要|不要|はいらない|いらない|なく|ない)"
)
NEGATED_CLOSEOUT_KEYWORDS = ("終了整理", "Closeout整理", "ふり返り", "振り返り", "ふりかえり", "作業終了")
NEGATED_CLOSEOUT_SUFFIXES = (
    "ではない",
    "ではないです",
    "ではなく",
    "ではなくて",
    "でない",
    "でないです",
    "じゃない",
    "じゃないです",
    "はない",
    "はいらない",
    "は不要",
    "必要ない",
    "不要",
    "要らない",
    "いらない",
    "ない",
)
NEGATED_PUNCTUATION = re.compile(r"[\s、。.!?！？ー−‐\\-]")
MAX_ALIAS_TRIGGER_DISTANCE = 32


def normalize_for_negation(value: str) -> str:
    return NEGATED_PUNCTUATION.sub("", value.casefold())


def is_negated_closeout_trigger(prompt: str, trigger: str) -> bool:
    folded = normalize_for_negation(prompt)
    normalized_trigger = normalize_for_negation(trigger)
    index = 0
    while True:
        index = folded.find(normalized_trigger, index)
        if index < 0:
            return False
        tail = folded[index + len(normalized_trigger):]
        for suffix in NEGATED_CLOSEOUT_SUFFIXES:
            if tail.startswith(normalize_for_negation(suffix)):
                return True
        index += len(normalized_trigger)


def positive_trigger_spans(prompt: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    for match in TRIGGER_RE.finditer(prompt):
        tail = prompt[match.start() : match.end() + 12]
        if match.group(1) == "続き" and NEGATED_CONTINUATION_RE.match(tail):
            continue
        if match.group(1) in NEGATED_CLOSEOUT_KEYWORDS and is_negated_closeout_trigger(prompt, match.group(1)):
            continue
        spans.append(match.span())
    return spans


def alias_near_trigger(prompt: str, name: str, trigger_spans: list[tuple[int, int]]) -> bool:
    if not name:
        return False
    for name_match in re.finditer(re.escape(name), prompt, flags=re.IGNORECASE):
        for trigger_start, trigger_end in trigger_spans:
            if name_match.end() <= trigger_start:
                distance = trigger_start - name_match.end()
            else:
                distance = name_match.start() - trigger_end
            if 0 <= distance <= MAX_ALIAS_TRIGGER_DISTANCE:
                return True
    return False


def matched_app(prompt: str, apps: list[dict[str, object]]) -> dict[str, object] | None:
    folded_prompt = prompt.casefold()
    trigger_spans = positive_trigger_spans(prompt)
    for app in apps:
        names: list[str] = []
        for key in ("canonical_name", "display_name"):
            value = app.get(key)
            if isinstance(value, str):
                names.append(value)
        aliases = app.get("aliases")
        if isinstance(aliases, list):
            names.extend(str(alias) for alias in aliases)

        for name in names:
            if trigger_spans and alias_near_trigger(prompt, name, trigger_spans):
                return app
            if name and name.casefold() in folded_prompt:
                return app
    return None


def project_from_cwd(path: Path) -> str:
    if (path / "DISTRIBUTION.yaml").is_file() and (path / "hook-registry.yaml").is_file():
        return "AGENT-HUB"
    text = str(path)
    checks = [
        ("AGENT-HUB", "/AGENT-HUB"),
        ("jtt-system", "/jtt-system"),
        ("jtt-apps", "/jtt-apps"),
        ("jtt-cms", "/jtt-cms"),
        ("jtt-cafe-pj", "/jtt-cafe-pj"),
        ("hermes", "/mac-mini-server/hermes"),
    ]
    for project, marker in checks:
        if marker in text:
            return project
    if (path / "pnpm-workspace.yaml").is_file() and (path / "apps").is_dir():
        return "jtt-system"
    return "non-pj"


def scope_from_cwd(project: str, path: Path) -> str:
    parts = path.parts
    if project == "jtt-system" and "apps" in parts:
        idx = parts.index("apps")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    if project == "AGENT-HUB":
        for marker in ("skills", "hook-library", "snippet-prompts", "agent-memory"):
            if marker in parts:
                idx = parts.index(marker)
                if idx + 1 < len(parts):
                    return parts[idx + 1]
                return marker
    return "root"


def handover_path(project: str, scope: str) -> str:
    return str(Path.home() / ".agent-hub" / "handovers" / project / scope / "current.md")


def legacy_path(project: str, scope: str) -> str:
    return str(Path.home() / ".agent-hub" / "takeovers" / project / scope / "current.md")


PROJECT_CLAUDE_MEMORY_PATHS = {
    "AGENT-HUB": "-Users-shintaro-business-AGENT-HUB",
    "bank-payment-automator": "-Users-shintaro-business-bank-payment-automator",
    "hermes": "-Users-shintaro-mac-mini-server-hermes",
    "jtt-apps": "-Users-shintaro-Herd-jtt-apps",
    "jtt-cafe-pj": "-Users-shintaro-business-jtt-cafe-pj",
    "jtt-cms": "-Users-shintaro-LLM-Dev-jtt-cms",
    "jtt-system": "-Users-shintaro-jtt-system",
}


def claude_memory_path(project: str, app: dict[str, object] | None) -> str:
    if app is not None:
        configured = app.get("claude_memory_path")
        if isinstance(configured, str) and configured:
            return configured
    encoded = PROJECT_CLAUDE_MEMORY_PATHS.get(project)
    if not encoded:
        return "未登録"
    return str(Path.home() / ".claude" / "projects" / encoded / "memory" / "MEMORY.md")


def print_hint(app: dict[str, object] | None, forced: bool) -> None:
    manual_path = "skills/handover-manual/references/handover.md"
    reflection_path = "agent-memory/registry/reflection-policy.md"
    placement_path = "agent-memory/registry/placement-policy.md"

    if app is not None:
        project = str(app.get("project") or project_from_cwd(project_dir))
        scope = str(app.get("canonical_name") or scope_from_cwd(project, project_dir))
        display = app.get("display_name") or scope
    else:
        project = project_from_cwd(project_dir)
        scope = scope_from_cwd(project, project_dir)
        display = scope

    print("handover preflight:")
    print(f"- scope: {project}/{scope}")
    print(f"- handover_path: {handover_path(project, scope)}")
    print(f"- legacy_path: {legacy_path(project, scope)}")
    print(f"- claude_memory: {claude_memory_path(project, app)}")
    print(f"- manual: {manual_path}")
    print(f"- reflection-policy: {reflection_path}")
    print(f"- placement-policy: {placement_path}")
    # [2026-07-18][fix]
    # 背景: closeoutでPJ固有の短期状態までGBrain候補に混ざり、人間の判断原則と技術台帳の境界が曖昧だった。
    # 守るべき業務ルール: GBrain候補はユーザーしか判断できない原則へ抽象化し、技術/PJ情報はTech GBrainかSSOTへ置く。
    # 他案不採用理由: 候補を全件GBrainへ送る案は確認負荷と重複を増やすため不採用。
    print("- closeout: 未完了 / 次回やること / Tech G-Brain候補 / GBrain候補 / SSOT昇格候補を分ける")
    print("- gbrain: 技術名・PJ固有名・短期状態は候補にせず、人間の判断原則へ抽象化")
    print("- handover_update: 未完了がある時だけ current.md を更新")
    if forced and app is None:
        print("- alias: 未検出。cwdから推定")
    elif app is not None:
        print(f"- app: {display}")


prompt = prompt_from_payload(raw)
forced = (
    os.environ.get("HANDOVER_PREFLIGHT_FORCE", "0") == "1"
    or os.environ.get("TAKEOVER_PREFLIGHT_FORCE", "0") == "1"
    or os.environ.get("AGENT_MEMORY_PREFLIGHT_FORCE", "0") == "1"
)

if not forced and not positive_trigger_spans(prompt):
    raise SystemExit(0)

aliases_path = find_aliases_path()
app = None
if aliases_path is not None:
    try:
        app = matched_app(prompt, load_apps(aliases_path))
    except Exception:
        app = None

print_hint(app, forced)
PY
