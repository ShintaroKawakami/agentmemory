#!/usr/bin/env python3
"""Fail closed when a Git/GitHub write targets a repository outside the user's fork owner.

[2026-08-13][feat]
Background:
  - User intent: prohibit every third-party upstream write across all projects and
    require writes to finish inside a user-owned fork.
  - Business rule: inspect push, PR, and REST mutation targets by GitHub owner;
    reject unknown owners and command forms that can override the resolved target.
  - Rejected alternatives: remote-name-only checks miss foreign ``origin`` remotes,
    and shell grep alone misses valid Git/GitHub global-option spellings.  This small
    parser is kept dependency-free so every generated hook surface can run it.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
from collections.abc import Mapping
from pathlib import Path


def git(cwd: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(cwd), *args], text=True, stderr=subprocess.DEVNULL).strip()


def configured_owner() -> str:
    return subprocess.run(
        ["git", "config", "--global", "github.user"],
        text=True,
        capture_output=True,
    ).stdout.strip()


def github_owner(url: str) -> str | None:
    match = re.search(r"github\.com(?::|/)([^/]+)/[^/]+?(?:\.git)?$", url.strip())
    return match.group(1) if match else None


# [2026-09-05][fix] Claude Code on the web（クラウド）の feature branch push が
# 恒久的に fail-close していた問題への対応。
# 背景:
#   - 依頼意図: クラウドコンテナには `git config --global github.user` が存在せず、
#     同一セッション内でその設定を書き込もうとしても本ガードが拒否するため、
#     third-party upstream ではない自分の fork の feature branch への通常
#     `git push` まで恒久的に fail-close していた（jtt-system
#     `spike/cloud-hub-probe` ブランチの docs/spike-cloud-hub-probe.md「push
#     経路の追加実測」2026-09-05・`gh api` で読める。AI は GitHub API 経由の
#     fallback で push した実測あり）。
#   - 守るべき業務ルール: third-party upstream への書込み禁止という本来の目的は
#     緩めない。origin 以外の owner とは一致させない。main への直接
#     commit/push 禁止もクラウドで緩めない（本ファイルの対象外＝
#     block-main-commit.sh 側の別チェックが引き続き担当する）。
#   - 他案不採用理由:
#     1) クラウド判定時に本ガード自体を無効化する案 → third-party upstream
#        だけでなく main 直 push まで無検査で通ってしまうため不採用。
#     2) セットアップスクリプトで `git config --global github.user` を
#        書き込む案 → クラウドコンテナの生成経路は UI 依存で全経路を
#        カバーできず、書けたとしても実測どおり同一セッション内の変更が
#        本ガードに拒否される場合がありうるため不採用。
# 対応: `CLAUDE_CODE_REMOTE=true` のときだけ、`github.user` 未設定時に
#   cwd リポの `origin` remote owner を「自分の owner」とみなすフォールバックを
#   追加する。クラウドの credential はセッションに添付した repo に限定される
#   ため、その repo の origin owner ＝ 自分の owner とみなせる（この repo
#   以外には書けない以上、origin 以外を騙る余地がない）。origin が無い・
#   owner を抽出できない場合は None/空文字を返し、呼び出し側は従来どおり
#   fail-close する。
def cloud_environment() -> bool:
    return os.environ.get("CLAUDE_CODE_REMOTE", "").strip().lower() == "true"


def origin_owner(cwd: Path) -> str | None:
    try:
        url = git(cwd, "remote", "get-url", "--push", "origin")
    except subprocess.CalledProcessError:
        return None
    return github_owner(url)


def resolve_owner(cwd: Path, configured: str) -> str:
    if configured:
        return configured
    if cloud_environment():
        return origin_owner(cwd) or ""
    return ""


def effective_cwd(base: Path, segment: str, tokens: list[str], git_index: int | None = None) -> Path:
    lead = re.match(r"^\s*cd\s+([^;&|]+?)\s*&&", segment)
    cwd = base
    if lead:
        value = shlex.split(lead.group(1))
        if len(value) != 1:
            raise ValueError("ambiguous cd target")
        target = Path(value[0])
        cwd = (base / target).resolve() if not target.is_absolute() else target.resolve()
    if git_index is not None:
        index = git_index + 1
        while index < len(tokens):
            if tokens[index] == "-C":
                if index + 1 >= len(tokens):
                    raise ValueError("missing git -C target")
                target = Path(tokens[index + 1])
                cwd = (cwd / target).resolve() if not target.is_absolute() else target.resolve()
                index += 2
                continue
            if tokens[index] in {"-c", "--config-env", "--git-dir", "--work-tree", "--namespace"}:
                index += 2
                continue
            if any(tokens[index].startswith(prefix) for prefix in ("--git-dir=", "--work-tree=", "--namespace=", "--config-env=")):
                index += 1
                continue
            if tokens[index].startswith("-"):
                index += 1
                continue
            break
    return cwd


def resolve_remote_urls(cwd: Path, remote: str | None) -> list[str]:
    if remote and ("://" in remote or remote.startswith("git@")):
        return [remote]
    selected = remote
    if not selected:
        branch = git(cwd, "branch", "--show-current")
        selected = subprocess.run(["git", "-C", str(cwd), "config", "--get", f"branch.{branch}.pushRemote"], text=True, capture_output=True).stdout.strip()
        if not selected:
            selected = subprocess.run(["git", "-C", str(cwd), "config", "--get", "remote.pushDefault"], text=True, capture_output=True).stdout.strip()
        if not selected:
            upstream = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "@{upstream}"], text=True, capture_output=True).stdout.strip()
            selected = upstream.split("/", 1)[0] if "/" in upstream else "origin"
    output = git(cwd, "remote", "get-url", "--push", "--all", selected or "origin")
    return [line for line in output.splitlines() if line]


def first_positional_after(tokens: list[str], start: int) -> str | None:
    value_options = {"--repo", "-R", "--head", "--base", "--title", "--body", "--body-file", "-f", "-F", "-X", "--method"}
    index = start
    while index < len(tokens):
        token = tokens[index]
        if ">" in token or "<" in token:
            index += 1
            continue
        if token in value_options:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token
    return None


def repo_option(tokens: list[str]) -> str | None:
    values: list[str] = []
    for index, token in enumerate(tokens):
        if token in {"--repo", "-R"} and index + 1 < len(tokens):
            values.append(tokens[index + 1])
        if token.startswith("--repo="):
            values.append(token.split("=", 1)[1])
        if token.startswith("-R="):
            values.append(token.split("=", 1)[1])
        elif token.startswith("-R") and token != "-R":
            values.append(token[2:])
    if len(values) > 1:
        raise ValueError("duplicate repository target")
    return values[0] if values else None


def environment_repo(tokens: list[str], gh_index: int) -> str | None:
    for token in reversed(tokens[:gh_index]):
        if token.startswith("GH_REPO="):
            return token.split("=", 1)[1]
    return None


def gh_positionals(tokens: list[str]) -> list[str]:
    value_options = {"--repo", "-R", "--hostname"}
    positionals: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in value_options:
            index += 2
            continue
        if token.startswith(("--repo=", "--hostname=", "-R=")) or (token.startswith("-R") and token != "-R") or token.startswith("-"):
            index += 1
            continue
        positionals.append(token)
        index += 1
    return positionals


def gh_command(tokens: list[str]) -> tuple[str | None, str | None]:
    positionals = gh_positionals(tokens)
    return positionals[0] if positionals else None, positionals[1] if len(positionals) > 1 else None


def gh_is_read_only(group: str | None, action: str | None) -> bool:
    if group in {"auth", "browse", "completion", "config", "help", "search", "status", "version"}:
        return True
    read_only_actions = {
        "cache": {"list"},
        "issue": {"list", "status", "view"},
        "label": {"list"},
        "pr": {"checks", "checkout", "diff", "list", "status", "view"},
        "release": {"download", "list", "view"},
        "repo": {"clone", "list", "view"},
        "run": {"download", "list", "view", "watch"},
        "workflow": {"list", "view"},
    }
    return action in read_only_actions.get(group or "", set())


def api_method_and_endpoint(tokens: list[str]) -> tuple[str, str | None]:
    method = "GET"
    endpoint: str | None = None
    fields_imply_post = False
    value_options = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input", "--hostname", "-H", "--header"}
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in {"-X", "--method"}:
            if index + 1 >= len(tokens):
                raise ValueError("missing gh api method")
            method = tokens[index + 1].upper()
            index += 2
            continue
        if token.startswith("--method="):
            method = token.split("=", 1)[1].upper()
            index += 1
            continue
        if token.startswith("-X") and token != "-X":
            method = token[2:].upper()
            index += 1
            continue
        if token in {"-f", "-F", "--field", "--raw-field", "--input"}:
            fields_imply_post = True
        if any(token.startswith(prefix) for prefix in ("-f=", "-F=", "--field=", "--raw-field=", "--input=")):
            fields_imply_post = True
            index += 1
            continue
        if token in value_options:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        if endpoint is None:
            endpoint = token.split("?", 1)[0]
        index += 1
    if method == "GET" and fields_imply_post:
        method = "POST"
    return method, endpoint


def repository_api_owner(endpoint: str | None) -> str | None:
    if endpoint is None:
        return None
    match = re.match(r"^/?repos/([^/]+)/[^/]+(?:/|$)", endpoint)
    return match.group(1) if match else None


def option_value(tokens: list[str], names: set[str]) -> str | None:
    for index, token in enumerate(tokens):
        if token in names and index + 1 < len(tokens):
            return tokens[index + 1]
        for name in names:
            if token.startswith(name + "="):
                return token.split("=", 1)[1]
    return None


def github_owner_from_args(tokens: list[str], group: str | None, action: str | None) -> str | None:
    repo = repo_option(tokens)
    if repo:
        if re.search(r"\$|`|\$\(", repo):
            raise ValueError("dynamic repository target")
        return repo.split("/", 1)[0] if "/" in repo else None
    owner = option_value(tokens, {"--owner", "-O"})
    if owner:
        return owner
    for token in tokens:
        match = re.search(r"https?://github\.com/([^/]+)/[^/]+(?:/|$)", token)
        if match:
            return match.group(1)
    if group == "repo" and action not in {None, "clone", "fork", "list", "view"}:
        positionals = gh_positionals(tokens)
        if len(positionals) >= 3 and re.match(r"^[^/\s]+/[^/\s]+$", positionals[2]):
            return positionals[2].split("/", 1)[0]
    return None


def git_config_owner_change(tokens: list[str], git_index: int) -> str | None:
    try:
        config_index = tokens.index("config", git_index + 1)
    except ValueError:
        return None
    args = tokens[config_index + 1 :]
    if not any(flag in args for flag in {"--global", "-g"}):
        return None
    try:
        key_index = args.index("github.user")
    except ValueError:
        return None
    if any(flag in args for flag in {"--unset", "--unset-all", "--remove-section"}):
        return ""
    if "--get" in args or key_index + 1 >= len(args):
        return None
    return args[key_index + 1]


def contains_repository_write(command: str) -> bool:
    return bool(
        re.search(r"(?:^|[;&|\s])(?:\S*/)?git(?:\s+(?:-[^\s]+\s+)*)?push(?:\s|$)", command)
        or re.search(r"(?:^|[;&|\s])(?:\S*/)?gh(?:\s|$)", command)
    )


# [2026-08-27][fix] ハイフン語内部の git / push をコマンドトークンと誤判定しない
# 背景:
#   - 依頼意図: 正規化で `-` が許可文字として残るため、`\bgit\b` `\bpush\b` の単語境界が
#     ハイフン区切りのディレクトリ名・ブランチ名（例: ai-worker-git-push-text-pattern）の
#     内部にも成立し、git を一切含まない `cd <dir> && python3 <script>` が
#     「cannot prove repository target through opaque runtime payload」で誤拒否されていた
#     （同種の `git` と `push` を `.*` で繋ぐ誤検知はこれで 4 例目）。
#   - 守るべき業務ルール: 実際に git 書き込みへ言及する不透明ペイロード
#     （独立トークンの git/push、gh の書込み系グループ、github.com URL）は
#     従来どおり fail-closed で止める。止まらなくなる形を 1 つも作らない。
#   - 他案不採用理由:
#     1) 正規化の許可文字集合から `-` を外して空白に潰す案 → `feature/x-y` のような正当な
#        refspec が `feature/x` と `y` に分断され、ブランチ名の断片が独立トークン化して
#        別の誤判定を生むおそれがあるため不採用。
#     2) この判定自体を撤廃する案 → python/node/env -S 等の不透明ペイロード経由の
#        書き込みを素通しするため不採用。
# 対応: 正規化後を空白で split し、`\b` に頼らずトークン一致で判定する。
#   先頭語（git / gh）は basename 一致（`/usr/bin/git` 形の言及を従来どおり拾うため）、
#   後続語（push / gh グループ）はトークン完全一致。github.com 判定は従来どおり正規表現のまま。
def _has_ordered_tokens(tokens: list[str], lead: str, followers: frozenset[str]) -> bool:
    lead_index = next(
        (index for index, token in enumerate(tokens) if token.rsplit("/", 1)[-1].lower() == lead),
        None,
    )
    if lead_index is None:
        return False
    return any(token.lower() in followers for token in tokens[lead_index + 1 :])


def opaque_payload_mentions_repository_write(payload: str) -> bool:
    normalized = re.sub(r"[^A-Za-z0-9_./:-]+", " ", payload)
    tokens = normalized.split()

    return bool(
        _has_ordered_tokens(tokens, "git", frozenset({"push"}))
        or _has_ordered_tokens(
            tokens,
            "gh",
            frozenset({"api", "pr", "issue", "release", "repo", "workflow", "run", "secret", "variable"}),
        )
        or re.search(r"github\.com", normalized, re.IGNORECASE)
    )


def git_subcommand(tokens: list[str], git_index: int) -> tuple[str | None, int]:
    index = git_index + 1
    value_options = {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace"}
    while index < len(tokens):
        token = tokens[index]
        if token in value_options:
            index += 2
            continue
        if token.startswith(("-C", "-c", "--config-env=", "--git-dir=", "--work-tree=", "--namespace=")):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token, index
    return None, index


def mutates_write_target(command: str) -> bool:
    if re.search(r"(?:^|[;&|\s])(?:export\s+)?GH_REPO\s*=", command):
        return True
    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        for index, token in enumerate(tokens):
            if Path(token).name != "git":
                continue
            subcommand, command_index = git_subcommand(tokens, index)
            args = tokens[command_index + 1 :]
            if subcommand == "remote" and args and args[0] in {"set-url", "add", "rename", "remove"}:
                return True
            if subcommand == "config" and any(re.match(r"^remote\.[^.\s]+\.(?:url|pushurl)$", arg) for arg in args):
                return True
    return False


# [2026-10-01][fix] 伸太郎さん承認（2026-10-01「1A」）:
# Claude Code の実行環境は GIT_CONFIG_COUNT=2 /
# KEY_0=credential.interactive / KEY_1=credential.guiPrompt（認証プロンプト抑止用の
# 無害な設定）を常に入れるため、旧実装の「GIT_CONFIG_* が1つでもあれば止める」では
# AI が自分の fork へ push できない永続的な誤ブロックが発生していた。
# 守るべき業務ルール: third-party upstream 宛先すり替えの防止は緩めない。
# 他案不採用理由:
#   1) GIT_CONFIG_* を全許可する案 → remote.*.url / url.*.insteadOf などで宛先すり替え
#      が可能になり、保護の目的そのものを壊すため不採用。
#   2) キー名の部分一致（suffix/prefix）許可の案 → alias.* や branch.*.remote のような
#      ワイルドカード系を誤許可しうるため不採用。許可は完全一致・小文字比較のみ。
# 方針: キー名（VALUE ではない）だけを検査し、明示的な許可リスト（認証プロンプト抑止
#   専用の credential.interactive / credential.guiprompt）以外は従来どおり止める。
#   未知のキーは安全側に倒して止める。credential.helper は空設定であっても宛先や
#   認証経路を変えうるため危険側として扱う。VALUE はログや例外に一切出力しない。
HARMLESS_GIT_CONFIG_KEYS = frozenset({"credential.interactive", "credential.guiprompt"})

# 許可リスト方式。未知は全部止める。以下は文書化のための参考一覧
# （判定には使わない。実際の判定は HARMLESS_GIT_CONFIG_KEYS 完全一致のみ）。
DANGEROUS_GIT_CONFIG_KEY_PATTERNS = (
    "remote.*.url",
    "remote.*.pushurl",
    "url.*.insteadof",
    "url.*.pushinsteadof",
    "core.sshcommand",
    "core.hookspath",
    "core.gitproxy",
    "http.proxy",
    "credential.helper",
    "include.path",
    "includeif.*",
    "alias.*",
    "push.*",
    "branch.*.remote",
    "branch.*.pushremote",
    "core.fsmonitor",
    "core.pager",
    "core.editor",
    "init.templatedir",
)


def git_config_key_is_harmless(key: str) -> bool:
    """キー名だけ（VALUE は見ない）で無害か判定。未知キーは無害とみなさない。

    許可は完全一致・小文字比較のみ（前後の空白を取り除く挙動は持たない）。
    """
    return key.casefold() in HARMLESS_GIT_CONFIG_KEYS


def git_config_env_is_unsafe(mapping: Mapping[str, str]) -> bool:
    """GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n の対を検査する。

    無害な GIT_CONFIG_* がなければ False。GIT_CONFIG_PARAMETERS /
    GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM / GIT_CONFIG_NOSYSTEM などその他の
    GIT_CONFIG_* 変数、COUNT の不整合、欠けた対、未知キーは全て True（止める）。
    """
    config_names = {
        name
        for name in mapping
        if name == "GIT_CONFIG_COUNT" or name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))
    }
    others = {name for name in mapping if name.startswith("GIT_CONFIG_")} - config_names
    if others:
        return True
    count_raw = mapping.get("GIT_CONFIG_COUNT")
    if count_raw is None:
        return bool(config_names)
    try:
        count = int(count_raw)
    except ValueError:
        return True
    if count < 0:
        return True
    for index in range(count):
        key = mapping.get(f"GIT_CONFIG_KEY_{index}")
        value = mapping.get(f"GIT_CONFIG_VALUE_{index}")
        if key is None or value is None:
            return True
        if not git_config_key_is_harmless(key):
            return True
    return False


# [2026-10-01][fix] security-reviewer 審査指摘（export/代入の抜け穴）への対応。
# 背景:
#   - 依頼意図: validate() のセグメント分割では同一セグメントの git より前の
#     トークンと os.environ しか見ていなかったため、
#     `export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=remote.origin.pushurl ...; git push`
#     や `export GIT_DIR=/o; git push`、`HOME=/tmp/h git push` が ALLOW だった。
#   - 守るべき業務ルール: third-party upstream 宛先すり替え防止は緩めない。
#     無関係な代入（FOO=bar、GIT_SSH_COMMAND）は従来どおり通す。
#   - 他案不採用理由:
#     1) export / 前セグメント代入まで無害キーなら通す案 → export は
#        実行時に展開される値を静的に追えず、無害2キーであっても安全側に
#        倒す必要があるため不採用。
# 方針: コマンド全体のセグメントを先に走査し、export / env / declare -x /
#   typeset -x 経路で GIT_CONFIG_* 等を設定している、または前のセグメントの
#   先頭代入で GIT_CONFIG_* / GIT_DIR / HOME 等を設定していて、かつコマンド
#   全体に書込み系（contains_repository_write と同じ基準）がある場合は
#   fail-close する。同一セグメント先頭の無害2キーだけの GIT_CONFIG_* 直代入
#   は従来どおり通す（環境変数から来る分も従来どおり通す）。
GIT_TARGET_ENV_NAMES = frozenset({"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "HOME", "XDG_CONFIG_HOME"})

_ENV_VAR_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def split_env_assignment(token: str) -> tuple[str, str] | None:
    if "=" not in token:
        return None
    key, _, value = token.partition("=")
    if not _ENV_VAR_NAME.match(key):
        return None
    return key, value


def is_git_target_env_name(name: str) -> bool:
    return name in GIT_TARGET_ENV_NAMES or name.startswith("GIT_CONFIG_")


def segment_exported_env(tokens: list[str]) -> dict[str, str]:
    """export / env / declare -x / typeset -x 経由で設定される KEY=VALUE を集める。"""
    settings: dict[str, str] = {}
    for index, token in enumerate(tokens):
        if token in {"export", "declare", "typeset"}:
            if token in {"declare", "typeset"} and "-x" not in tokens[index + 1 :]:
                continue
            for arg in tokens[index + 1 :]:
                pair = split_env_assignment(arg)
                if pair:
                    settings[pair[0]] = pair[1]
        elif token == "env":
            for arg in tokens[index + 1 :]:
                if arg.startswith("-") and "=" not in arg:
                    continue
                pair = split_env_assignment(arg)
                if not pair:
                    break
                settings[pair[0]] = pair[1]
    return settings


def environment_override_blocks_write(command: str) -> str | None:
    """export / 代入経路の GIT_CONFIG_* 等をコマンド全体から検査する（理由を返す）。"""
    if not contains_repository_write(command):
        return None
    prior_env: dict[str, str] = {}
    prior_config_names: set[str] = set()
    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        plain: dict[str, str] = {}
        for token in tokens:
            pair = split_env_assignment(token)
            if pair is None:
                break
            plain[pair[0]] = pair[1]
        exported = segment_exported_env(tokens)
        if any(is_git_target_env_name(name) for name in exported):
            return "cannot prove repository write target with exported environment overrides"
        if any(name in GIT_TARGET_ENV_NAMES for name in plain):
            return "cannot prove repository write target with target environment overrides"
        combined = dict(prior_env)
        combined.update(plain)
        if any(name in GIT_TARGET_ENV_NAMES for name in prior_env):
            return "cannot prove repository write target with environment overrides in earlier command segment"
        if prior_config_names:
            return "cannot prove repository write target with environment overrides in earlier command segment"
        if any(name.startswith("GIT_CONFIG_") for name in combined) and git_config_env_is_unsafe(combined):
            return "cannot prove repository write target with target environment overrides"
        prior_env.update(plain)
        prior_config_names.update(name for name in plain if name.startswith("GIT_CONFIG_"))
        prior_config_names.update(name for name in exported if name.startswith("GIT_CONFIG_"))
    return None


def harmless_git_config_env_present() -> bool:
    """os.environ に無害2キーだけの GIT_CONFIG_* があるか（VALUE は見ない）。"""
    return any(name.startswith("GIT_CONFIG_") for name in os.environ) and not git_config_env_is_unsafe(os.environ)


def leading_git_config_assignment(command: str) -> dict[str, str]:
    """コマンド先頭セグメントの先頭代入から GIT_CONFIG_* だけを集める（VALUE は見ない）。

    連続する KEY=VALUE トークンが途切れた時点で打ち切る。export 経路や
    前のセグメントの代入は environment_override_blocks_write() が別に扱う。
    """
    segment = re.split(r"(?:&&|\|\||;|\n)", command, maxsplit=1)[0]
    try:
        tokens = shlex.split(segment)
    except ValueError:
        return {}
    assignments: dict[str, str] = {}
    for token in tokens:
        pair = split_env_assignment(token)
        if pair is None:
            break
        if pair[0].startswith("GIT_CONFIG_"):
            assignments[pair[0]] = pair[1]
    return assignments


# [2026-10-01][fix] security-reviewer 再審査指摘（無害 GIT_CONFIG の緩和の実害化）への対応。
# 背景:
#   - 依頼意図: 無害2キー（credential.interactive / credential.guiPrompt）の環境を
#     通す緩和により、サブシェル・引用符内の区切り・--rep= の略記・変数の間接指定・
#     env のオプション・config 経由の pushDefault 等の既存の穴が実害化した。
#     穴ごとに塞ぐやり方は終わりが無いため、緩和の適用範囲を厳格な単純形の
#     push だけに絞る。
#   - 守るべき業務ルール: 単純形に当たった場合でも、宛先解決（リモートが自分の
#     fork を指すか）の検査は従来どおり必ず通す。GIT_DIR / GIT_COMMON_DIR /
#     GIT_WORK_TREE が環境にあれば従来どおり止める。gh コマンドの扱いは変えない。
#   - 他案不採用理由:
#     1) 穴ごとに個別パッチを当て続ける案 → 新しい迂回形の列挙に終わりが無いため不採用。
#     2) 無害 GIT_CONFIG_* を全コマンドで通し続ける案 → 上記の穴がそのまま残るため不採用。
# 方針: 環境に無害 GIT_CONFIG_* があるとき、コマンド全体が次の厳格な単純形に
#   完全一致する場合だけ緩和を適用する。それ以外で git push 系の言及がある
#   コマンドは、緩和前の挙動（GIT_CONFIG_* があれば止める）に戻す。
#   単純形: `[cd <dir> &&] git [-C <path>] push [-u | --set-upstream]
#   [--force-with-lease] [<remote> [<refspec>]]`（コマンド全文に anchored
#   正規表現。前後の trim は
#   ASCII 空白（スペース・タブ）と末尾の改行だけで、Unicode 空白（U+3000 等）や
#   VT(\x0b) は剥がさない。内部空白は半角スペース1個。タブ・改行・連続空白・
#   メタ文字は不一致）。
#   <dir>・<path> は先頭が - でない [A-Za-z0-9_./-]+、<remote> は先頭が - でない
#   [A-Za-z0-9_.-]+、<refspec> は先頭が - でも + でもない [A-Za-z0-9_./:-]+。
#   force 用の + 付き refspec・--repo / --rep*・-o / --push-option・
#   --receive-pack・--exec・--mirror・--all・--delete・--force（単独）・
#   コマンド先頭の KEY=VALUE 代入は単純形に当たらない（＝止める）。
#   なお `-u` / `--set-upstream` の前には半角スペース1個必須で、
#   `git push--set-upstream`（空白無し）は単純形に当たらない。
#   `cd <dir> &&` の前置きは1回だけ・`&&` 区切りのみ（`;` / `||` / 引用符付き /
#   空白・~・変数を含む path は単純形に当たらない）。
# [2026-10-03][fix] issue #3239: 無害 GIT_CONFIG_* 環境（Claude Code が常駐させる
#   credential.interactive / credential.guiPrompt）で `cd <dir> && git push` と
#   remote 省略の bare `git push` が依然「cannot prove Git push target outside a
#   simple git push」で止まり、セッションごとの api_commit.py 迂回が続いていた。
#   背景:
#     - 依頼意図: issue #3239「正当な origin への push を通す」。9-30 実測で止まった
#       `git push`・`-C` 指定・`cd` 前置きの3形のうち `-C` は 10-01 の単純形緩和で
#       通るようになったが、cd 前置きと remote 省略は残っていた。
#     - 守るべき業務ルール: 緩和は引き続き厳格な単純形だけ。追加する2形は通常経路の
#       宛先解決がそのまま証明できる形に限定する（cd のセグメント追跡で cwd が確定し、
#       remote 省略は resolve_remote_urls が既定 remote を解決して owner 検査を通す）。
#     - 他案不採用理由:
#       1) api_commit 相当の正式スクリプト化（issue の代替案）→ 正当な push が
#          通せるため迂回経路を公式化する必要がない。
#       2) cd 前置きを `;` / `||` でも許す案 → 報告された形は `&&` だけであり、
#          単純形は狭く保つ方が審査済みの穴を広げないため不採用。
#   対応: 単純形に「`cd <literal> &&` 前置き（1回）」と「<remote> 省略」を足す。
_SIMPLE_GIT_PUSH_RE = re.compile(
    r"^(?:cd [A-Za-z0-9_./][A-Za-z0-9_./-]* && )?"
    r"git(?: -C [A-Za-z0-9_./][A-Za-z0-9_./-]*)? push"
    r"(?: (?:-u|--set-upstream))?"
    r"(?: --force-with-lease)?"
    r"(?: [A-Za-z0-9_.][A-Za-z0-9_.-]*"
    r"(?: [A-Za-z0-9_./:][A-Za-z0-9_./:-]*)?)?$"
)

# 単純形でないコマンドでの $VAR 間接指定の検出（緩和の適用可否判定に使う）。
_INDIRECT_PUSH_RE = re.compile(r"(?:^|[;&|]\s*)\$[A-Za-z_][A-Za-z0-9_]*\s+(?:\S*/)?push(?:\s|$)")


def is_simple_git_push(command: str) -> bool:
    """コマンド全体が厳格な単純形に完全一致するか（厳密な定義は上のコメント参照）。

    前後の trim は ASCII 空白（スペース・タブ）と末尾の改行だけ。str.strip() は
    Unicode 空白（U+3000 等）や VT(\x0b) も剥がしてしまい、anchored 完全一致の
    主張とずれるため使わない。
    """
    trimmed = re.sub(r"^[ \t]+", "", command)
    trimmed = re.sub(r"\n+$", "", trimmed)
    trimmed = re.sub(r"[ \t]+$", "", trimmed)
    return bool(_SIMPLE_GIT_PUSH_RE.fullmatch(trimmed))


def _tokens_mention_git_push(tokens: list[str]) -> bool:
    for index, token in enumerate(tokens):
        if Path(token).name.lower() != "git":
            continue
        subcommand, _ = git_subcommand(tokens, index)
        if subcommand == "push":
            return True
    return False


def mentions_git_push(command: str) -> bool:
    """git push 系の言及があるか（git の直後のサブコマンドが push・$VAR 間接指定）。

    git 直後のグローバルオプション（-C <path>、-c <k=v>、--git-dir=…、
    --work-tree=…、--no-pager 等）は読み飛ばしてサブコマンドを決める。
    それ以外のサブコマンド（log、grep、status、diff 等）と、git 実行の後ろに
    ある単語 push（`git log --grep=push`、`git grep push`、
    `git status && echo push later`、`git log --oneline | grep push` 等）は
    言及に当たらない（security-reviewer 最終審査 2026-10-01 指摘による修正。
    旧実装の「git の後ろのどこかに push の語」判定はこれらを誤ブロックした）。
    shlex 分割に失敗する形や引用符内の区切りは、正規化トークンでも判定する。
    """
    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = []
        if _tokens_mention_git_push(tokens):
            return True
    normalized = re.sub(r"[^A-Za-z0-9_./:-]+", " ", command).split()
    return bool(_tokens_mention_git_push(normalized)) or bool(_INDIRECT_PUSH_RE.search(command))


def has_git_target_environment(tokens: list[str], git_index: int) -> bool:
    dangerous = {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE"}
    command_env: dict[str, str] = {}
    for token in tokens[:git_index]:
        if "=" not in token:
            continue
        key, _, value = token.partition("=")
        if key in dangerous:
            return True
        if key.startswith("GIT_CONFIG_"):
            command_env[key] = value
    if any(key in os.environ for key in dangerous):
        return True
    if git_config_env_is_unsafe(os.environ):
        return True
    return git_config_env_is_unsafe(command_env)


# [2026-08-13][fix] issue #1733: `git cherry` は read-only（upstream との未取り込みコミット比較）。
# `cherry-pick` だけ既知だと closeout 監査の複合 read-only が「unknown Git subcommand cherry」で
# third-party write と誤表示される。書き込み系を増やさず比較専用 cherry だけ追加する。
KNOWN_GIT_SUBCOMMANDS = {
    "add", "am", "apply", "archive", "bisect", "blame", "branch", "bundle",
    "cat-file", "check-ignore", "check-ref-format", "checkout", "cherry",
    "cherry-pick", "clean", "clone", "commit", "config", "describe", "diff",
    "diff-tree", "fetch", "for-each-ref", "format-patch", "fsck", "gc", "grep",
    "hash-object", "init", "lfs", "log", "ls-files", "ls-remote", "maintenance",
    "merge", "merge-base", "mv", "notes", "pull", "push", "range-diff", "rebase",
    "reflog", "remote", "reset", "restore", "rev-list", "rev-parse", "revert",
    "rm", "show", "show-ref", "sparse-checkout", "stash", "status", "submodule",
    "switch", "tag", "update-index", "update-ref", "worktree",
}

KNOWN_GH_GROUPS = {
    "alias", "api", "attestation", "auth", "browse", "cache", "codespace",
    "completion", "config", "extension", "gist", "gpg-key", "issue", "label",
    "org", "pr", "project", "release", "repo", "ruleset", "run", "search",
    "secret", "ssh-key", "status", "variable", "workflow",
}


# [2026-10-03][fix] issue #2897: 書込み系 git/gh サブコマンドを1つも含まない
# 複合コマンドは早期許可する。
# 背景:
#   - 依頼意図: `cd <repo> && cat f | head -30 && echo === && git worktree list | grep x`
#     （read-only だけの複合）が「cannot prove repository write target across
#     conditional or piped cd」で、また `gh issue list --search "... python3 ..."` が
#     「cannot prove repository target through opaque runtime payload」で誤拒否され、
#     正当な調査コマンドが都度単発への分割を強制されていた。
#   - 守るべき業務ルール: upstream 書込み系の検査（git push / lfs / config 宛先変更・
#     gh 書込み系・REST 非 GET・不透明ペイロード）は緩めない。早期許可は
#     「静的に upstream write が起こりえない」と証明できる形だけに限定し、
#     証明できない形は従来どおり fail-closed の解析経路へ送る。
#     main 直 commit/push 保護は block-main-commit.sh 側の別チェックが本判定の
#     後にも走るため、ローカル変更系（commit/checkout/branch -f 等）を
#     ここで通してもその保護は弱まらない。
#   - 他案不採用理由:
#     1) cd+pipe 検査の git/gh 正規表現だけを write 限定に絞る案 →
#        `gh issue list --search` 側（opaque payload 誤検知）が残るため不採用。
#     2) 引用符内を全部削ってから走査する案 → `bash -c "..."` / `python3 -c "..."` の
#        ペイロードは文字列リテラル内にあり、削ると実検知が死ぬため不採用。
#     3) git サブコマンドを純粋 read の allowlist に限定する案 → `commit` 等の
#        ローカル変更は upstream を書かず本ガードの守備範囲外であり、なおかつ
#        既知サブコマンド一覧との差分管理が複雑になるため不採用。代わりに
#        「upstream write / 宛先変更を起こしうるサブコマンド」だけを除外する。

# インタプリタ・シェル・ペイロードを文字列で受け取る wrapper 等の実行名。
# これらがトークンに1つでもあれば中身を静的に追えないため証明不能（False）に倒す。
# トークンがそのまま見える wrapper（nice / command / time 等）は含めない —
# 内側の git/gh トークンはそのまま走査される。
_OPAQUE_EXECUTABLE_NAMES = frozenset(
    {
        "node", "nodejs", "ruby", "perl", "php", "lua", "osascript", "expect",
        "eval", "env", "xargs", "source",
        "bash", "sh", "zsh", "dash", "ksh", "fish",
        "ssh", "sudo", "make", "just", "rake", "bundle",
        "npm", "npx", "yarn", "pnpm", "pipenv", "poetry", "cargo", "go",
        "docker", "kubectl", "watch", "parallel", "tmux", "screen",
    }
)

# upstream write または宛先設定変更を起こしうる git サブコマンド。
#   push : upstream への書込み本体。
#   lfs  : `git lfs push` が LFS サーバへのアップロードを持つ。
#   config: `github.user` / `url.*.insteadOf` の変更は本ガードの判定基準そのものを
#           書き換えるため、読み取り形（--get 等）も含めて証明不能側に倒し、
#           従来の解析経路（git_config_owner_change / url.insteadOf 検査）に任せる。
_GIT_TARGET_WRITE_SUBCOMMANDS = frozenset({"push", "lfs", "config"})


def _git_token_blocks_read_only_proof(tokens: list[str], git_index: int) -> bool:
    subcommand, _ = git_subcommand(tokens, git_index)
    if subcommand is None:
        return False  # グローバルオプションのみ（git --version 等）は書込みえない
    if subcommand not in KNOWN_GIT_SUBCOMMANDS:
        return True  # alias / 未知サブコマンドは従来どおり解析経路で fail-closed
    return subcommand in _GIT_TARGET_WRITE_SUBCOMMANDS


def _gh_token_blocks_read_only_proof(tokens: list[str], gh_index: int) -> bool:
    args = tokens[gh_index + 1 :]
    group, action = gh_command(args)
    if group is None:
        return False  # bare gh / gh --version / gh --help は書込みえない
    if group not in KNOWN_GH_GROUPS:
        return True  # 未知グループは従来どおり解析経路で fail-closed
    if group == "api":
        try:
            method, _endpoint = api_method_and_endpoint(args[args.index("api") + 1 :])
        except ValueError:
            return True
        return method not in {"GET", "HEAD"}
    return not gh_is_read_only(group, action)


def command_is_provably_read_only(command: str) -> bool:
    """コマンド全体が upstream write / 宛先設定変更を起こしえないと静的に証明できるか。

    セグメント分割・shlex 解析に失敗する形、shell substitution / 変数展開
    （`$` / バッククォート / `<(` / `>(`。変数間接指定 `$G push` を含む）、
    およびインタプリタ・シェル・wrapper 経由の不透明ペイロードは証明不能として
    False。git は KNOWN かつ push / lfs / config 以外、gh は read-only
    group/action または api の GET/HEAD のみ True 側に倒す。
    引用符内の文字列（`--search "..."` 等）は1トークンのため実行名に一致しない。
    """
    if re.search(r"[$`]", command) or "<(" in command or ">(" in command:
        return False
    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            return False
        for index, token in enumerate(tokens):
            executable = Path(token).name
            if (
                token == "."
                or executable.startswith("python")
                or executable in _OPAQUE_EXECUTABLE_NAMES
            ):
                return False
            if executable == "git" and _git_token_blocks_read_only_proof(tokens, index):
                return False
            if executable == "gh" and _gh_token_blocks_read_only_proof(tokens, index):
                return False
    return True


def validate(command: str, base: Path) -> tuple[bool, str]:
    owner = configured_owner()
    override_reason = environment_override_blocks_write(command)
    if override_reason:
        return False, override_reason
    # [2026-10-03][fix] issue #2897: upstream write が起こりえないと静的に証明できる
    # 複合コマンドはここで許可する。証明不能な形（不透明ペイロード・shell
    # substitution・push/lfs/config・gh 書込み系・未知サブコマンド）は従来どおり
    # 下の fail-closed 解析へ送る。
    if command_is_provably_read_only(command):
        return True, ""
    # [2026-10-01][fix] 無害 GIT_CONFIG_* の緩和は厳格な単純形の push だけに限定する。
    # 単純形以外で git push 系を言及するコマンドは、緩和前の挙動に戻して止める。
    # 緩和が効くのは os.environ の無害2キー（またはコマンド先頭の無害2キーだけの
    # GIT_CONFIG_* 直代入）で、どちらの経路でもコマンドは単純形に完全一致する
    # 必要がある（security-reviewer 最終審査 2026-10-01 指摘: 環境に GIT_CONFIG_*
    # が無い時のコマンド先頭の無害2キー付与は旧実装どおり止める）。
    # gh コマンド・read-only コマンド・GIT_CONFIG_* が無い環境はこのゲートの外。
    command_config = leading_git_config_assignment(command)
    relaxed_git_config_env = harmless_git_config_env_present() or (
        bool(command_config) and not git_config_env_is_unsafe(command_config)
    )
    if relaxed_git_config_env and not is_simple_git_push(command) and mentions_git_push(command):
        return False, "cannot prove Git push target outside a simple git push with GIT_CONFIG_* environment"
    # [2026-10-03][fix] issue #2897: opaque payload 判定は interpreter 実行名より
    # 後ろのペイロード部分だけを走査する。コマンド全体を走査すると、先に置いた
    # read-only の `gh issue list` や `--search "... python3 ..."` のような
    # 引用符内の文字列が実行中の言及として誤検知されていた。
    runtime_match = re.search(r"(?:^|[;&|\s])(?:\S*/)?(?:python\d*|node|ruby|perl|osascript)\s+", command)
    if runtime_match and opaque_payload_mentions_repository_write(command[runtime_match.end() :]):
        return False, "cannot prove repository target through opaque runtime payload"
    env_split_match = re.search(r"(?:^|[;&|\s])env\s+(?:-S|--split-string)\S*\s*", command)
    if env_split_match and opaque_payload_mentions_repository_write(command[env_split_match.end() :]):
        return False, "cannot prove repository target through env split-string wrapper"
    if ("$(" in command or "`" in command or "<(" in command or ">(" in command) and re.search(r"\b(?:git|gh)\b", command):
        return False, "cannot prove repository target through shell substitution"
    if contains_repository_write(command) and mutates_write_target(command):
        return False, "repository write target may be changed inside the same command"
    current_cwd = base
    cwd_known = True
    if re.search(r"\bcd\b", command) and re.search(r"\|\||\|", command):
        if re.search(r"(?:^|[;&|\s])(?:[^\s/]+/)*(?:git|gh)(?:\s|$)", command):
            return False, "cannot prove repository write target across conditional or piped cd"
    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            if re.search(r"\b(?:git\s+push|gh\s+(?:pr\s+create|api))\b", segment):
                return False, "ambiguous repository write command"
            continue
        if tokens and tokens[0] == "cd":
            if len(tokens) != 2:
                cwd_known = False
            else:
                target = Path(tokens[1])
                current_cwd = (current_cwd / target).resolve() if not target.is_absolute() else target.resolve()
            continue
        for index, token in enumerate(tokens):
            executable = Path(token).name
            if executable in {"python", "python3", "node", "ruby", "perl", "osascript"}:
                payload = " ".join(tokens[index + 1 :])
                if opaque_payload_mentions_repository_write(payload):
                    return False, f"cannot prove repository target through opaque {executable} payload"
            if executable == "env" and any(arg == "-S" or arg.startswith("--split-string") for arg in tokens[index + 1 :]):
                payload = " ".join(tokens[index + 1 :])
                if opaque_payload_mentions_repository_write(payload):
                    return False, "cannot prove repository target through env split-string wrapper"
            if executable == "eval" and contains_repository_write(" ".join(tokens[index + 1 :])):
                return False, "cannot prove repository target through eval"
            if executable in {"bash", "sh", "zsh"}:
                try:
                    shell_c_index = tokens.index("-c", index + 1)
                except ValueError:
                    shell_c_index = -1
                if shell_c_index >= 0:
                    if shell_c_index + 1 >= len(tokens):
                        return False, "ambiguous shell wrapper"
                    nested_allowed, nested_reason = validate(tokens[shell_c_index + 1], current_cwd)
                    if not nested_allowed:
                        return False, nested_reason
            if executable == "git":
                subcommand, _ = git_subcommand(tokens, index)
                if subcommand:
                    alias = subprocess.run(
                        ["git", "-C", str(current_cwd), "config", "--get", f"alias.{subcommand}"],
                        text=True,
                        capture_output=True,
                    ).stdout.strip()
                    if alias:
                        return False, f"cannot prove repository target for Git alias {subcommand}"
                    if subcommand not in KNOWN_GIT_SUBCOMMANDS:
                        return False, f"cannot prove repository target for unknown Git subcommand {subcommand}"
                requested_owner = git_config_owner_change(tokens, index)
                if requested_owner is not None and requested_owner != owner:
                    return False, f"github.user is fixed outside repository write commands to {owner or 'unconfigured'}"
                git_command, git_command_index = git_subcommand(tokens, index)
                if git_command == "config" and any(
                    re.match(r'^url\..+\.(?:insteadOf|pushInsteadOf)$', arg, re.IGNORECASE)
                    for arg in tokens[git_command_index + 1 :]
                ):
                    return False, "Git URL rewrite configuration cannot be changed through repository commands"
            if executable == "git" and "push" in tokens[index + 1 :]:
                if not cwd_known:
                    return False, "cannot prove Git push working directory"
                if has_git_target_environment(tokens, index):
                    return False, "cannot prove Git push target with Git target environment overrides"
                push_index = tokens.index("push", index + 1)
                # [2026-10-01][fix] security-reviewer 審査指摘（--repo の抜け穴）:
                # `git push --repo=URL` / `--repo URL` は git push 自身の宛先指定
                # オプションであり、既定リモート解決をすり替える。owner 一致
                # 判定より前に必ず止める。VALUE(URL) は理由文字列に出さない。
                push_args = tokens[push_index + 1 :]
                if any(arg == "--repo" or arg.startswith("--repo=") for arg in push_args):
                    return False, "cannot prove Git push target with --repo"
                global_options = tokens[index + 1 : push_index]
                if any(
                    option in {"-c", "--config-env", "--git-dir", "--work-tree"}
                    or (option.startswith("-c") and option != "-c")
                    or (option.startswith("-C") and option != "-C")
                    or option.startswith(("--config-env=", "--git-dir=", "--work-tree="))
                    for option in global_options
                ):
                    return False, "cannot prove Git push target with target-overriding global options"
                cwd = effective_cwd(current_cwd, segment, tokens, index)
                effective_owner = resolve_owner(cwd, owner)
                if not effective_owner:
                    return False, "git config --global github.user is required before repository writes"
                remote = first_positional_after(tokens, push_index + 1)
                try:
                    target_owners = [github_owner(url) for url in resolve_remote_urls(cwd, remote)]
                except (subprocess.CalledProcessError, ValueError):
                    return False, "cannot prove Git push target is the user's fork"
                if not target_owners or any(target_owner is None or target_owner.casefold() != effective_owner.casefold() for target_owner in target_owners):
                    rendered = ",".join(target_owner or "unknown" for target_owner in target_owners) or "unknown"
                    return False, f"Git push target owner {rendered} is not fork owner {effective_owner}"
            if executable == "gh":
                args = tokens[index + 1 :]
                group, action = gh_command(args)
                if group not in KNOWN_GH_GROUPS:
                    return False, f"cannot prove repository target for unknown gh command {group or 'unknown'}"
                if group == "api":
                    api_index = args.index("api")
                    try:
                        method, endpoint = api_method_and_endpoint(args[api_index + 1 :])
                    except ValueError:
                        return False, "cannot prove REST write target"
                    if method not in {"GET", "HEAD"}:
                        # [2026-09-05][fix] Codex 🟡: 通常の gh 書込み分岐と異なり、この REST
                        # 書込み分岐だけ current_cwd を直接 resolve_owner へ渡していた
                        # （segment 内の `cd <dir> &&` を反映する effective_cwd を経由しない）。
                        # `cd <repo> && gh api ...` の cwd 解決を他分岐と揃える。
                        effective_owner = resolve_owner(effective_cwd(current_cwd, segment, tokens), owner) if cwd_known else owner
                        if not effective_owner:
                            return False, "git config --global github.user is required before repository writes"
                        target_owner = repository_api_owner(endpoint)
                        if target_owner is None or target_owner.casefold() != effective_owner.casefold():
                            return False, f"REST write target owner {target_owner or 'unknown'} is not fork owner {effective_owner}"
                    continue
                if gh_is_read_only(group, action):
                    continue
                if not cwd_known:
                    return False, "cannot prove GitHub command working directory"
                cwd = effective_cwd(current_cwd, segment, tokens)
                effective_owner = resolve_owner(cwd, owner)
                if not effective_owner:
                    return False, "git config --global github.user is required before repository writes"
                env_repo = environment_repo(tokens, index) or os.environ.get("GH_REPO")
                try:
                    target_owner = github_owner_from_args(args, group, action)
                except ValueError:
                    return False, "cannot prove GitHub write target with duplicate repository selectors"
                if group == "repo" and action == "fork":
                    destination_owner = option_value(args, {"--org"}) or effective_owner
                    if destination_owner.casefold() != effective_owner.casefold():
                        return False, f"fork destination owner {destination_owner} is not fork owner {effective_owner}"
                    continue
                if target_owner is None and env_repo:
                    target_owner = env_repo.split("/", 1)[0] if "/" in env_repo else None
                if target_owner is None:
                    try:
                        urls = resolve_remote_urls(cwd, "origin")
                        owners = [github_owner(url) for url in urls]
                        target_owner = owners[0] if len(owners) == 1 else None
                    except subprocess.CalledProcessError:
                        return False, "cannot prove GitHub write target is the user's fork"
                if target_owner is None or target_owner.casefold() != effective_owner.casefold():
                    return False, f"GitHub write target owner {target_owner or 'unknown'} is not fork owner {effective_owner}"
    return True, ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--command", required=True)
    args = parser.parse_args()
    allowed, reason = validate(args.command, Path(args.cwd).resolve())
    if not allowed:
        print(reason)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
