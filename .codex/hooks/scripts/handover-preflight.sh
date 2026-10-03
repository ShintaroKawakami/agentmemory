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

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd || true)"
HOOK_INPUT="$RAW_INPUT" HOOK_LIB_DIR="$HOOK_LIB_DIR" command python3 - "$PROJECT_DIR" <<'PY'
import json
import os
import re
import subprocess
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


# [2026-09-08][feat] 発火語・否定判定語は hook-library/lib/handover-preflight-policy.json（正本）から読む。
# 背景: スクリプト内ハードコードは tests/test_hook_policy_registry.py の allowlist 例外だった。
#   台帳化して例外を消す。語の意味・順序は従来と同じ（trigger_words は正規表現の選択肢として順に結合）。
_POLICY_PATH = os.environ.get("HANDOVER_PREFLIGHT_POLICY_PATH") or os.path.join(
    os.environ.get("HOOK_LIB_DIR", ""), "handover-preflight-policy.json"
)
try:
    with open(_POLICY_PATH, encoding="utf-8") as _f:
        _POLICY = json.load(_f)
except Exception as _exc:  # fail-open だが黙らない
    print("handover preflight:")
    print(f"- 台帳 handover-preflight-policy.json が読めません（{_exc}）。manual: skills/handover-manual/references/handover.md")
    raise SystemExit(0)


def _policy_words(key: str) -> tuple:
    return tuple(w for w in _POLICY.get(key, []) if isinstance(w, str) and w)


TRIGGER_RE = re.compile(
    "(" + "|".join(re.escape(w) for w in _policy_words("trigger_words")) + ")",
    re.IGNORECASE,
)
NEGATED_CONTINUATION_RE = re.compile(
    r"続き\s*(?:ではなくて|ではなく|ではない|でなく|でない|じゃなくて|じゃなく|じゃない|"
    r"はなく|はない|は不要|不要|はいらない|いらない|なく|ない)"
)
NEGATED_CLOSEOUT_KEYWORDS = _policy_words("negated_closeout_keywords")
NEGATED_CLOSEOUT_SUFFIXES = _policy_words("negated_closeout_suffixes")
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


# [2026-08-05][fix] mac-mini-server 配下の repo が non-pj へ落ちる誤判定を修正する。
# 背景:
# - ユーザー依頼意図: closeout で preflight が `scope: non-pj/root` を提示したが、正本である
#   `skills/handover-manual/scripts/resolve-handover-path.py` は同じ cwd を `register/root` と解決していた。
#   preflight を信じると handover が別 scope（non-pj）へ書かれ、次セッションが引き継ぎを見失う。
# - 守るべき業務ルール: preflight の project 解決は resolve-handover-path.py（正本）と一致させる。
#   正本は `/mac-mini-server/<repo>` を MAC_MINI_REPOS で個別 repo として解決するが、本 hook は
#   hermes だけを特別扱いし、register / sales / analytics / keiei-dashboard / cron-dashboard を
#   取りこぼしていた（2 箇所に同じ写像を持っていて片方だけ更新された典型）。
# - 他案不採用理由:
#   1) hook から resolve-handover-path.py を import する案: hook は各 PJ へ配布され skill の
#      配置パスが保証されないため、実行時解決に失敗すると preflight 全体が壊れる。今回は最小差分で
#      写像だけ揃え、DRY 化は AGENT-HUB Issue へ分離する。
#   2) git remote 名から機械的に決める案: worktree / fork / ミラーで別名になり、既存 scope と乖離する。
MAC_MINI_REPOS = (
    "keiei-dashboard",
    "cron-dashboard",
    "hermes",
    "analytics",
    "sales",
    "register",
)


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
    parts = path.parts
    if "mac-mini-server" in parts:
        idx = parts.index("mac-mini-server")
        if idx + 1 < len(parts) and parts[idx + 1] in MAC_MINI_REPOS:
            return parts[idx + 1]
        return "mac-mini-server"
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


# [2026-10-03][fix] #1479: scope 解決を正本 resolve-handover-path.py へ委譲する。
# 背景:
# - ユーザー依頼意図: preflight が PJ 内でも non-pj/root や別 PJ scope を返し、
#   preflight を信じた closeout が別 scope の current.md へ誤保存されるのを直す。
#   同型の再報告が #2951 / #2980 / #3278 / #3302 と続いた。
# - 守るべき業務ルール: project / scope の判定写像は resolve-handover-path.py（正本）と一致させる。
#   2 箇所に同じ写像を持つと片方だけ更新されて drift する（2026-08-05 CaD で DRY 化を本 Issue へ分離済み）。
# - 他案不採用理由:
#   1) 内蔵判定を正本へ追従更新する案: 過去 5 回 drift で再発しており、構造的に解決しないため不採用。
#   2) hook を正本 import へ全面移行する案: 正本が見つからない環境で preflight 全体が壊れるため、
#      正本優先・内蔵判定フォールバックの2段とした（フォールバック時は warn を出して黙らない）。
RESOLVER_REL = Path("skills") / "handover-manual" / "scripts" / "resolve-handover-path.py"


