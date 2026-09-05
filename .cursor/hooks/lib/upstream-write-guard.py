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
def opaque_payload_mentions_repository_write(payload: str) -> bool:
    normalized = re.sub(r"[^A-Za-z0-9_./:-]+", " ", payload)
    tokens = normalized.split()

    def has_ordered_tokens(lead: str, followers: frozenset[str]) -> bool:
        lead_index = next(
            (index for index, token in enumerate(tokens) if token.rsplit("/", 1)[-1].lower() == lead),
            None,
        )
        if lead_index is None:
            return False
        return any(token.lower() in followers for token in tokens[lead_index + 1 :])

    return bool(
        has_ordered_tokens("git", frozenset({"push"}))
        or has_ordered_tokens(
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


def has_git_target_environment(tokens: list[str], git_index: int) -> bool:
    dangerous = {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE"}
    for token in tokens[:git_index]:
        if "=" not in token:
            continue
        key = token.split("=", 1)[0]
        if key in dangerous or key.startswith("GIT_CONFIG_"):
            return True
    return any(key in os.environ for key in dangerous) or any(key.startswith("GIT_CONFIG_") for key in os.environ)


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


def validate(command: str, base: Path) -> tuple[bool, str]:
    owner = configured_owner()
    if re.search(r"(?:^|[;&|\s])(?:\S*/)?(?:python\d*|node|ruby|perl|osascript)\s+", command) and opaque_payload_mentions_repository_write(command):
        return False, "cannot prove repository target through opaque runtime payload"
    if re.search(r"(?:^|[;&|\s])env\s+(?:-S|--split-string)", command) and opaque_payload_mentions_repository_write(command):
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
