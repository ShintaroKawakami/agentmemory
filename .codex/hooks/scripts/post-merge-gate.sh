#!/usr/bin/env bash
# PreToolUse(Bash) post-merge gate.
# `gh pr merge` の直接実行を止め、マージ担当者が ccprmerd 正本を読む wrapper へ誘導する。
# [2026-06-20][feat]
# 背景:
#   - ユーザー依頼意図: マージ担当者がマージ作業の中で必ず `;ccprmerd` 相当の
#     Typinator 正本を読み、マージ後確認まで含めて進める運用にしたい。
#   - 守るべき業務ルール: マージ処理は「PRレビュー → マージ時チェックリスト読み込み →
#     マージ → 同じチェックリストで反映確認」までを一連の作業として扱う。
#   - 他案不採用理由: SKILL.md に手順だけ書く案は、AI が直接 `gh pr merge` を叩く経路を残し、
#     ccprmerd 読み込み漏れを機械的に防げないため不採用。
# 対応: PreToolUse(Bash) で直接 `gh pr merge` を deny し、`merge-pr.py` 経由へ誘導する。
# [2026-07-18][fix]
# 背景:
#   - ユーザー依頼意図: dirty cleanup のレビューで、`xargs gh pr merge` が直接マージ禁止を迂回できると判明した。
#   - 守るべき業務ルール: 実行ラッパーを挟んでも `gh pr merge` は merge-pr.py 経由へ統一する。
#   - 他案不採用理由: 単純な文字列検索は説明文を誤検知し、`xargs` 全面禁止は無関係な利用まで止めるため不採用。
# 対応: xargs のオプションを除いた実行コマンドを既存の gh サブコマンド解析へ渡す。
# [2026-07-18][fix]
# 背景:
#   - ユーザー依頼意図: web2context のレビューで、`nohup gh pr merge` が直接マージ禁止を迂回できると判明した。
#   - 守るべき業務ルール: 実行方法を変える標準ラッパーを挟んでも merge-pr.py 経由を強制する。
#   - 他案不採用理由: `nohup` だけを個別検知する案は `setsid` / `nice` で同じ抜け道を残すため不採用。
# 対応: 副作用のない実行ラッパー3種と各オプションを prefix parser で正規化する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

# telemetry(harness-checkup): deny/バイパスを記録。lib 無しでも壊れない no-op fallback。
# 注意: `set -euo pipefail` 下で `. 存在しないファイル` は `||` フォールバックを素通りして
# シェルごと終了する(bash の source 失敗は errexit 免除の対象外)。存在チェックを先に行い、
# 未配布(telemetry-lib.sh 未同期の配布先)でも deny 本体を絶対に壊さない。
if [ -f "$SCRIPT_DIR/telemetry-lib.sh" ]; then
  . "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || true
fi
if ! declare -f agent_hub_telemetry_log >/dev/null 2>&1; then
  agent_hub_telemetry_log() { :; }
fi

read_stdin

COMMAND="$(extract_field command)"

if [ -z "$COMMAND" ]; then
  printf '{"continue":true}\n'
  exit 0
fi

if [ "${AGENT_HUB_ALLOW_DIRECT_GH_PR_MERGE:-0}" = "1" ]; then
  # telemetry(harness-checkup): 緊急バイパスを記録(黙って通さない)。
  agent_hub_telemetry_log hook_bypass post-merge-gate allow '{"env":"AGENT_HUB_ALLOW_DIRECT_GH_PR_MERGE"}' 2>/dev/null || true
  printf '{"continue":true}\n'
  exit 0
fi

if COMMAND_TEXT="$COMMAND" python3 - <<'PY'
from __future__ import annotations

import os
import re
import shlex
import sys

command = os.environ.get("COMMAND_TEXT", "")
RESERVED_PREFIXES = {"if", "while", "until"}

