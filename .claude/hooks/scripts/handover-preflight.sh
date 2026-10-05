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


# [2026-10-04][fix] #1501: scope 解決の写像を正本 resolver 1 箇所へ集約する。
# 背景:
# - ユーザー依頼意図: hook 内蔵の簡易判定（MAC_MINI_REPOS / checks）が正本
#   `skills/handover-manual/scripts/resolve-handover-path.py` と drift し続けた
#   二重管理を解消したい（#1500 / #1479 で写像は揃えたが構造は残ったまま）。
# - 守るべき業務ルール: project / scope 判定の正本は resolve-handover-path.py のみ。
#   hook は正本を参照し、hook 側に project リストの複製を持たない（reference-over-hardcode）。
# - 他案不採用理由:
#   1) 写像を YAML 台帳へ切り出す案: 正本の判定は単なるリストでなく worktree 正本
#      root 解決 / .git 実在判定 / package.json name / jtt-cms scope 正名まで含むため、
#      台帳では表現しきれない。
#   2) hook が各 PJ の CLAUDE.md canonical project を読む案: scope（アプリ別名・
#      worktree）まで解決できず、正本との完全一致を保てない。
#   3) 内蔵フォールバックを残す案: fallback が古いまま drift する二重管理の再来のため不採用。
# 対応: 正本の byte 同一ミラーを hook-library/lib/ へ同梱する（lib/ は deploy-hooks が
# 全配布先の hooks/lib/ へ一括コピーするため、skill が無い配布先でも
# ../lib/resolve-handover-path.py に正本が来る）。ミラーは tests/test_handover_manual.py の
# 一致テストが正本との byte 同一を強制するため drift しない（symlink は harness
# generation ledger が canonical asset として拒否するため不採用）。
# 候補順は PJ 内 skill 配置 → 同梱 → ユーザ全体 → AGENT-HUB 正本パス。
# どこにも無ければ scope を推定せず unresolved + warn で黙らない。
RESOLVER_REL = Path("skills") / "handover-manual" / "scripts" / "resolve-handover-path.py"


def bundled_resolver_path() -> Path | None:
    """hook payload 同梱の正本 resolver（各PJ hooks/lib/resolve-handover-path.py）。"""
    lib_dir = os.environ.get("HOOK_LIB_DIR", "").strip()
    if not lib_dir:
        return None
    return Path(lib_dir) / "resolve-handover-path.py"


def candidate_resolver_paths() -> list[Path]:
    # HANDOVER_RESOLVER_PATH が設定されていればそれだけを使う（テスト用の明示指定）。
    env_path = os.environ.get("HANDOVER_RESOLVER_PATH", "").strip()
    if env_path:
        return [Path(env_path).expanduser()]
    paths: list[Path] = []
    for surface in (".claude", ".agents", ".cursor", ".kimi-code", ".gemini"):
        paths.append(project_dir / surface / RESOLVER_REL)
    bundled = bundled_resolver_path()
    if bundled is not None:
        paths.append(bundled)
    paths.append(Path.home() / ".claude" / RESOLVER_REL)
    paths.append(Path.home() / ".agents" / RESOLVER_REL)
    paths.append(Path("/Users/shintaro/business/AGENT-HUB") / RESOLVER_REL)
    return paths


def resolve_scope_via_resolver(prompt: str) -> tuple[dict, Path] | None:
    """正本 resolve-handover-path.py の `scope` サブコマンドで project/scope を解決する。

    戻り値は (scope JSON, 使用した resolver のパス)。見つからない・失敗した場合は None。
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
            return data, resolver
    return None


def differing_resolver_paths(used: Path) -> list[Path]:
    """使用中 resolver と内容が異なる候補を列挙する（版ずれの自己申告用）。

    hook payload と skill 配置は別系統で配布されるため、どちらかが古いまま
    停滞しうる。食い違いを warn できれば原因切り分けが 1 手で済む（#1501 コメント）。
    """
    try:
        used_real = used.resolve()
        used_bytes = used.read_bytes()
    except OSError:
        return []
    differs: list[Path] = []
    for candidate in candidate_resolver_paths():
        try:
            if candidate.resolve() == used_real or not candidate.is_file():
                continue
            if candidate.read_bytes() != used_bytes:
                differs.append(candidate)
        except OSError:
            continue
    return differs


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
    resolved_pair = resolve_scope_via_resolver(prompt)
    if resolved_pair is not None:
        resolved, used_resolver = resolved_pair
        cwd_project = str(resolved["project"])
        cwd_scope = str(resolved["scope"])
        resolver_differs = differing_resolver_paths(used_resolver)
    else:
        # #1501: 写像の複製は持たない。正本がどこにも無い時は推定せず unresolved。
        used_resolver = None
        resolver_differs = []
        cwd_project = "unresolved"
        cwd_scope = "unresolved"
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
    if used_resolver is not None:
        print(f"- resolver: {used_resolver}")
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
    if used_resolver is None:
        # [2026-10-04][fix] #1501: 正本不在では scope を推定しない（誤 scope を出す方が害）。
        print("- warn: 正本 resolve-handover-path.py が見つかりません（skill 配置・hook 同梱の両方なし）。scope を確定できないため unresolved としています")
    elif resolver_differs:
        # [2026-10-04][fix] #1501 コメント: hook 側が「自分の版が古いかもしれない」を
        # 自己申告する。配布物同士の食い違いを出せば原因切り分けが 1 手で済む。
        others = ", ".join(str(path) for path in resolver_differs)
        print(f"- warn: 別候補の resolver と内容が異なります（使用中: {used_resolver} / 相違: {others}）。どちらかの配布物が古い可能性があります")
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
