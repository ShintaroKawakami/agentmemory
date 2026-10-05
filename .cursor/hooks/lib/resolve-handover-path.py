#!/usr/bin/env python3
"""Resolve Handover triggers, scope, classification, and Git-ignored paths.

This helper intentionally uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


DEFAULT_ROOT = Path.home() / ".agent-hub" / "handovers"
LEGACY_TAKEOVER_ROOT = Path.home() / ".agent-hub" / "takeovers"

USER_TRIGGERS = (
    "終了整理",
    "Closeout整理",
    "続き",
    "ふり返り",
    "振り返り",
    "ふりかえり",
    "引継ぎ書つくって",
    "引き継ぎ",
    "作業終了",
    "handover",
    "takeover",
    "continuation",
)
COMPAT_TRIGGERS = ("continuation-closeout",)
ALL_TRIGGERS = USER_TRIGGERS + COMPAT_TRIGGERS
NEGATED_CONTINUATION_RE = re.compile(
    r"続き\s*(?:ではなくて|ではなく|ではない|でなく|でない|じゃなくて|じゃなく|じゃない|"
    r"はなく|はない|は不要|不要|はいらない|いらない|なく|ない)"
)
NEGATED_CLOSEOUT_KEYWORDS = (
    "終了整理",
    "Closeout整理",
    "ふり返り",
    "振り返り",
    "ふりかえり",
    "作業終了",
)
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

PROTECTED_PREFIXES = (
    ".claude/",
    ".codex/",
    ".cursor/",
    ".gemini/",
    ".kimi-code/",
    ".augment/",
    ".opencode/",
    ".githooks/",
    "claude-plans/",
    "node_modules/",
)

# [2026-10-02][fix]
# 背景:
#   - ユーザー依頼意図: 登録済み Laravel PJ mixpost-app の終了整理が non-pj/root に落ちる誤りを直す
#     （AGENT-HUB #3278）。docs/project-registry.yaml / DISTRIBUTION.yaml / hook-registry.yaml には
#     既に mixpost-app がある。
#   - 守るべき業務ルール: jtt-system / jtt-cms / AGENT-HUB / hermes の既存判定は変えない。
#     未登録は non-pj。既存 handover ファイルは移動・削除しない。
#   - 他案不採用理由: 実行時に AGENT-HUB の YAML 台帳を読む案は、skill が配布先 PJ に置かれた状態で
#     台帳パスが無いため不採用。git remote 名だけで決める案は worktree / fork / ミラーで既存
#     scope と乖離するため不採用。
# 対応: 配布先でも動く ROOT_HINTS へ、登録済み mixpost-app の path identity を追加する。
# [2026-10-03][fix]
# 背景:
#   - ユーザー依頼意図: ~/mcp-servers 直下の横断メンテ終了整理が non-pj/root に落ち、
#     個人コンテキスト（法律相談等）の current.md を汚染しかけたのを直す（AGENT-HUB #2980）。
#     同じ誤分類クラス: #2951（mattermost-chat）/ #2943（google-review）。
#   - 守るべき業務ルール: mcp-servers は ~25 個の開発リポジトリを抱えるコンテナ。
#     コンテナ直下は mcp-servers/root、配下の各 repo ディレクトリは mcp-servers/<repo> scope
#     で分け、repo 間でも current.md を混ぜない。未登録は引き続き non-pj。
#     既存 handover ファイルは移動・削除しない。
#   - 他案不採用理由: 各 repo を個別 project として列挙する案（MAC_MINI_REPOS 型）は、
#     repo の追加・改名で固定リストが陳腐化し再発するため不採用。実行時に YAML 台帳を読む案は
#     配布先に台帳パスが無いため不採用（#3278 と同じ判断）。
# 対応: ROOT_HINTS へ mcp-servers コンテナの path identity を追加し、scope_from_cwd で
# 直下の子ディレクトリ名を scope として返す。
# [2026-10-03][fix]
# 背景:
#   - ユーザー依頼意図: 登録済みの独立Gitリポ ~/mac-mini-server/mattermost-chat の終了整理が
#     mac-mini-server/root へ誤分類され、別PJの current.md を上書きする危険があったのを直す
#     （AGENT-HUB #2951）。同じ誤分類クラス: #2943（google-review）。
#   - 守るべき業務ルール: MAC_MINI_REPOS 固定集合の既存判定は変えない。直下の子ディレクトリが
#     実在する Git リポジトリ（.git あり）なら独立PJとしてその名前の project へ解決し、
#     .git の無い未登録ディレクトリは引き続き mac-mini-server/root。既存 handover ファイルは
#     移動・削除しない。
#   - 他案不採用理由: MAC_MINI_REPOS へ mattermost-chat / google-review を列挙追加する案は、
#     repo の追加・改名で固定リストが陳腐化し同型バグが再発するため不採用（#2980 と同じ判断）。
#     実行時に AGENT-HUB の YAML 台帳を読む案は、skill が配布先 PJ に置かれた状態で台帳パスが
#     無いため不採用。git remote 名で決める案は fork / ミラーで乖離するため不採用。
# 対応: project_from_root_path の mac-mini-server 分岐で、直下の子ディレクトリ名が
# MAC_MINI_REPOS に無くても <child>/.git が実在すればその名前を project として返す。
# [2026-10-03][fix]
# 背景:
#   - ユーザー依頼意図: 登録済みPJ ~/ugreen-nas の終了整理が non-pj/root に落ちる誤りを直す
#     （AGENT-HUB #3443）。docs/project-registry.yaml と DISTRIBUTION.yaml には既に ugreen-nas が
#     登録済み（canonical_name: ugreen-nas、path: /Users/shintaro/ugreen-nas）。旧名 synology-nas は
#     registry の alias だが実ディレクトリは ugreen-nas のみ。
#   - 守るべき業務ルール: 既存PJ・本来のnon-pjの判定は変えない。既存 handover ファイルは
#     移動・削除しない。router の write 許可は承認済み write roots の外にある ~/ugreen-nas を
#     対象外とする fail-close を維持し、未承認の対象拡張では解消しない。
#   - 他案不採用理由: 実行時に AGENT-HUB の YAML 台帳を読む案は、skill が配布先 PJ に置かれた
#     状態で台帳パスが無いため不採用（#3278 と同じ判断）。git remote 名だけで決める案は
#     worktree / fork / ミラーで乖離するため不採用。
# 対応: ROOT_HINTS へ登録済み ugreen-nas の path identity を追加する。
# [2026-10-04][fix] 登録済みスマレジPJと外部MCP worktreeの引継ぎ先を守る。
# remote名の推測や既存記憶の移動は行わず、正本のpath identityを使う。
ROOT_HINTS = [
    ("AGENT-HUB", re.compile(r"/AGENT-HUB(?:/|$)")),
    ("jtt-system", re.compile(r"/jtt-system(?:/|$)")),
    ("jtt-apps", re.compile(r"/jtt-apps(?:/|$)")),
    ("smaregi-mobile-order", re.compile(r"/smaregi-mobile-order(?:/|$)")),
    ("mixpost-app", re.compile(r"/mixpost-app(?:/|$)")),
    ("jtt-cms", re.compile(r"/jtt-cms(?:/|$)")),
    ("jtt-cafe-video-workspace", re.compile(r"/jtt-cafe-video-workspace(?:/|$)")),
    ("jtt-cafe-pj", re.compile(r"/jtt-cafe-pj(?:/|$)")),
    ("mcp-servers", re.compile(r"/mcp-servers(?:/|$)")),
    ("non-pj", re.compile(r"/non-pj(?:/|$)")),
    ("hermes", re.compile(r"/mac-mini-server/hermes(?:/|$)|/hermes(?:/|$)")),
    ("mac-mini-server", re.compile(r"/mac-mini-server(?:/|$)")),
    ("ugreen-nas", re.compile(r"/ugreen-nas(?:/|$)")),
]

MAC_MINI_REPOS = {
    "keiei-dashboard",
    "cron-dashboard",
    "hermes",
    "analytics",
    "sales",
    "register",
}

APP_ALIASES = {
    "jtt-system": {
        "admin-console": ["管理コンソール", "admin-console", "admin", "console"],
        "de-panda": ["出パンダ", "でぱんだ", "de-panda", "depanda", "panda", "シフト"],
        "hyoka-wanko": ["評価わんこ", "ひょうかわんこ", "wanko", "hyoka"],
        "tame-risu": ["ためりす", "タメリス", "tame-risu", "tamerisu", "在庫", "発注"],
        "chie-fukuro": ["知恵ふくろう", "ちえふくろう", "chie", "fukuro"],
        "hotopi-ai": ["ほとぴぃ", "ほとぴー", "hotopi-ai", "hotopi", "横断AI", "RAG"],
        "nikka-pengin": ["日課ぺんぎん", "にっかぺんぎん", "nikka-pengin", "nikka", "pengin"],
        "koban-neko": ["小判ねこ", "こばんねこ", "koban-neko", "koban", "neko"],
    },
    "jtt-cms": {
        "yoyakuma": ["よやくま", "予約", "reservation", "yoyakuma"],
        "orielle-hp": ["オリエルHP", "orielle", "orielle-hp"],
        "akihabara-hp": ["秋葉原店HP", "秋葉原HP", "fs-akihabara"],
    },
    "jtt-apps": {},
    "jtt-cafe-video-workspace": {
        "video-factory": ["video-factory", "動画制作", "動画作成", "かき氷動画", "kakigori"],
    },
}

# [2026-10-03][fix] jtt-cms の apps/ ディレクトリ名 → handover scope 正名の対応（AGENT-HUB #2475）。
# scope_from_cwd が slug(dir名) をそのまま返すと apps/reservation が "reservation" scope になり、
# prompt alias の "yoyakuma" と別 current.md に分かれてしまうため正名へ寄せる。
JTT_CMS_APP_SCOPES = {
    "reservation": "yoyakuma",
    "orielle": "orielle-hp",
    "fs-akihabara": "akihabara-hp",
}

GBRAIN_FORBIDDEN_RE = re.compile(
    r"(AI\s*worker|worker|pytest|pnpm|npm|branch|PR\s*#?\d+|commit|worktree|"
    r"CI|error|エラー|コマンド|テスト|ログ|バグ|cron|MCP|OTP|PIN|(?<![A-Za-z0-9_])DB(?:名)?(?![A-Za-z0-9_])|"
    r"監査ログ|audit\s*log|paid|unpaid|通知書|納付額|請求額|支払額|"
    r"(?:[¥￥]\s*[0-9０-９][0-9０-９,，]*|[0-9０-９][0-9０-９,，]*\s*円))",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Scope:
    project: str
    scope: str
    reason: str


def normalize(value: str) -> str:
    return re.sub(r"\s+", "", value).casefold()


def normalize_for_negation(value: str) -> str:
    return NEGATED_PUNCTUATION.sub("", value.casefold())


def slug(value: str) -> str:
    value = value.strip()
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-._")
    return value or "root"


def is_handover_trigger(prompt: str) -> bool:
    folded = normalize(prompt)
    for trigger in ALL_TRIGGERS:
        normalized_trigger = normalize(trigger)
        if normalized_trigger not in folded:
            continue
        if normalized_trigger == normalize("続き") and NEGATED_CONTINUATION_RE.search(prompt):
            continue
        if normalized_trigger in {normalize(word) for word in NEGATED_CLOSEOUT_KEYWORDS}:
            if is_negated_closeout_trigger(prompt, trigger):
                continue
        return True
    return False


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


def is_takeover_trigger(prompt: str) -> bool:
    """Backward-compatible alias for old integrations."""
    return is_handover_trigger(prompt)


def project_from_root_path(root: str) -> str | None:
    """Match one candidate repo root against AGENT-HUB markers and ROOT_HINTS."""
    root_path = Path(root)
    if (root_path / "DISTRIBUTION.yaml").is_file() and (root_path / "hook-registry.yaml").is_file():
        return "AGENT-HUB"
    for project, pattern in ROOT_HINTS:
        if pattern.search(root):
            if project == "mac-mini-server":
                parts = root_path.parts
                try:
                    idx = parts.index("mac-mini-server")
                except ValueError:
                    return project
                if idx + 1 < len(parts):
                    child = parts[idx + 1]
                    if child in MAC_MINI_REPOS or (Path(*parts[: idx + 2]) / ".git").exists():
                        return child
            return project
    return None


def canonical_worktree_root(cwd: str) -> str | None:
    """Return the main repository root when cwd sits inside a linked git worktree.

    A linked worktree has a ``.git`` *file* containing ``gitdir: <main>/.git/worktrees/<name>``;
    the ``commondir`` file inside that gitdir points back to the shared ``.git`` directory,
    whose parent is the canonical repository root. Regular clones (``.git`` directory) and
    submodules (no ``commondir``) return None.
    """
    for directory in (Path(cwd), *Path(cwd).parents):
        marker = directory / ".git"
        if not marker.exists():
            continue
        if not marker.is_file():
            return None
        try:
            first_line = marker.read_text(encoding="utf-8", errors="replace").splitlines()[0]
        except (OSError, IndexError):
            return None
        if not first_line.startswith("gitdir:"):
            return None
        gitdir = Path(first_line.split(":", 1)[1].strip())
        if not gitdir.is_absolute():
            gitdir = (directory / gitdir).resolve()
        try:
            common = (gitdir / "commondir").read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if not common:
            return None
        common_dir = Path(common)
        if not common_dir.is_absolute():
            common_dir = (gitdir / common_dir).resolve()
        return str(common_dir.parent)
    return None


def package_name(root: Path) -> str | None:
    try:
        data = json.loads((root / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    name = data.get("name")
    return name if isinstance(name, str) and name else None


def project_from_cwd(cwd: str) -> str:
    # [2026-10-03][fix]
    # 背景:
    #   - ユーザー依頼意図: jtt-cms の worktree（例: jtt-cms-worktrees/<slug>）で終了整理を
    #     実行すると、ROOT_HINTS が `/jtt-cms/` に一致せず pnpm-workspace.yaml + apps/ の
    #     フォールバックで jtt-system/root へ誤記録されるのを直す（AGENT-HUB #2475）。
    #   - 守るべき業務ルール: 既存の path 一致・pnpm フォールバック・non-pj 既定は維持し、
    #     worktree の正本 root と package.json name を canonical identity として使う。
    #   - 他案不採用理由: ROOT_HINTS に `jtt-cms-*` 等の接尾辞一致を足す案は worktree の
    #     置き場所・命名に依存し、任意パスの worktree で再発するため不採用。git remote 名
    #     だけで決める案は fork / ミラーで乖離するため不採用（#3278 と同じ判断）。
    # 対応: .git ファイル → gitdir → commondir で正本 root を辿り ROOT_HINTS を再評価し、
    # pnpm フォールバックは package.json name が登録PJ名ならそれを優先する。
    project = project_from_root_path(cwd)
    if project:
        return project
    canonical = canonical_worktree_root(cwd)
    if canonical and canonical != cwd:
        project = project_from_root_path(canonical)
        if project:
            return project
    cwd_path = Path(cwd)
    if (cwd_path / "pnpm-workspace.yaml").is_file() and (cwd_path / "apps").is_dir():
        name = package_name(cwd_path)
        if name:
            for project, _pattern in ROOT_HINTS:
                if name.casefold() == project.casefold():
                    return project
        return "jtt-system"
    return "non-pj"


def scope_from_prompt(project: str, prompt: str) -> str | None:
    folded = prompt.casefold()
    for scope, names in APP_ALIASES.get(project, {}).items():
        for name in [scope, *names]:
            if name and name.casefold() in folded:
                return scope
    return None


def scope_from_cwd(project: str, cwd: str) -> str:
    path = Path(cwd)
    parts = path.parts
    if project in {"jtt-system", "jtt-cms"} and "apps" in parts:
        idx = parts.index("apps")
        if idx + 1 < len(parts):
            app = slug(parts[idx + 1])
            if project == "jtt-cms":
                return JTT_CMS_APP_SCOPES.get(app, app)
            return app
    if project == "mcp-servers" and "mcp-servers" in parts:
        idx = parts.index("mcp-servers")
        if idx + 1 < len(parts):
            return slug(parts[idx + 1])
        return "root"
    if project == "AGENT-HUB":
        for marker in ("skills", "hook-library", "snippet-prompts", "agent-memory"):
            if marker in parts:
                idx = parts.index(marker)
                if idx + 1 < len(parts):
                    return slug(parts[idx + 1])
                return slug(marker)
    return "root"


def resolve_scope(cwd: str, prompt: str = "", explicit_scope: str | None = None) -> Scope:
    project = project_from_cwd(cwd)
    if explicit_scope:
        return Scope(project, slug(explicit_scope), "explicit")
    prompt_scope = scope_from_prompt(project, prompt)
    if prompt_scope:
        return Scope(project, prompt_scope, "prompt alias")
    scope = scope_from_cwd(project, cwd)
    # [2026-10-04][fix] mcp-servers内のlinked worktree名も保存先scopeに使わない。
    # rootの場合だけ戻す案では、同じコンテナ内の別名worktreeが別PJ扱いになる。
    if project == "mcp-servers":
        canonical = canonical_worktree_root(cwd)
        if canonical:
            scope = scope_from_cwd(project, canonical)
    return Scope(project, scope, "cwd")


def storage_path(project: str, scope: str, root: Path = DEFAULT_ROOT) -> Path:
    return root.expanduser() / slug(project) / slug(scope) / "current.md"


def archive_path(project: str, scope: str, date_text: str, root: Path = DEFAULT_ROOT) -> Path:
    return storage_path(project, scope, root).parent / "archive" / f"{slug(date_text)}.md"


def resolve(cwd: str, prompt: str, root: Path = DEFAULT_ROOT) -> Path:
    scope = resolve_scope(cwd, prompt)
    return storage_path(scope.project, scope.scope, root)


def is_git_managed_handover_path(path: str) -> bool:
    text = str(path).replace("\\", "/")
    ignored_roots = (
        "/.agent-hub/handovers/",
        "~/.agent-hub/handovers/",
        "/.agent-hub/takeovers/",
        "~/.agent-hub/takeovers/",
    )
    return not any(marker in text or text.startswith(marker) for marker in ignored_roots)


def is_git_managed_takeover_path(path: str) -> bool:
    """Backward-compatible alias. Legacy takeover files remain Git-ignored."""
    return is_git_managed_handover_path(path)


def is_protected_path(path: str) -> bool:
    text = path.replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    name = Path(text).name
    if name == ".env" or name.startswith(".env."):
        return True
    return any(text == prefix.rstrip("/") or text.startswith(prefix) for prefix in PROTECTED_PREFIXES)


def can_save_to_gbrain(text: str) -> bool:
    return GBRAIN_FORBIDDEN_RE.search(text) is None


def classify_information(text: str) -> str:
    folded = text.casefold()
    if any(token in folded for token in ("全pj", "確定ルール", "命名", "ガードレール", "運用手順", "ssot")):
        return "ssot"
    if any(
        token in folded
        for token in (
            "伸太郎",
            "判断軸",
            "思想",
            "考え方",
            "開発原則",
            "pm判断",
            "横展開",
            "既存アプリ",
            "新しい仕組み",
        )
    ):
        return "gbrain" if can_save_to_gbrain(text) else "reject-gbrain"
    if any(token in folded for token in ("再利用", "回避", "worker", "pytest", "pnpm", "エラー", "テスト実行", "落とし穴")):
        return "tech-gbrain"
    if any(token in folded for token in ("pr", "branch", "未完了", "検証待ち", "current.md", "worktree")):
        return "handover"
    return "handover"


def canonical_classification(value: str) -> str:
    if value == "takeover":
        return "handover"
    return value


def as_json(scope: Scope) -> str:
    return json.dumps(scope.__dict__, ensure_ascii=False, sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")

    p_path = sub.add_parser("path")
    p_path.add_argument("--cwd", default=str(Path.cwd()))
    p_path.add_argument("--prompt", default="")
    p_path.add_argument("--root", default=str(DEFAULT_ROOT))

    p_scope = sub.add_parser("scope")
    p_scope.add_argument("--cwd", default=str(Path.cwd()))
    p_scope.add_argument("--prompt", default="")
    p_scope.add_argument("--scope")

    p_trigger = sub.add_parser("trigger")
    p_trigger.add_argument("prompt")

    p_classify = sub.add_parser("classify")
    p_classify.add_argument("text")

    args = parser.parse_args()
    command = args.command or "path"

    # [2026-08-02][fix] サブコマンド無しの既定 path 実行が AttributeError で落ちていた。
    # 背景:
    #   - ユーザー依頼意図: 終了整理の入口で `resolve-handover-path.py` を素で叩いたら
    #     `AttributeError: 'Namespace' object has no attribute 'cwd'` で停止した（2026-08-02 実測）。
    #   - 守るべき業務ルール: `command = args.command or "path"` が示すとおり、サブコマンド省略時は
    #     path として動くのが仕様。サブパーサの既定値は親 Namespace に載らないため、ここで補う。
    #   - 他案不採用理由: サブコマンドを必須にする案は、既存の呼び出し（素で叩く運用）を壊すため不採用。
    cwd = getattr(args, "cwd", None) or str(Path.cwd())
    prompt = getattr(args, "prompt", "") or ""
    root = getattr(args, "root", None) or str(DEFAULT_ROOT)

    if command == "path":
        print(resolve(cwd, prompt, Path(root)).expanduser())
        return 0
    if command == "scope":
        print(as_json(resolve_scope(cwd, prompt, args.scope)))
        return 0
    if command == "trigger":
        print("true" if is_handover_trigger(args.prompt) else "false")
        return 0
    if command == "classify":
        print(classify_information(args.text))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