def normalize_newline_separators(text: str) -> str:
    """Turn unquoted newlines into command separators before tokenization."""
    result: list[str] = []
    quote = None
    escaped = False
    for char in text:
        if escaped:
            result.append(char)
            escaped = False
            continue
        if char == "\\" and quote != "'":
            result.append(char)
            escaped = True
            continue
        if quote is not None:
            result.append(char)
            if char == quote:
                quote = None
            continue
        if char in {"'", '"'}:
            quote = char
            result.append(char)
            continue
        result.append(";" if char in "\r\n" else char)
    return "".join(result)

def split_segments(text: str) -> list[list[str]]:
    try:
        lexer = shlex.shlex(normalize_newline_separators(text), posix=True, punctuation_chars=";&|(){}")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except Exception:
        return []
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token and all(ch in ";&|(){}" for ch in token):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments

def split_segments_with_dynamic_commands(text: str) -> list[list[str]]:
    """Keep the normal parse and add a view where command expansions are one token."""
    masked = re.sub(r"\$\([^()\r\n]*\)", "$DYNAMIC_COMMAND", text)
    masked = re.sub(r"\$\{[^{}\r\n]+\}", "$DYNAMIC_COMMAND", masked)
    segments = split_segments(text)
    if masked != text:
        segments.extend(split_segments(masked))
    return segments

def iter_backticks(text: str) -> list[str]:
    chunks: list[str] = []
    start = None
    escaped = False
    quote = None
    for index, char in enumerate(text):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote == "'":
            if char == "'":
                quote = None
            continue
        if start is None and char in {"'", '"'}:
            # 二重引用符内の ' は literal（single-quote モードに入れない）。
            # これを怠ると `echo "'`...`'"` で backtick command-sub を見逃す。
            if char == "'" and quote == '"':
                continue
            quote = None if quote == char else char
            continue
        if char != "`":
            continue
        if start is None:
            start = index + 1
        else:
            chunks.append(text[start:index])
            start = None
    return chunks