def candidate_resolver_paths() -> list[Path]:
    # HANDOVER_RESOLVER_PATH が設定されていればそれだけを使う（テスト用の明示指定）。
    env_path = os.environ.get("HANDOVER_RESOLVER_PATH", "").strip()
    if env_path:
        return [Path(env_path).expanduser()]
    paths: list[Path] = []
    for surface in (".claude", ".agents", ".cursor", ".kimi-code", ".gemini"):
        paths.append(project_dir / surface / RESOLVER_REL)
    paths.append(Path.home() / ".claude" / RESOLVER_REL)
    paths.append(Path.home() / ".agents" / RESOLVER_REL)
    paths.append(Path("/Users/shintaro/business/AGENT-HUB") / RESOLVER_REL)
    return paths


def resolve_scope_via_resolver(prompt: str) -> dict | None:
    """正本 resolve-handover-path.py の `scope` サブコマンドで project/scope を解決する。

    見つからない・失敗した場合は None を返し、呼び出し側が内蔵判定へフォールバックする。
    """
    for resolver in candidate_resolver_paths():
        if not resolver.is_file():
            continue
        try:
            result = subprocess.run(
                [sys.executable, str(resolver), "scope", "--cwd", str(project_dir), "--prompt", prompt],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except Exception:
            continue
        if result.returncode != 0:
            continue
        try:
            data = json.loads(result.stdout)
        except ValueError:
            continue
        if isinstance(data.get("project"), str) and isinstance(data.get("scope"), str):
            return data
    return None


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

    # [2026-10-02][fix]
    # 背景:
    # - ユーザー依頼意図: jtt-cms worktree で終了整理したのに、プロンプト本文の
    #   「jtt-cafe-pj」例示で preflight が scope=jtt-cafe-pj/root を返し、生きている
    #   引き継ぎを取り違える（#3302）。#1479 の逆向き。
    # - 守るべき業務ルール: scope は cwd / git root → project registry 解決を正とする。
    #   プロンプトキーワードが別 PJ を示しても上書きしない。警告だけ出す。
    #   同一 PJ 内のアプリ別名（評価わんこ → hyoka-wanko）は resolve-handover-path.py と同じく許可する。
    # - 他案不採用理由: 発話を常に優先する案は説明文の PJ 名に引きずられるため不採用。
    resolved = resolve_scope_via_resolver(prompt)
    resolver_used = resolved is not None
    if resolved is not None:
        cwd_project = str(resolved["project"])
        cwd_scope = str(resolved["scope"])
    else:
        cwd_project = project_from_cwd(project_dir)
        cwd_scope = scope_from_cwd(cwd_project, project_dir)
    project = cwd_project
    scope = cwd_scope
    display = cwd_scope
    project_mismatch = False
    prompt_label = ""

    if app is not None:
        prompt_project = str(app.get("project") or "")
        prompt_scope = str(app.get("canonical_name") or "")
        prompt_label = str(app.get("display_name") or prompt_project or prompt_scope)
        if prompt_project and prompt_project != cwd_project:
            project_mismatch = True
        else:
            if prompt_scope:
                scope = prompt_scope
            display = prompt_label or scope
            app_for_memory = app
    else:
        app_for_memory = None

    if project_mismatch:
        app_for_memory = None

    print("handover preflight:")
    print(f"- scope: {project}/{scope}")
    print(f"- handover_path: {handover_path(project, scope)}")
    print(f"- legacy_path: {legacy_path(project, scope)}")
    print(f"- claude_memory: {claude_memory_path(project, app_for_memory)}")
    print(f"- manual: {manual_path}")
    print(f"- reflection-policy: {reflection_path}")
    print(f"- placement-policy: {placement_path}")
    # [2026-07-18][fix]
    # 背景: closeoutでPJ固有の短期状態までGBrain候補に混ざり、人間の判断原則と技術台帳の境界が曖昧だった。
    # 守るべき業務ルール: GBrain候補はユーザーしか判断できない原則へ抽象化し、技術/PJ情報はTech GBrainかSSOTへ置く。
    # 他案不採用理由: 候補を全件GBrainへ送る案は確認負荷と重複を増やすため不採用。
    print("- closeout: 未完了 / 次回やること / Tech G-Brain候補 / GBrain候補 / SSOT昇格候補を分ける")
    print("- gbrain: 技術名・PJ固有名・短期状態は候補にせず、人間の判断原則へ抽象化")
    print("- handover_update: 終了整理のたびに current.md を最新化（未完了なしでも書く。「更新不要」は使わない）")
    if project_mismatch:
        prompt_project = str(app.get("project") or "?")
        prompt_scope = str(app.get("canonical_name") or "root")
        print(
            f"- warn: cwd と本文の PJ が食い違う。cwd を優先"
            f"（cwd={cwd_project}/{cwd_scope}, prompt={prompt_project}/{prompt_scope}）"
        )
    if project == "non-pj":
        # [2026-10-03][fix] #1479: non-pj へ落ちた時に黙らない。
        # preflight を信じて書くと個人コンテキストの current.md を汚染するため、
        # 「cwd から PJ を特定できなかった」ことを明示して AI が確認できるようにする。
        print("- warn: cwd から PJ を特定できませんでした（non-pj 扱い）。作業ディレクトリと保存先を確認してください")
    if not resolver_used:
        print("- warn: 正本 resolve-handover-path.py が見つかりません。内蔵の簡易判定を使用中（scope が古い判定の可能性あり）")
    if forced and app is None:
        print("- alias: 未検出。cwdから推定")
    elif project_mismatch:
        print(f"- app: cwd優先（本文は {prompt_label or '未検出'}）")
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