def iter_dollar_subshells(text: str) -> list[str]:
    chunks: list[str] = []
    index = 0
    quote = None
    escaped = False
    while index < len(text):
        char = text[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if char == "'" and quote != '"':
            quote = None if quote == "'" else "'"
            index += 1
            continue
        if char == '"' and quote != "'":
            quote = None if quote == '"' else '"'
            index += 1
            continue
        if quote == "'" or not text.startswith("$(", index):
            index += 1
            continue
        start = index
        depth = 1
        cursor = start + 2
        inner_quote = None
        inner_escaped = False
        while cursor < len(text):
            char = text[cursor]
            if inner_escaped:
                inner_escaped = False
            elif char == "\\":
                inner_escaped = True
            elif inner_quote:
                if char == inner_quote:
                    inner_quote = None
            elif char in {"'", '"'}:
                inner_quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    chunks.append(text[start + 2:cursor])
                    break
            cursor += 1
        index = cursor + 1
    return chunks

def strip_prefix(tokens: list[str]) -> list[str]:
    index = 0
    while index < len(tokens):
        token = os.path.basename(tokens[index])
        if "=" in tokens[index] and tokens[index].split("=", 1)[0].replace("_", "A").isalnum():
            index += 1
            continue
        if token in {"command", "builtin", "exec"}:
            index += 1
            if index < len(tokens) and tokens[index] == "-p":
                index += 1
            continue
        if token == "time":
            index += 1
            if index < len(tokens) and tokens[index] == "-p":
                index += 1
            continue
        if token == "sudo":
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                opt = tokens[index]
                index += 1
                if opt in {"-u", "-g", "-h", "-p", "-C", "-T"} and index < len(tokens):
                    index += 1
            continue
        if token == "env":
            index += 1
            while index < len(tokens):
                opt = tokens[index]
                if opt in {"-u", "--unset", "-C", "--chdir"} and index + 1 < len(tokens):
                    index += 2
                    continue
                if opt.startswith("-"):
                    index += 1
                    continue
                if "=" in opt and opt.split("=", 1)[0].replace("_", "A").isalnum():
                    index += 1
                    continue
                break
            continue
        if token in {"nohup", "setsid"}:
            index += 1
            while index < len(tokens):
                opt = tokens[index]
                if opt == "--":
                    index += 1
                    break
                if not opt.startswith("-"):
                    break
                index += 1
            continue
        if token == "nice":
            index += 1
            while index < len(tokens):
                opt = tokens[index]
                if opt == "--":
                    index += 1
                    break
                if opt in {"-n", "--adjustment"} and index + 1 < len(tokens):
                    index += 2
                    continue
                if opt.startswith("--adjustment=") or (opt.startswith("-") and opt[1:].lstrip("+").isdigit()):
                    index += 1
                    continue
                break
            continue
        break
    return tokens[index:]

def gh_subcommand(tokens: list[str]) -> list[str]:
    tokens = strip_prefix(tokens)
    if not tokens or os.path.basename(tokens[0]) != "gh":
        return []
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            index += 1
            break
        if token in {"-R", "--repo", "--hostname", "--config"}:
            index += 2
            continue
        if token.startswith("-R") and len(token) > 2:
            index += 1
            continue
        if token.startswith("--repo=") or token.startswith("--hostname=") or token.startswith("--config="):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return tokens[index:]

def indirect_subcommand(tokens: list[str]) -> list[str]:
    """Fail closed when a dynamic command position could expand to gh."""
    tokens = strip_prefix(tokens)
    if not tokens:
        return []
    command = tokens[0]
    is_simple_var = command.startswith("$") and command[1:].replace("_", "A").isalnum()
    is_dynamic_expansion = (
        (command.startswith("${") and command.endswith("}"))
        or command.startswith("$(")
        or command.startswith("`")
    )
    if not (is_simple_var or is_dynamic_expansion):
        return []
    # [2026-07-18][fix]
    # 背景:
    #   - PR1018再レビューで `${GH:-gh}` / `${GH?err}` / `$(printf gh)` のような
    #     command-position expansionが単純変数判定を外れ、直接mergeを実行できると判明した。
    #   - 守るべき業務ルール: 実行ファイルを静的に確定できない `pr merge` はfail-closedにする。
    #   - 他案不採用理由: shell parameter expansionを評価してghか判定する案は、default/error演算子や
    #     command substitutionの実行環境を再実装することになり、別形式で再びfail-openするため不採用。
    # 対応: 動的command tokenの後ろからpr subcommand境界を探し、展開形式を限定せず拒否する。
    for index, token in enumerate(tokens[1:], start=1):
        if token == "pr":
            return tokens[index:]
    return []

def strip_pr_options(tokens: list[str]) -> list[str]:
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in {"-R", "--repo", "--hostname", "--config"}:
            index += 2
            continue
        if token.startswith("-R") and len(token) > 2:
            index += 1
            continue
        if token.startswith("--repo=") or token.startswith("--hostname=") or token.startswith("--config="):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return tokens[index:]

def xargs_command(tokens: list[str]) -> list[str]:
    """Return the command executed by xargs, or an empty list."""
    tokens = strip_prefix(tokens)
    if not tokens or os.path.basename(tokens[0]) != "xargs":
        return []
    options_with_value = {
        "-a", "--arg-file", "-d", "--delimiter", "-E", "--eof", "-I", "--replace", "-J",
        "-L", "--max-lines", "-n", "--max-args", "-P", "--max-procs",
        "-R", "-S", "-s", "--max-chars",
    }
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if token in options_with_value:
            index += 2
            continue
        if token.startswith("--") and "=" in token:
            index += 1
            continue
        if token.startswith(("-d", "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s")) and len(token) > 2:
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return tokens[index:]

def find_exec_command(tokens: list[str]) -> list[str]:
    """Return the command passed to find -exec/-execdir, or an empty list."""
    tokens = strip_prefix(tokens)
    if not tokens or os.path.basename(tokens[0]) != "find":
        return []
    for index, token in enumerate(tokens):
        if token in {"-exec", "-execdir"}:
            return tokens[index + 1:]
    return []

def candidate_commands(segment: list[str]) -> list[list[str]]:
    candidates = [segment]
    for index, token in enumerate(segment[:-1]):
        if token in RESERVED_PREFIXES:
            candidates.append(segment[index + 1:])
    return candidates

def contains_generated_shell_command(text: str, depth: int) -> bool:
    """Detect a direct merge emitted by printf/echo inside command substitution."""
    for chunk in iter_dollar_subshells(text) + iter_backticks(text):
        for segment in split_segments(chunk):
            stripped = strip_prefix(segment)
            if not stripped or os.path.basename(stripped[0]) not in {"echo", "printf"}:
                continue
            for token in stripped[1:]:
                if contains_direct_merge(token, depth + 1):
                    return True
    return False

def contains_direct_merge(text: str, depth: int = 0) -> bool:
    if depth > 3:
        return False
    for chunk in iter_backticks(text):
        if contains_direct_merge(chunk, depth + 1):
            return True
    for chunk in iter_dollar_subshells(text):
        if contains_direct_merge(chunk, depth + 1):
            return True
    for segment in split_segments_with_dynamic_commands(text):
        for candidate in candidate_commands(segment):
            commands = [candidate]
            wrapped = xargs_command(candidate)
            if wrapped:
                commands.append(wrapped)
            find_wrapped = find_exec_command(candidate)
            if find_wrapped:
                commands.append(find_wrapped)
            for nested_tokens in (wrapped, find_wrapped):
                if nested_tokens:
                    nested_text = " ".join(shlex.quote(token) for token in nested_tokens)
                    if contains_direct_merge(nested_text, depth + 1):
                        return True
            for command_tokens in commands:
                sub = gh_subcommand(command_tokens)
                if not sub:
                    sub = indirect_subcommand(command_tokens)
                if sub and sub[0] == "pr":
                    pr_sub = strip_pr_options(sub[1:])
                    if pr_sub and pr_sub[0] == "merge":
                        return True
        stripped = strip_prefix(segment)
        if stripped and os.path.basename(stripped[0]) == "eval":
            for token in stripped[1:]:
                if contains_direct_merge(token, depth + 1):
                    return True
        if stripped and os.path.basename(stripped[0]) in {"bash", "sh", "zsh"}:
            for i, token in enumerate(stripped[1:], start=1):
                if token in {"-c", "-lc"} and i + 1 < len(stripped):
                    payload = stripped[i + 1]
                    if contains_generated_shell_command(payload, depth) or contains_direct_merge(payload, depth + 1):
                        return True
    return False

sys.exit(0 if contains_direct_merge(command) else 1)
PY
then
  # telemetry(harness-checkup): deny を記録(fail-open)。
  agent_hub_telemetry_log hook_deny post-merge-gate deny 2>/dev/null || true
  # [2026-07-31][docs] Issue #1105: 回避策を deny メッセージに明示する
  # 背景:
  #   - 報告は「PR 本文（--body）に説明目的でコマンド例を書いただけでブロックされる」だったが、実測すると
  #     ブロックされるのは **二重引用符内に backtick / $() で書いた場合だけ**で、これは bash が実際に
  #     コマンド置換として実行する形＝真陽性だった（単一引用符・素のテキスト・--body-file は通る）。
  #   - よって Issue の第一案「判定対象を実行される先頭コマンドに限定する」は採らない。採ると
  #     `--body "$(...)"` のような本物の実行経路を見逃し、正しい安全検査を弱めるため。
  #   - 実際に不足していたのは「なぜ止まったか・どう書けば通るか」の案内なので、Issue の第二案
  #     （メッセージへ回避策を明示）だけを実施する。
  emit_deny "[hook:post-merge-gate] 直接の gh pr merge は禁止です。マージ担当者が ccprmerd 正本を読むため、python3 ~/business/AGENT-HUB/skills/post-merge/scripts/merge-pr.py <PR番号> を使ってください。
説明文・PR 本文にコマンド例を書いただけで止まった場合: 二重引用符の中の backtick や \$() は bash が実際に実行するため検知対象です。単一引用符で囲むか --body-file を使ってください。
リリース昇格 / forward-merge（head が main 等の長寿命ブランチ）の PR は、既定の --squash だと履歴が乖離します。--method merge --no-delete-branch --no-cleanup を明示してください。
緊急時のみ AGENT_HUB_ALLOW_DIRECT_GH_PR_MERGE=1 を明示できます。"
fi

printf '{"continue":true}\n'
