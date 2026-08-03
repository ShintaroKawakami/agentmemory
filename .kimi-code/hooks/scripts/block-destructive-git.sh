#!/usr/bin/env bash
# PreToolUse(Bash) destructive git guard.
# AI/自動化が tracked local changes を暗黙に破棄する事故を止める。
# [2026-06-14][feat]
# 背景:
#   - ユーザー依頼意図: AI 横断作業中の `git reset --hard` / `git clean -f` / `git checkout --` による
#     tracked local changes の暗黙破棄を止めたい。
#   - 守るべき業務ルール: ローカル変更の破棄は、差分確認後に明示許可した復旧作業だけに限定する。
#   - 他案不採用理由: 破壊的 git をルール文だけで禁止する案は、別セッション WIP の事故を機械的に止められないため不採用。
# 対応: 安全な dry-run / unstage は許可し、作業ツリーを破棄する git 操作だけを PreToolUse でブロックする。

set -uo pipefail

# telemetry(harness-checkup): deny/バイパスを記録。lib 無しでも壊れない no-op fallback。
. "$(dirname "$0")/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }

input="$(cat)"

command="$(
  INPUT_JSON="${input}" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    data = json.loads(os.environ.get("INPUT_JSON", "{}"))
except json.JSONDecodeError:
    data = {}
tool_input = {}
if isinstance(data.get("tool_input"), dict):
    tool_input = data["tool_input"]
elif isinstance(data.get("toolInput"), dict):
    tool_input = data["toolInput"]
print(tool_input.get("command") or "")
PY
)"

allow_json() {
  printf '{"continue": true}\n'
}

# [2026-08-03][fix] deny メッセージを「コマンド行の先頭に書けば通る」という誤った案内から、
# 実際に効く手順（セッションの環境変数として設定）へ正す。
# 背景:
#   - ユーザー依頼意図: 2026-08-03 jtt-cms 作業中、旧メッセージの案内どおり
#     `AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git ...` をコマンド行の先頭に書いて再実行したが、
#     再びブロックされた。66行目の bypass 判定はこの hook プロセス自身の環境変数だけを見ており、
#     Bash ツールは呼び出しごとに cwd がリセットされるため実際の再実行はほぼ必ず
#     `cd <dir> && AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git ...` の形になる。1745行目付近の
#     inline bypass はコマンド全体の最初のトークンが裸の代入直後の `git` である場合だけしか
#     救済せず、`cd &&` 等が前に付くと機能しない（実測で再現・恒久的に効く手段ではない）。
#   - 守るべき業務ルール: AI エージェントは自己判断で破壊的 git を通せてはならない。bypass は
#     利用者がセッションの環境変数として明示設定した場合だけに限定する設計を維持する
#     （bypass 判定ロジック自体は変更しない・本対応はメッセージ文言のみ）。
#   - 他案不採用理由: 「コマンド行の先頭に書けば常に効くようにする」案は、AI が自分の発行する
#     コマンド文字列だけで bypass を成立させられてしまい、破壊的 git を自己判断で通す抜け道になる
#     ため不採用。メッセージを正直にし、実際に効く手段（利用者へのセッション環境変数設定の依頼、
#     または hook にかからない代替コマンド）を案内する方針を採る。
block_json() {
  local label="$1"
  # telemetry(harness-checkup): deny を記録。fail-open(記録失敗は無視)。
  agent_hub_telemetry_log hook_deny block-destructive-git deny "{\"label\":\"$label\"}" 2>/dev/null || true
  HOOK_LABEL="$label" python3 - <<'PY'
import json
import os

label = os.environ.get("HOOK_LABEL", "")
reason_lines = [
    f"[hook:block-destructive-git] destructive git command blocked: {label}。",
    "ローカル変更を暗黙に破棄しないため停止しました。",
    (
        "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 は、このセッションの環境変数として設定されている"
        "必要があります。コマンド行の先頭に書くだけでは効きません"
        "（cd 等が前に付くと届かないため）。"
    ),
    (
        "AI はこの環境変数を自分で設定できません。復旧が必要な場合は、利用者に"
        "「このセッションで AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 を設定してください」と依頼してください。"
    ),
    (
        "単一ファイルを HEAD の内容へ戻すだけなら、この hook にかからない "
        "`git show HEAD:<path> > <path>` で足りることが多いです。"
    ),
]
reason = "\n".join(reason_lines)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
}

if [ -z "${command}" ]; then
  allow_json
  exit 0
fi

if [ "${AGENT_HUB_ALLOW_DESTRUCTIVE_GIT:-0}" = "1" ]; then
  # telemetry(harness-checkup): 緊急バイパスを記録(黙って通さない)。
  agent_hub_telemetry_log hook_bypass block-destructive-git allow '{"env":"AGENT_HUB_ALLOW_DESTRUCTIVE_GIT"}' 2>/dev/null || true
  allow_json
  exit 0
fi

# [2026-08-02][fix] path-qualified git executable を token 境界で裸の `git` に正規化する。
# 背景:
#   - ユーザー依頼意図: `/usr/bin/git` や空白を含む引用符付き path でも、`reset --hard` /
#     `clean` 等を取り逃がさないようにする。
#   - 守るべき業務ルール: 実行 token の basename が `git` の場合だけ、裸の `git` と同じく
#     fail-closed で止める。`/tmp/git tools/notgit` のような非 git executable は許可する。
#   - 他案不採用理由: Bash regex で path の slash・quote・空白を列挙する案は token 境界を失い、
#     新しい path 表記や git を含む別 executable の誤検出を招く。PJ ごとの hook 手修正も不採用。
# 対応: Python 標準 `shlex` で実行 token を解決し、`os.path.basename(token) == "git"` のときだけ
#     その token を `git` に置換してから、後段の Bash 判定へ渡す。
# [2026-08-02][fix] nice/nohup を安全に解析し、未知・解決不能な前置きを fail-closed にする。
# 背景:
#   - ユーザー依頼意図: 標準ラッパー経由の `nice git ...` / `nohup git ...` でも破壊的 Git を止めたい。
#   - 守るべき業務ルール: 既知の引数だけを消費し、曖昧な option や欠落した command は許可しない。
#   - 他案不採用理由: 任意の `-...` を無条件に読み飛ばす案は、未知 option の後ろの Git を取り逃がすため不採用。
# 対応: nice の数値 option と nohup の `--` だけを明示的に消費し、未知・解決不能時は marker を出して停止する。
readonly GIT_BIN='git'
readonly GIT_GLOBAL_OPT='(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--config-env[[:space:]]+[^[:space:]]+|--git-dir(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--work-tree(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--namespace(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--exec-path(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)?|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--help|--version|--html-path|--man-path|--info-path|-p)'
readonly GIT_GLOBAL_OPTS="([[:space:]]+${GIT_GLOBAL_OPT})*"
readonly SUDO_OPT='((-u|-g|-h|-p|-C|-T)[[:space:]]+[^[:space:]]+|-[^[:space:]]+)'
readonly ENV_OPT='((-u|--unset|-C|--chdir)[[:space:]]+[^[:space:]]+|-[^[:space:]]+)'
readonly GIT_PREFIX_TOKEN='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+|!|if|then|else|elif|do|while|until|command([[:space:]]+-p)?|builtin|exec|time([[:space:]]+-p)?|sudo([[:space:]]+'"${SUDO_OPT}"')*)'
readonly ENV_BIN='(/([^[:space:]/]+/)*env|env)'
readonly ENV_PREFIX="${ENV_BIN}"'([[:space:]]+'"${ENV_OPT}"')*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*'
readonly GIT_SEGMENT_START='^[[:space:]]*(('"${GIT_PREFIX_TOKEN}"'|'"${ENV_PREFIX}"')[[:space:]]+)*'"${GIT_BIN}"

command_segments="$(
  COMMAND_TEXT="$command" python3 - <<'PY' 2>/dev/null || true
import os
import re
import shlex

cmd = os.environ.get("COMMAND_TEXT", "")

CONTROL_WORDS = {"!", "if", "then", "else", "elif", "do", "while", "until"}
UNRESOLVED_WRAPPER = -1

def executable_basename(token: str, *, decoded: bool = False):
    if decoded:
        return os.path.basename(token)
    try:
        lexer = shlex.shlex(token, posix=True)
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        return None
    if len(words) != 1:
        return None
    return os.path.basename(words[0])

# [2026-08-02][fix] command wrapperと実行名は静的に確定できる場合だけ許可する。
# 背景:
#   - ユーザー依頼意図: env/time/exec/sudo/eval 等を挟んだ場合や、変数・command substitutionで
#     実行名を組み立てた場合も、破壊的Git操作を同じ基準で止める。
#   - 守るべき業務ルール: wrapper後の実行ファイルを静的に確定できない場合は許可しない。
#     posix lexerでdecode済みのtokenは再度shell parseせず、実ファイル名のquoteをliteralとして扱う。
#   - 他案不採用理由: 各OS・wrapperの全optionを推測して許可すると、引数をcommandとして
#     再解釈するoptionや将来追加されたoptionが新しい迂回経路になる。decode済みtokenの再shlexは
#     quoteを含む有効なpathを構文エラーに変え、basename=gitの検出を失うため不採用。
# 対応: 安全性を確認したoptionだけをwhitelistし、eval・未知option・再分割option・動的実行名は
#   unresolved markerへ送る。decode済みtokenのbasenameは文字列から直接取得する。
def command_executable_index(segment: list[str], *, decoded: bool = False):
    sudo_short_options_with_arg = {"-u", "-g", "-h", "-p", "-C", "-T", "-D", "-R", "-r", "-t", "-U"}
    sudo_short_options_no_arg = set("ABbEeHiKklnPSsVv")
    sudo_long_options_with_arg = {
        "--user", "--group", "--host", "--prompt", "--close-from",
        "--chdir", "--chroot", "--command-timeout", "--other-user",
        "--login-class", "--role", "--type",
    }
    sudo_long_options_no_arg = {
        "--askpass", "--background", "--bell", "--edit", "--help", "--login",
        "--list", "--non-interactive", "--preserve-env", "--remove-timestamp",
        "--reset-timestamp", "--set-home", "--shell", "--stdin", "--validate", "--version",
    }
    index = 0
    while index < len(segment):
        wrapper_start = index
        while index < len(segment):
            token = segment[index]
            if token in CONTROL_WORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
                index += 1
                continue
            break
        if index >= len(segment):
            return None

        executable = executable_basename(segment[index], decoded=decoded)
        if executable in {"command", "builtin"}:
            index += 1
            while index < len(segment):
                if segment[index] == "--":
                    index += 1
                    break
                if segment[index] == "-p":
                    index += 1
                    continue
                break
        elif executable == "eval":
            # eval reparses every remaining argument as shell source.
            return UNRESOLVED_WRAPPER
        elif executable == "exec":
            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option == "-a":
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if option.startswith("-a") and option != "-a":
                    index += 1
                    continue
                if re.fullmatch(r"-[cl]+", option):
                    index += 1
                    continue
                if option.startswith("-"):
                    return UNRESOLVED_WRAPPER
                break
        elif executable == "time":
            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option in {"--help", "--version"}:
                    return None
                if option in {"-o", "-f", "--output", "--format"}:
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if option.startswith("--output=") or option.startswith("--format="):
                    index += 1
                    continue
                if option in {"--append", "--verbose", "--portability", "--quiet"}:
                    index += 1
                    continue
                if re.fullmatch(r"-[ahlpv]+", option):
                    index += 1
                    continue
                if re.fullmatch(r"-(?:o|f).+", option):
                    index += 1
                    continue
                if option.startswith("-"):
                    return UNRESOLVED_WRAPPER
                break
        # [2026-08-02][fix] timeout wrapper の後段 command を限定解析する。
        # 背景:
        #   - ユーザー依頼意図: 全PJへ配布する破壊的Git guardで、`timeout 5 git reset --hard` の
        #     ような標準wrapper経由の実行も直接実行と同じ基準で止める。
        #   - 守るべき業務ルール: timeoutの既知optionと必須durationだけを消費し、その直後の
        #     commandを再帰的に検査する。未知option・値不足・command不足はfail-closedにする。
        #   - 他案不採用理由: timeout以下を通常引数として許可する案は破壊操作を見逃し、全optionを
        #     無条件に読み飛ばす案は将来の再解釈optionで同じ迂回を再発させるため不採用。
        # 対応: GNU timeoutの副作用を持たない既知optionだけを許可し、durationを1語消費して
        #   後段commandへ解析を継続する。hook自身はtimeoutや対象commandを実行しない。
        elif executable == "timeout":
            duration_pattern = r"(?:\d+(?:\.\d*)?|\.\d+)(?:s|m|h|d)?"
            signal_pattern = r"(?:SIG)?[A-Za-z0-9]+"

            def static_timeout_value(token: str, pattern: str) -> bool:
                if token_has_unresolved_executable_expansion(token):
                    return False
                try:
                    value = token if decoded else decode_shell_command(token)
                except (TypeError, ValueError):
                    return False
                return re.fullmatch(pattern, value) is not None

            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option in {"--help", "--version"}:
                    return None
                if option in {"--preserve-status", "--foreground", "--verbose", "-v"}:
                    index += 1
                    continue
                if option in {"-k", "--kill-after", "-s", "--signal"}:
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    value_pattern = duration_pattern if option in {"-k", "--kill-after"} else signal_pattern
                    if not static_timeout_value(segment[index + 1], value_pattern):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if option.startswith("-k") and option != "-k":
                    if not static_timeout_value(option[2:], duration_pattern):
                        return UNRESOLVED_WRAPPER
                    index += 1
                    continue
                if option.startswith("-s") and option != "-s":
                    if not static_timeout_value(option[2:], signal_pattern):
                        return UNRESOLVED_WRAPPER
                    index += 1
                    continue
                if option.startswith("--kill-after="):
                    if not static_timeout_value(option.split("=", 1)[1], duration_pattern):
                        return UNRESOLVED_WRAPPER
                    index += 1
                    continue
                if option.startswith("--signal="):
                    if not static_timeout_value(option.split("=", 1)[1], signal_pattern):
                        return UNRESOLVED_WRAPPER
                    index += 1
                    continue
                if option.startswith("-"):
                    return UNRESOLVED_WRAPPER
                break
            # timeout requires one duration token followed by a command.
            if index + 1 >= len(segment):
                return UNRESOLVED_WRAPPER
            if not static_timeout_value(segment[index], duration_pattern):
                return UNRESOLVED_WRAPPER
            index += 1
        elif executable == "nice":
            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option == "-n" or option == "--adjustment":
                    index += 1
                    if index >= len(segment) or not re.fullmatch(r"[+-]?\d+", segment[index]):
                        return UNRESOLVED_WRAPPER
                    index += 1
                    continue
                if re.fullmatch(r"-n[+-]?\d+", option) or re.fullmatch(r"-\+?\d+", option):
                    index += 1
                    continue
                if re.fullmatch(r"--adjustment=[+-]?\d+", option):
                    index += 1
                    continue
                if option in {"--help", "--version"}:
                    return None
                if option.startswith("-"):
                    return UNRESOLVED_WRAPPER
                break
            if index >= len(segment):
                return UNRESOLVED_WRAPPER
        elif executable == "nohup":
            index += 1
            if index < len(segment) and segment[index] == "--":
                index += 1
            elif index < len(segment) and segment[index].startswith("-"):
                return UNRESOLVED_WRAPPER
            if index >= len(segment):
                return UNRESOLVED_WRAPPER
        elif executable == "sudo":
            index += 1
            terminated = False
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                if option == "--":
                    index += 1
                    terminated = True
                    break
                if option.startswith("--"):
                    if "=" in option:
                        option_name, _ = option.split("=", 1)
                        has_attached_value = True
                    else:
                        option_name = option
                        has_attached_value = False
                    if option_name not in sudo_long_options_with_arg and option_name not in sudo_long_options_no_arg:
                        return UNRESOLVED_WRAPPER
                    index += 1
                    if (
                        not has_attached_value
                        and option_name in sudo_long_options_with_arg
                    ):
                        if index >= len(segment):
                            return UNRESOLVED_WRAPPER
                        index += 1
                    continue
                option_name = option[:2]
                if option_name in sudo_short_options_with_arg:
                    index += 1
                    if len(option) == 2:
                        if index >= len(segment):
                            return UNRESOLVED_WRAPPER
                        index += 1
                    continue
                if all(char in sudo_short_options_no_arg for char in option[1:]):
                    index += 1
                    continue
                return UNRESOLVED_WRAPPER
            if not terminated:
                while index < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[index]):
                    index += 1
        # [2026-08-02][fix] xargs を wrapper として解析し、実行 command へ検査を継続する。
        # 背景:
        #   - ユーザー依頼意図: `printf 'HEAD' | xargs -n1 git reset --hard` のように xargs 経由で
        #     破壊的 Git を起動すると、git が引数位置に見えて検査から漏れていた
        #     （jtt-cms PR #1542 の codex-review が検出した Critical）。
        #   - 守るべき業務ルール: timeout / env と同じく、副作用と再解釈の無い既知 option だけを
        #     whitelist で消費し、直後の command を通常の検査へ流す。引数が任意個の option
        #     （GNU の bare -l / -i / -e、--replace 単独等）は静的に境界を確定できないため
        #     unresolved（fail-closed）に送る。command 無しの xargs は既定 echo のため安全。
        #   - 他案不採用理由: xargs を一律 unresolved にする案は、`ls | xargs rm` 等の非 git 用途
        #     まで全 deny し誤検知摩擦（#1313 で解消したクラス）を再発させる。全 option の
        #     読み飛ばしは将来の再解釈 option で迂回を再発させる（timeout の CaD と同判断）。
        elif executable == "xargs":
            xargs_long_with_arg = {
                "--arg-file", "--delimiter", "--eof", "--max-args", "--max-chars",
                "--max-lines", "--max-procs", "--process-slot-var",
            }
            xargs_no_arg = {
                "-0", "--null", "-p", "--interactive", "-r", "--no-run-if-empty",
                "-t", "--verbose", "-x", "--exit", "-o", "--open-tty",
            }
            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option in {"--help", "--version"}:
                    return None
                if option in {"-n", "-L", "-s", "-P", "-a", "-d", "-E", "-J", "-I"}:
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if option in xargs_long_with_arg:
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if any(option.startswith(name + "=") for name in xargs_long_with_arg | {"--replace"}):
                    index += 1
                    continue
                if re.fullmatch(r"-[nLsPadEJIi].+", option):
                    # 値が密着した短形（-n1 / -I{} / -i{} / -d\n 等）
                    index += 1
                    continue
                if option in xargs_no_arg or re.fullmatch(r"-[0prtxo]+", option):
                    index += 1
                    continue
                if option.startswith("-"):
                    # bare -l / -i / -e / --replace 等の任意引数 option・未知 option
                    return UNRESOLVED_WRAPPER
                break
        elif executable == "env":
            index += 1
            while index < len(segment):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option in {"-S", "--split-string"} or option.startswith("-S") or option.startswith("--split-string="):
                    # split-string reparses one token into a complete command.
                    return UNRESOLVED_WRAPPER
                if option in {"-u", "--unset", "-C", "--chdir"}:
                    if index + 1 >= len(segment):
                        return UNRESOLVED_WRAPPER
                    index += 2
                    continue
                if option.startswith("--unset=") or option.startswith("--chdir="):
                    index += 1
                    continue
                if re.fullmatch(r"-(?:u|C).+", option):
                    index += 1
                    continue
                if option in {"-", "-i", "--ignore-environment", "-0", "--null", "--debug"}:
                    index += 1
                    continue
                if option in {"--help", "--version"}:
                    return None
                if option.startswith("-"):
                    return UNRESOLVED_WRAPPER
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", option):
                    index += 1
                    continue
                break
        else:
            return index

        if index <= wrapper_start:
            return None
    return None

def token_has_unresolved_executable_expansion(token: str) -> bool:
    """Return whether an executable word requires shell expansion to resolve."""
    if token.startswith("="):
        # zsh expands a leading equals command name to an absolute executable path.
        return True
    quote = None
    index = 0
    while index < len(token):
        char = token[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if quote == '"' and char == '"':
            quote = None
            index += 1
            continue
        if quote is None and char in {"'", '"'}:
            quote = char
            index += 1
            continue
        if char == chr(96):
            return True
        if char == "$" and index + 1 < len(token):
            next_char = token[index + 1]
            if next_char in "{([?*!#@$-0123456789_" or next_char.isalpha():
                return True
        if char in "<>" and index + 1 < len(token) and token[index + 1] == "(":
            return True
        if quote is None and char in "*?":
            return True
        if (
            quote is None
            and char in "[{"
            and index + 1 < len(token)
            and not token[index + 1].isspace()
            and token[index + 1] not in ";&|"
        ):
            return True
        if quote is None and char in "@+!" and index + 1 < len(token) and token[index + 1] == "(":
            return True
        if (
            quote is None
            and char == "("
            and index > 0
            and not token[index - 1].isspace()
            and token[index - 1] not in ";&|(<"
        ):
            return True
        index += 1
    return False

def has_unresolved_command_start(text: str) -> bool:
    """Inspect raw command-start words without evaluating shell syntax."""
    try:
        # Keep parentheses inside words so `$(...)`, extglob, and zsh qualifiers
        # remain visible. The regular parser separately handles grouping syntax.
        lexer = shlex.shlex(text, posix=False, punctuation_chars=";&|")
        # Real shell comments were removed by
        # collapse_shell_line_continuations().  Keep `#` inside parameter
        # expansions such as `${#name}` visible to the lexer.
        lexer.commenters = ""
        lexer.whitespace_split = True
        tokens = list(lexer)
    except Exception:
        return True

    segment: list[str] = []
    for token in tokens + [";"]:
        if token in {"(", ")", "{", "}"} or (token and all(char in ";&|" for char in token)):
            if segment:
                executable_index = command_executable_index(segment)
                if executable_index == UNRESOLVED_WRAPPER:
                    return True
                if (
                    executable_index is not None
                    and executable_index >= 0
                    and token_has_unresolved_executable_expansion(segment[executable_index])
                ):
                    return True
                segment = []
        else:
            segment.append(token)
    return False

def emit_segment_line(text: str) -> None:
    if has_unresolved_command_start(text):
        print("__UNRESOLVED_COMMAND_WRAPPER__")
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|(){}")
        lexer.commenters = ""
        lexer.whitespace_split = True
        tokens = list(lexer)
    except Exception:
        for segment in re.split(r"[;&|(){}]+", text):
            segment = segment.strip()
            if segment:
                print(segment)
        return

    segment = []

    def flush() -> None:
        if segment:
            # `segment` came from a posix=True lexer, so quoted arguments with
            # spaces are already one token. Replace those spaces only for the
            # executable parser; nested shell bodies keep their original quotes.
            parser_segment = [re.sub(r"\s+", "__ARG_SPACE__", token) for token in segment]
            executable_index = command_executable_index(parser_segment, decoded=True)
            if executable_index == UNRESOLVED_WRAPPER:
                print("__UNRESOLVED_COMMAND_WRAPPER__")
                segment.clear()
                return
            # [2026-08-02][fix] grouping 構文の内側でも動的 executable を fail-closed にする。
            # 背景:
            #   - ユーザー依頼意図: `{ "$G" reset --hard; }`、subshell、function body のように
            #     command start が grouping token の後ろにある場合も、破壊的 Git を取り逃がさない。
            #   - 守るべき業務ルール: 実行ファイル名を静的に `git` 以外と確定できない command segment は
            #     grouping の深さに関係なく unresolved marker へ送り、既存の fail-close 契約を保つ。
            #   - 他案不採用理由: 外側の raw scanner だけで grouping 全体を一つの command とみなす案は、
            #     brace/subshell/function の内側にある実際の executable 境界を失うため不採用。
            # 対応: decoded parser が抽出した各 segment の executable token も検査し、変数または
            #   command substitution を含む場合は unresolved marker を出す。
            if (
                executable_index is not None
                and executable_index >= 0
                and (
                    parser_segment[executable_index] == "$"
                    or token_has_unresolved_executable_expansion(parser_segment[executable_index])
                )
            ):
                # The decoded parser also sees command starts inside brace/paren
                # groups and function bodies that the outer raw segment begins
                # with grouping syntax rather than the eventual executable.
                print("__UNRESOLVED_COMMAND_WRAPPER__")
                segment.clear()
                return
            if (
                executable_index is not None
                and executable_index >= 0
                and executable_basename(parser_segment[executable_index], decoded=True) == "git"
            ):
                segment[:] = ["git"] + segment[executable_index + 1:]
            # shlex は引用を外すため、空白入り `git -C "/tmp/a b"` をそのまま join すると
            # 後段の正規表現が git global option の引数境界を誤る。判定に不要な内部空白だけ
            # sentinel に寄せ、実コマンドの語順は保ったまま検査する。
            normalized = [re.sub(r"\s+", "__ARG_SPACE__", token) for token in segment]
            print(" ".join(normalized).strip())
            segment.clear()

    for token in tokens:
        if token and all(ch in ";&|(){}" for ch in token):
            flush()
        else:
            segment.append(token)
    flush()

# [2026-08-02][fix] dash / ksh も shell receiver として再帰検査する（issue #1344）。
# 背景:
#   - ユーザー依頼意図: dash / ksh へ here-doc（quoted 'EOF' 区切り）で流し込んだ破壊的 Git が
#     receiver 集合の漏れで再帰検査されず素通りしていた（PR #1343 の codex-review が検出）。
#     ※このコメントに here-doc 演算子そのものを書かないこと: 本 Python は bash の $( ) 置換内の
#       quoted heredoc に埋まっており、bash の置換パーサはコメント内でも演算子を解釈して壊れる。
#   - 守るべき業務ルール: shell として本文を実行する受け手は全て同じ fail-close 再帰へ送る。
#   - 他案不採用理由: 任意の実行ファイルを receiver 扱いする案は、非 shell の cat/tee まで
#     本文をコマンド検査して誤検知を増やすため不採用（shell 実体の列挙を維持し不足だけ足す）。
shells = {"sh", "bash", "zsh", "dash", "ksh"}
MAX_SHELL_DEPTH = 4
UNRESOLVED_COMMAND_MARKER = "__UNRESOLVED_COMMAND_WRAPPER__"

# [2026-08-02][fix] 引用内改行で論理行を分断しない（issue #1313 誤検知ファミリー）。
# 背景:
#   - ユーザー依頼意図: `git commit -m "<複数行メッセージ>"` / `gh pr create --body "<複数行>"` が
#     text.splitlines() の引用非対応分割で引用途中に千切れ、unresolved 判定→deny になっていた
#     （1セッション3〜6回の実測摩擦。値は実行されないデータであり真陽性ではない）。
#   - 守るべき業務ルール: shell の行分割は引用外の改行だけがコマンド区切り。引用内・$( ) /
#     backtick 内の改行はトークン/置換本文の一部として同じ論理行に留める。未終端の引用・置換は
#     従来どおり None を返し fail-closed（unresolved）へ倒す。$( ) / backtick の本文検査は
#     shell_substitution_bodies 側が従来どおり再帰実施するため、検知力は変えない。
#   - 他案不採用理由: -m/--body 等の「データ引数の値」を走査対象から除外する案は、値の中の
#     $( ) 置換（shell が実際に実行する）まで免除しかねず、緩和面が広い。引用対応の分割は
#     誤検知3ケースを同時に解消しつつ既存の置換再帰検査を一切変えない最小修正のため採用。
def split_shell_logical_lines(text: str):
    """Split on newlines that are outside quotes / $() / backticks. None if unterminated.

    Context stack model: 'sq' (single quote), 'dq' (double quote), 'sub'
    ($() or bare paren inside a substitution), 'bt' (backtick). Newlines break
    logical lines only when the stack is empty (= plain command position).
    """
    BACKTICK = chr(96)  # 字面のバッククォートは外側 bash の置換スキャナを壊すため chr で持つ
    lines = []
    current = []
    stack: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        state = stack[-1] if stack else None
        if state == "sq":
            # 単一引用内の backslash+改行は「continuation に見える難読化」の既存保守契約を
            # 維持するため unresolved（None）へ倒す（test: single quoted continuation）。
            if char == "\\" and index + 1 < length and text[index + 1] in "\r\n":
                return None
            current.append(char)
            if char == "'":
                stack.pop()
            index += 1
            continue
        if char == "\\":
            # escape consumes next char in normal / dq / sub / bt contexts
            current.append(char)
            if index + 1 < length:
                current.append(text[index + 1])
                index += 2
            else:
                index += 1
            continue
        if state == "dq":
            if char == '"':
                stack.pop()
            elif char == "$" and index + 1 < length and text[index + 1] == "(":
                # NOTE: dollar+開き括弧のリテラルを1トークンで書かない。外側 bash の
                # 置換スキャナが引用内でも入れ子置換の開始と解釈して構文崩壊するため、
                # 2文字に分けて append する（本ファイル特有の制約）。
                current.append("$")
                current.append("(")
                stack.append("sub")
                index += 2
                continue
            elif char == BACKTICK:
                stack.append("bt")
            current.append(char)
            index += 1
            continue
        if state == "bt":
            if char == BACKTICK:
                stack.pop()
            current.append(char)
            index += 1
            continue
        # state is None (top level) or 'sub' — both accept openers
        if char == "'":
            stack.append("sq")
            current.append(char)
            index += 1
            continue
        if char == '"':
            stack.append("dq")
            current.append(char)
            index += 1
            continue
        if char == BACKTICK:
            stack.append("bt")
            current.append(char)
            index += 1
            continue
        if char == "$" and index + 1 < length and text[index + 1] == "(":
            stack.append("sub")
            # NOTE: dollar+開き括弧のリテラルは2文字に分けて append（上の分岐と同じ理由）。
            current.append("$")
            current.append("(")
            index += 2
            continue
        if state == "sub":
            if char == "(":
                stack.append("sub")
            elif char == ")":
                stack.pop()
            current.append(char)
            index += 1
            continue
        if char == "\n":
            lines.append("".join(current))
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    if stack:
        return None
    lines.append("".join(current))
    return [line for line in lines if line.strip()] or [""]


# [2026-08-02][fix] git 無縁と静的に確定できる nested body だけ unresolved deny を免除する
# （issue #1313 案3の安全部分集合・下の呼び出し元 CaD と対）。
# 背景:
#   - ユーザー依頼意図: 変数や特殊パラメータを含むだけの非 git body（例: exit status 表示付きの
#     script 実行）が unresolved 扱いで deny される摩擦を解消したい。
#   - 守るべき業務ルール: 既存の fail-closed 契約（変数 executable / glob・brace・class による
#     git 難読化 / 引用継続の難読化は deny）を 1 件も後退させない。判定は「安全と証明できた
#     場合のみ許可」の片側条件とし、証明できない形は全て従来どおり deny に落とす。
#   - 他案不採用理由: body へ再帰降下する案は、glob executable（g?t 等）を非 git と誤読する。
#     git 文字列の有無だけで判定する案は、変数 executable（PAYLOAD 経由）を素通りさせる。
def nested_body_safely_non_git(body: str) -> bool:
    """True only when the body is provably inert w.r.t. destructive git.

    条件（全て満たす時だけ許可・1つでも証明できなければ False = 従来の deny）:
    1. body に "git" 文字列が無い（大文字小文字無視・部分一致で安全側）
    2. brace / backtick / 置換開始（dollar+開き括弧）が無い
    3. dollar 展開は単文字特殊パラメータ（? $ ! #）のみ（$VAR / ${...} は
       eval や interpreter の引数経由で任意コマンド化しうるため一律 deny）
    4. 各 command segment の実行子がプレーンリテラルで、shell でも
       実行 wrapper（eval / exec / env / sudo / xargs 等・引数を実行する類）でもない
    """
    lowered = body.lower()
    if "git" in lowered:
        return False
    if "{" in body or "}" in body:
        # brace expansion は tokenizer が区切りとして分解し executable 難読化
        # （/usr/bin/g{it} 等）を見えなくするため、含む body は証明不能として deny 側
        return False
    if chr(96) in body:
        # backtick 置換は静的解決不能
        return False
    # [2026-08-02][fix] PR #1354 codex-review Critical 対応: $VAR / ${...} を含む body は
    # `eval $PAYLOAD` / `python3 -c $CODE` 等の引数経由で任意コマンド化するため許可しない。
    # 実行時に値が確定済みで不活性なのは単文字特殊パラメータだけ、という許可リストへ縮小する。
    position = body.find("$")
    while position != -1:
        follower = body[position + 1:position + 2]
        if follower not in {"?", "$", "!", "#"}:
            return False
        position = body.find("$", position + 2)
    segments = segment_tokens(body)
    if segments is None:
        return False
    plain_executable = re.compile(r"[A-Za-z0-9_./-]+")
    # 引数を新たなコマンドとして実行しうる wrapper。列挙は原理的に完全にならないため、
    # ここに無い未知 wrapper への防御は上の「$VAR 全面 deny」（引数が静的リテラルなら
    # wrapper 経由でも body 内に "git" が現れ 1. で deny）と組み合わせて成立させる。
    exec_wrappers = {
        "eval", "exec", "command", "builtin", "source", ".",
        "env", "sudo", "doas", "su", "xargs", "nohup", "nice",
        "time", "timeout", "setsid", "script", "watch", "caffeinate",
    }
    for segment in segments:
        index = command_executable_index(segment)
        if index == UNRESOLVED_WRAPPER:
            return False
        if index is None:
            # 実行子なし（純 assignment 等）は破壊操作を持たない
            continue
        if index < 0 or index >= len(segment):
            return False
        token = segment[index]
        if plain_executable.fullmatch(token) is None:
            return False
        basename = executable_basename(token)
        if basename in shells or basename in exec_wrappers:
            # nested-nested shell / 実行 wrapper は本関数で安全証明できないため deny 側
            return False
    return True


def decode_shell_command(token: str) -> str:
    lexer = shlex.shlex(token, posix=True)
    lexer.whitespace_split = True
    words = list(lexer)
    if len(words) != 1:
        raise ValueError("invalid shell command argument")
    return words[0]

def segment_tokens(text: str):
    try:
        # Keep the outer quote around `bash -c`/`sh -c` bodies so the nested
        # command can be decoded once without losing its own quoted path tokens.
        lexer = shlex.shlex(text, posix=False, punctuation_chars=";&|(){}")
        lexer.commenters = ""
        lexer.whitespace_split = True
        tokens = list(lexer)
    except Exception:
        return None
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

def shell_start_index(segment: list[str]):
    index = command_executable_index(segment)
    return index if index is not None and index >= 0 and executable_basename(segment[index]) in shells else None


# [2026-08-02][fix] nested shell の動的 body を fail-closed にする。
# 背景:
#   - ユーザー依頼意図: `PAYLOAD="git reset --hard"; bash -c "$PAYLOAD"` のように、
#     shell `-c` の body を変数・command substitution・process substitution で組み立てる
#     経路でも、破壊的 Git の静的検査を迂回させない。
#   - 守るべき業務ルール: hook が安全に確定できない nested body は許可せず、必ず deny する。
#     hook 自身が変数展開や command substitution を実行して body を得ることは禁止する。
#   - 他案不採用理由: body を実行して展開結果を得る案は hook の副作用・コマンドインジェクションを
#     招く。正規表現だけで全ての shell 展開を再現する案は quote/escape 境界を取り違えるため不採用。
# 対応: shlex で decode 済みの body を小さな quote-aware scanner で確認し、未解決の `$` 展開、
#   backtick、`$()`、process substitution、pathname/brace展開を marker に変換する。
#   静的 body の再帰検査は従来どおり行う。
# [2026-08-02][fix] double quote 中の single quote で scanner state を切り替えない。
# 背景: shell では double quote 内の `'` は literal だが、旧 scanner は single quote 開始と誤認し、
#   後続の `$PAYLOAD` を「展開されない文字列」として見逃し得た。scanner 単体でも shell semantics と
#   一致させる必要がある。quote 全文を正規表現へ戻す案は既存の escape 境界を失うため不採用。
# 対応: double quote state は `"` だけで終了し、その中の `'` は通常文字として扱う。
def has_unresolved_shell_expansion(text: str) -> bool:
    """Return whether a nested shell body contains expansion we must not evaluate."""
    quote = None
    index = 0

    def parameter_expansion_at(position: int) -> bool:
        if position + 1 >= len(text):
            return False
        next_char = text[position + 1]
        if next_char in "{([?*!#@$-0123456789_":
            return True
        return next_char.isalpha()

    while index < len(text):
        char = text[index]
        if quote == "'":
            # Single-quoted shell text has no expansion semantics.
            if char == "'":
                quote = None
            index += 1
            continue

        if char == "\\":
            # In unquoted/double-quoted text, an escaped next character is literal.
            index += 2
            continue
        if quote == '"' and char == '"':
            quote = None
            index += 1
            continue
        if quote is None and char in {"'", '"'}:
            quote = char
            index += 1
            continue
        if char == chr(96):
            return True
        if char == "$" and parameter_expansion_at(index):
            return True
        if char in "<>" and index + 1 < len(text) and text[index + 1] == "(":
            return True
        if quote is None and char in "*?":
            return True
        if (
            quote is None
            and char in "[{"
            and index + 1 < len(text)
            and not text[index + 1].isspace()
            and text[index + 1] not in ";&|"
        ):
            return True
        if (
            quote is None
            and char in "@+!"
            and index + 1 < len(text)
            and text[index + 1] == "("
        ):
            # Bash extglob such as @(git) can synthesize the executable name.
            return True
        if (
            quote is None
            and char == "("
            and index > 0
            and not text[index - 1].isspace()
            and text[index - 1] not in ";&|(<"
        ):
            # zsh glob qualifiers such as /usr/bin/git(.) are attached to a word.
            return True
        index += 1
    return False


# [2026-08-02][fix] 通常 command の引数内にある shell substitution も再帰検査する。
# 背景:
#   - ユーザー依頼意図: `printf '%s' "$(git reset --hard)"` のように、外側の executable が
#     `git` でなくても実行される破壊的 Git を取り逃がさない。
#   - 守るべき業務ルール: command / process / backtick substitution の body は、引用位置に関係なく
#     実際に shell が実行する範囲だけを静的に抽出し、既存と同じ fail-close 判定へ渡す。
#   - 他案不採用理由: substitution を含む command を一律 deny すると `$(pwd)` 等の安全な開発操作まで
#     止める。shell 展開を実行して body を得る案は副作用と command injection を招くため不採用。
# 対応: single quote と escape を尊重する小さな scanner で `$()` / `<()` / `>()` / backtick の
#   body を抽出する。対応できない構文・不均衡・深すぎる再帰は unresolved marker へ送る。
def shell_substitution_bodies(text: str):
    """Return executable substitution bodies, or ``None`` when ambiguous."""

    def backtick_end(start: int):
        position = start + 1
        while position < len(text):
            if text[position] == "\\":
                position += 2
                continue
            if text[position] == chr(96):
                return position
            position += 1
        return None

    def paren_end(open_index: int):
        depth = 1
        quote = None
        position = open_index + 1
        while position < len(text):
            char = text[position]
            if quote == "'":
                if char == "'":
                    quote = None
                position += 1
                continue
            if char == "\\":
                position += 2
                continue
            if quote == '"':
                if char == '"':
                    quote = None
                    position += 1
                    continue
                if char == "$" and position + 1 < len(text) and text[position + 1] == "{":
                    # Parameter expansion patterns may legally contain `)` and
                    # make a hand-written parenthesis matcher terminate early.
                    return None
                if char == "$" and position + 1 < len(text) and text[position + 1] == "(":
                    nested_end = paren_end(position + 1)
                    if nested_end is None:
                        return None
                    position = nested_end + 1
                    continue
                if char == chr(96):
                    nested_end = backtick_end(position)
                    if nested_end is None:
                        return None
                    position = nested_end + 1
                    continue
                position += 1
                continue
            if char in {"'", '"'}:
                quote = char
                position += 1
                continue
            if (
                char == "#"
                and (
                    position == open_index + 1
                    or text[position - 1].isspace()
                    or text[position - 1] in ";&|({}"
                )
            ):
                # An unquoted shell comment hides every `)` through the newline.
                newline = text.find("\n", position + 1)
                if newline < 0:
                    return None
                position = newline + 1
                continue
            if char == chr(96):
                nested_end = backtick_end(position)
                if nested_end is None:
                    return None
                position = nested_end + 1
                continue
            if char == "$" and position + 1 < len(text) and text[position + 1] == "(":
                nested_end = paren_end(position + 1)
                if nested_end is None:
                    return None
                position = nested_end + 1
                continue
            if char == "$" and position + 1 < len(text) and text[position + 1] == "{":
                return None
            if char == "<" and position + 1 < len(text) and text[position + 1] == "<":
                # Skip a here-doc inside `$()` so a later `)` / command remains visible.
                # Example: `$(cat <<EOF` ... `EOF` then destructive git then `)` must still
                # expose the trailing destructive git to recursive inspection.
                heredoc_end = heredoc_skip_end(text, position)
                if heredoc_end is None:
                    return None
                position = heredoc_end[0]
                continue
            if char == "[" and position + 1 < len(text) and text[position + 1] == "[":
                # Bash regex operands can contain unmatched `)` tokens.
                return None
            if char in "<>" and position + 1 < len(text) and text[position + 1] == "(":
                nested_end = paren_end(position + 1)
                if nested_end is None:
                    return None
                position = nested_end + 1
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    return position
            position += 1
        return None

    bodies = []
    quote = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if quote == '"' and char == '"':
            quote = None
            index += 1
            continue
        if quote is None and char in {"'", '"'}:
            quote = char
            index += 1
            continue
        if char == chr(96):
            end = backtick_end(index)
            if end is None:
                return None
            body = text[index + 1:end]
            # Inside legacy backticks, an escaped backtick opens/closes a nested
            # command substitution. Until that grammar is decoded losslessly,
            # preserve the documented fail-close boundary instead of treating it
            # as a literal escape and dropping the nested executable.
            if chr(92) + chr(96) in body:
                return None
            bodies.append(body)
            index = end + 1
            continue
        if char == "$" and index + 1 < len(text) and text[index + 1] == "(":
            end = paren_end(index + 1)
            if end is None:
                return None
            body = text[index + 2:end]
            if body.startswith("("):
                # Arithmetic expansion is not itself a command, but may contain one.
                nested = shell_substitution_bodies(body)
                if nested is None:
                    return None
                bodies.extend(nested)
            else:
                # A case-pattern `)` is indistinguishable from the substitution
                # terminator in this deliberately small scanner. Never infer
                # safety from a later `esac` string: it may be pattern data before
                # the prematurely matched `)` rather than the closing keyword.
                case_start = r"(?:^|[;&|({\n]|\b(?:then|do|else)\b)\s*case\b"
                if re.search(case_start, body):
                    return None
                bodies.append(body)
            index = end + 1
            continue
        if quote is None and char in "<>" and index + 1 < len(text) and text[index + 1] == "(":
            end = paren_end(index + 1)
            if end is None:
                return None
            bodies.append(text[index + 2:end])
            index = end + 1
            continue
        index += 1
    if quote is not None:
        return None
    return bodies


# [2026-08-02][fix] shell tokenizationより先にline continuationを論理行へ戻す。
# 背景:
#   - ユーザー依頼意図: `g\\\nit reset --hard` のように物理改行で executable を分割しても、
#     実行時に `git` へ戻る破壊操作を取り逃がさない。
#   - 守るべき業務ルール: shell がtokenize前に行うbackslash-newline除去を静的に再現し、
#     command substitution内外で同じfail-close判定へ渡す。single quote内のliteralは変更しない。
#   - 他案不採用理由: shell自体を実行して展開結果を得る案は、副作用とcommand injectionを招く。
#     物理行を別々に検査する旧方式は、改行をまたいだ実行tokenを原理的に復元できない。
# 対応: quote-awareな標準Python処理でLF/CRLF continuationだけを除去し、その後に既存scannerを使う。
def collapse_shell_line_continuations(text: str) -> str:
    """Collapse continuations and remove real comments before ``shlex``."""
    result = []
    quote = None
    in_comment = False
    index = 0
    while index < len(text):
        char = text[index]
        if in_comment:
            # Backslash-newline is literal comment text here; the physical newline
            # still ends the comment before the next command.
            if char == "\n":
                result.append(char)
                in_comment = False
            index += 1
            continue
        if quote == "'":
            result.append(char)
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\":
            if index + 1 < len(text) and text[index + 1] == "\n":
                index += 2
                continue
            if index + 2 < len(text) and text[index + 1:index + 3] == "\r\n":
                index += 3
                continue
            result.append(char)
            if index + 1 < len(text):
                result.append(text[index + 1])
                index += 2
            else:
                index += 1
            continue
        if (
            quote is None
            and char == "#"
            and not (len(result) >= 2 and result[-2:] == ["$", "{"])
            and (
                not result
                or result[-1].isspace()
                or result[-1] in ";&|({}"
            )
        ):
            in_comment = True
            index += 1
            continue
        if quote == '"' and char == '"':
            quote = None
        elif quote is None and char in {"'", '"'}:
            quote = char
        result.append(char)
        index += 1
    return "".join(result)



# [2026-08-02][fix] here-doc 本文は受信コマンドのデータであり、行分割して再検査しない。
# 背景:
#   - ユーザー依頼意図: `git commit -F -` への here-doc や `gh ... --body "$(cat <<EOF)"` の
#     本文に危険コマンド文字列を書いただけでも hook がブロックし、ガード改善の記録自体が止まる。
#   - 守るべき業務ルール: 実際に実行される shell / git 破壊操作は fail-closed のまま止め、
#     here-doc に書かれた文書データはネスト実行と誤認しない。shell が here-doc を script として
#     読む場合（`bash <<EOF`）だけ本文を再帰検査する。
#   - 他案不採用理由: 「git commit だけ特例許可」は gh / cat 経由の同型摩擦を残す。
#     `$()` 内の `<<` を常に unresolved にする旧方式は、記録用 heredoc を原理的に通せない。
# 対応: quote-aware に heredoc 終端まで本文をスキップし、(1) トップレベルでは非 shell 受信時に
#   本文行を emit しない (2) shell 受信時は本文を再帰 emit (3) `$()` 内でも heredoc を読み飛ばして
#   閉じ括弧と後続コマンドを正しく抽出する。
def heredoc_skip_end(text: str, lt_index: int):
    """Return ``(index_after_heredoc, delimiter_quoted)`` or None.

    ``delimiter_quoted`` is True for ``<<'TAG'``, ``<<"TAG"``, and ``<<\\TAG``
    (shell does not expand the body). Bare ``<<TAG`` is unquoted.
    """
    if lt_index < 0 or lt_index + 1 >= len(text) or text[lt_index:lt_index + 2] != "<<":
        return None
    pos = lt_index + 2
    strip_tabs = False
    if pos < len(text) and text[pos] == "-":
        strip_tabs = True
        pos += 1
    while pos < len(text) and text[pos] in " \t":
        pos += 1
    if pos >= len(text) or text[pos] == "\n":
        return None

    quoted = False
    if text[pos] == "\\":
        quoted = True
        pos += 1
        if pos >= len(text):
            return None
        start = pos
        while pos < len(text) and (text[pos].isalnum() or text[pos] == "_"):
            pos += 1
        delimiter = text[start:pos]
    elif text[pos] in {"'", '"'}:
        quoted = True
        quote = text[pos]
        pos += 1
        start = pos
        while pos < len(text) and text[pos] != quote:
            if text[pos] == "\\" and quote == '"':
                pos += 2
                continue
            pos += 1
        if pos >= len(text):
            return None
        delimiter = text[start:pos]
        pos += 1
    else:
        start = pos
        while pos < len(text) and (text[pos].isalnum() or text[pos] in "_-"):
            pos += 1
        delimiter = text[start:pos]
    if not delimiter:
        return None

    newline = text.find("\n", pos)
    if newline < 0:
        return None
    body_pos = newline + 1
    while body_pos <= len(text):
        next_nl = text.find("\n", body_pos)
        line = text[body_pos:] if next_nl < 0 else text[body_pos:next_nl]
        compare = line.lstrip("\t") if strip_tabs else line
        if compare == delimiter:
            end = len(text) if next_nl < 0 else next_nl + 1
            return end, quoted
        if next_nl < 0:
            return None
        body_pos = next_nl + 1
    return None



def extract_heredocs(text: str):
    """Split here-doc bodies from command text.

    Returns ``(without_bodies, shell_bodies, unquoted_bodies)``.

    Here-docs are recognized outside single quotes. Double quotes are ignored as
    a quoting barrier so ``"$(cat <<EOF ...)"`` still strips the data body (shell
    parses the substitution in a fresh context). False positives like
    ``echo "<<EOF"`` are accepted as fail-closed ambiguity only when a full
    delimiter/body/end triple matches.

    Shell receivers re-inspect the body as a script. Unquoted non-shell here-docs
    still expand ``$()`` / backticks, so those bodies are returned separately for
    expansion-only inspection (not line-split as top-level commands).
    """
    # dash / ksh も本文をスクリプト実行する receiver（issue #1344・上の shells 定義と対）
    shells = {"sh", "bash", "zsh", "dash", "ksh"}
    sq = chr(39)
    without = []
    shell_bodies = []
    unquoted_bodies = []
    in_single = False
    index = 0
    line_start = 0

    while index < len(text):
        char = text[index]
        if in_single:
            without.append(char)
            if char == sq:
                in_single = False
            index += 1
            continue
        if char == "\\":
            without.append(char)
            if index + 1 < len(text):
                without.append(text[index + 1])
                index += 2
            else:
                index += 1
            continue
        if char == sq:
            in_single = True
            without.append(char)
            index += 1
            continue
        if char == "<" and index + 1 < len(text) and text[index + 1] == "<":
            end_info = heredoc_skip_end(text, index)
            if end_info is None:
                # Not a complete here-doc; keep the characters literally.
                without.append(char)
                index += 1
                continue
            end, quoted = end_info
            delim_line_end = text.find("\n", index)
            if delim_line_end < 0 or delim_line_end >= end:
                without.append(text[index:end])
                index = end
                continue
            without.append(text[index : delim_line_end + 1])
            body = text[delim_line_end + 1 : end]
            body_lines = body.splitlines(keepends=True)
            body_content = "".join(body_lines[:-1]) if body_lines else ""
            receiver_line = "".join(without[line_start:]) + text[index:delim_line_end]
            try:
                lexer = shlex.shlex(receiver_line, posix=True, punctuation_chars=";&|(){}")
                lexer.commenters = ""
                lexer.whitespace_split = True
                tokens = list(lexer)
            except Exception:
                tokens = []
            exec_index = command_executable_index(tokens, decoded=True) if tokens else None
            is_shell = (
                exec_index is not None
                and exec_index >= 0
                and executable_basename(tokens[exec_index], decoded=True) in shells
            )
            if is_shell:
                shell_bodies.append(body_content)
            elif not quoted and body_content.strip():
                unquoted_bodies.append(body_content)
            index = end
            if index > 0 and text[index - 1] == "\n":
                line_start = len(without)
            continue
        if char == "\n":
            without.append(char)
            index += 1
            line_start = len(without)
            continue
        without.append(char)
        index += 1
    return "".join(without), shell_bodies, unquoted_bodies




def _strip_quoted_heredocs_completely(body: str):
    """Remove quoted here-docs entirely from a ``$()`` body.

    Returns ``(remaining, True)`` when every here-doc used a quoted delimiter.
    Returns ``(None, False)`` when an unquoted/incomplete here-doc is present
    (caller must not collapse — trailing commands or expansions may remain).
    """
    sq = chr(39)
    remaining = []
    in_single = False
    index = 0
    saw_heredoc = False
    while index < len(body):
        char = body[index]
        if in_single:
            remaining.append(char)
            if char == sq:
                in_single = False
            index += 1
            continue
        if char == "\\":
            remaining.append(char)
            if index + 1 < len(body):
                remaining.append(body[index + 1])
                index += 2
            else:
                index += 1
            continue
        if char == sq:
            in_single = True
            remaining.append(char)
            index += 1
            continue
        if char == "<" and index + 1 < len(body) and body[index + 1] == "<":
            end_info = heredoc_skip_end(body, index)
            if end_info is None:
                return None, False
            end, quoted = end_info
            if not quoted:
                return None, False
            saw_heredoc = True
            index = end
            continue
        remaining.append(char)
        index += 1
    if not saw_heredoc:
        return None, False
    return "".join(remaining), True


def collapse_data_substitutions(text: str):
    """Collapse data-command substitutions that only feed quoted here-doc text.

    Only ``$(cat <<'EOF' ... EOF)`` style payloads collapse. Unquoted here-docs,
    trailing ``; cmd``, pipelines, and nested substitutions are left intact so
    later scanners still see real executable git.
    """
    data_commands = {"cat", "printf", "echo", "head", "tail", "base64", "wc", "true"}
    dq = chr(34)
    sq = chr(39)
    open_sub = "$" + "("
    token = dq + "__HOOK_STATIC_HEREDOC_DATA__" + dq
    separators = {";", "&", "|", "||", "&&", "(", ")", "{", "}"}
    out = []
    index = 0
    while index < len(text):
        dollar = text.find(open_sub, index)
        if dollar < 0:
            out.append(text[index:])
            break
        prefix = text[index:dollar]
        in_single = False
        p = 0
        while p < len(prefix):
            ch = prefix[p]
            if in_single:
                if ch == sq:
                    in_single = False
                p += 1
                continue
            if ch == "\\":
                p += 2
                continue
            if ch == sq:
                in_single = True
            p += 1
        if in_single:
            out.append(text[index:dollar + len(open_sub)])
            index = dollar + len(open_sub)
            continue
        depth = 1
        pos = dollar + len(open_sub)
        replaced = False
        while pos < len(text) and depth:
            ch = text[pos]
            if ch == "\\":
                pos += 2
                continue
            if ch == sq:
                pos += 1
                while pos < len(text) and text[pos] != sq:
                    pos += 1
                pos += 1
                continue
            if ch == dq:
                pos += 1
                while pos < len(text) and text[pos] != dq:
                    if text[pos] == "\\":
                        pos += 2
                        continue
                    pos += 1
                pos += 1
                continue
            if ch == "<" and pos + 1 < len(text) and text[pos + 1] == "<":
                skipped = heredoc_skip_end(text, pos)
                if skipped is None:
                    break
                pos = skipped[0]
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    body = text[dollar + len(open_sub):pos]
                    remaining, ok = _strip_quoted_heredocs_completely(body)
                    if ok and remaining is not None:
                        nested = shell_substitution_bodies(remaining)
                        if nested == []:
                            try:
                                lexer = shlex.shlex(
                                    remaining, posix=True, punctuation_chars=";&|(){}"
                                )
                                lexer.commenters = ""
                                lexer.whitespace_split = True
                                tokens = list(lexer)
                            except Exception:
                                tokens = []
                            if tokens and not any(tok in separators for tok in tokens):
                                exec_index = command_executable_index(
                                    tokens, decoded=True
                                )
                                if (
                                    exec_index is not None
                                    and exec_index >= 0
                                    and executable_basename(
                                        tokens[exec_index], decoded=True
                                    )
                                    in data_commands
                                ):
                                    start = dollar
                                    endpos = pos + 1
                                    if (
                                        start > 0
                                        and endpos < len(text)
                                        and text[start - 1] == dq
                                        and text[endpos] == dq
                                    ):
                                        start -= 1
                                        endpos += 1
                                    out.append(text[index:start])
                                    out.append(token)
                                    index = endpos
                                    replaced = True
                    break
            pos += 1
        if not replaced:
            if pos >= len(text) and depth:
                out.append(text[index:])
                break
            out.append(text[index:dollar + len(open_sub)])
            index = dollar + len(open_sub)
    return "".join(out)


def emit_segments(text: str, depth: int = 0) -> None:
    """Emit a shell command and recursively inspect every ``*-c`` body.

    Shells can be nested arbitrarily (for example ``bash -c 'sh -c ...'``).
    Bound the static expansion so an adversarially deep or malformed payload
    becomes an unresolved marker instead of silently bypassing the hook.
    """
    if depth > MAX_SHELL_DEPTH:
        print(UNRESOLVED_COMMAND_MARKER)
        return

    text = collapse_shell_line_continuations(text)

    # Collapse quoted data here-docs inside $() BEFORE stripping, otherwise the
    # opener remains and collapse can no longer find the terminator.
    text = collapse_data_substitutions(text)

    # Here-doc bodies are data for the receiving command. Do not line-split them
    # into fake top-level commands. Shell receivers still re-inspect the body.
    stripped, shell_heredocs, unquoted_heredocs = extract_heredocs(text)
    if stripped is None:
        print(UNRESOLVED_COMMAND_MARKER)
        return
    text = stripped

    # 引用/置換の内側の改行で論理行を千切らない（split_shell_logical_lines の CaD 参照）。
    # 未終端の引用・置換は None → 従来どおり unresolved で fail-closed。
    lines = split_shell_logical_lines(text)
    if lines is None:
        print(UNRESOLVED_COMMAND_MARKER)
        return
    if not lines:
        emit_segment_line(text)
    else:
        for line in lines:
            emit_segment_line(line)

    for heredoc_body in shell_heredocs:
        if heredoc_body.strip():
            emit_segments(heredoc_body, depth + 1)

    # Unquoted here-doc bodies expand $()/backticks; inspect those only.
    for heredoc_body in unquoted_heredocs:
        expansion_bodies = shell_substitution_bodies(heredoc_body)
        if expansion_bodies is None:
            print(UNRESOLVED_COMMAND_MARKER)
            return
        for body in expansion_bodies:
            emit_segments(body, depth + 1)

    substitution_bodies = shell_substitution_bodies(text)
    if substitution_bodies is None:
        print(UNRESOLVED_COMMAND_MARKER)
        return
    for body in substitution_bodies:
        emit_segments(body, depth + 1)

    segments = segment_tokens(text)
    if segments is None:
        print(UNRESOLVED_COMMAND_MARKER)
        return
    if depth > 0 and not text.strip():
        print(UNRESOLVED_COMMAND_MARKER)
        return
    if depth > 0 and text.strip() and not segments:
        print(UNRESOLVED_COMMAND_MARKER)
        return

    for segment in segments:
        index = shell_start_index(segment)
        if index is None:
            continue
        lookahead = index + 1
        tokens = segment
        while lookahead < len(tokens) and tokens[lookahead].startswith("-"):
            option_token = tokens[lookahead]
            option = option_token.lstrip("-")
            if not option_token.startswith("--") and "c" in option:
                command_index = lookahead + 1
                if command_index < len(tokens) and tokens[command_index] == "--":
                    command_index += 1
                if command_index >= len(tokens):
                    print(UNRESOLVED_COMMAND_MARKER)
                    break
                try:
                    nested_command = decode_shell_command(tokens[command_index])
                except Exception:
                    # A malformed nested shell argument must fail closed.
                    print(UNRESOLVED_COMMAND_MARKER)
                    break
                if has_unresolved_shell_expansion(nested_command):
                    # Do not evaluate shell variables/substitutions in the hook. The body may
                    # resolve to destructive Git after the hook returns, so static inspection is
                    # impossible without executing untrusted input.
                    #
                    # [2026-08-02][fix] git 無縁の nested body まで deny しない（issue #1313 案3の
                    # 安全部分集合）。
                    # 背景:
                    #   - ユーザー依頼意図: `bash -c '... echo "exit=$?" ...'` のような、git を
                    #     一切含まない body が $? / $VAR だけで unresolved 扱いされ deny される
                    #     摩擦を解消したい（実測: 1セッション3回）。
                    #   - 守るべき業務ルール: 本 hook の守備範囲は破壊的 Git のみ（冒頭 CaD）。
                    #     "git" が現れない body は展開後も git になり得る余地を静的に持たない
                    #     （g${X}it 型の難読化は変数側に "git" が現れないが、その場合 body 内に
                    #     substring "git" が無くても executable 難読化は既存の変数 executable
                    #     fail-close が上流で拾う）。substring 判定（大文字小文字無視・単語境界
                    #     なし）を使い、"digital" 等を含む body も deny 側へ倒す（安全側の過剰）。
                    #   - 他案不採用理由: unresolved wrapper 全面緩和（案3全体）は影響範囲が
                    #     読めず不採用。データ引数の値の除外は $( ) 置換の免除リスクがあり不採用。
                    #     git 文字列の有無だけの判定は変数 executable を素通りさせるため不採用
                    #     （安全証明は nested_body_safely_non_git に集約）。
                    if not nested_body_safely_non_git(nested_command):
                        print(UNRESOLVED_COMMAND_MARKER)
                    break
                emit_segments(nested_command, depth + 1)
                break
            if option_token in {"-o", "-O", "--rcfile", "--init-file"} and lookahead + 1 < len(tokens):
                lookahead += 2
                continue
            lookahead += 1

emit_segments(cmd)
PY
)"

if printf '%s\n' "${command_segments}" | grep -Fqx '__UNRESOLVED_COMMAND_WRAPPER__'; then
  block_json "unresolved command wrapper"
  exit 0
fi

# [2026-08-02][fix] inline override は実行対象の git に直結する assignment だけを許可する。
# 背景:
#   - ユーザー依頼意図: `printf` / `echo` の引数や別 segment に書かれた
#     `AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1` を、破壊的 git 復旧の許可と誤認しないようにする。
#   - 守るべき業務ルール: 破壊的 Git 操作は fail-closed で止め、明示的な復旧時だけ
#     inherited env または実行対象 `git` の直前 assignment による inline override を許可する。
#   - 他案不採用理由:
#     1) コマンド全体 grep の継続は、文字列・引数・別 segment の偽装を検出できず Critical を再発させる。
#     2) 生成された PJ 側 hook の手修正は中央正本を迂回して再発する。
#     3) `git clean` の設定値列挙やルール文だけの禁止は、迂回経路を原理的に閉じない。
#     4) 新規外部依存や全面的な shell parser 導入は、配布対象を増やし保守境界を曖昧にする。
# 対応: Python 標準 `shlex` で単一の shell segment を tokenize し、segment 全体が実コマンド先頭の
# assignment token 直後の裸の `git` の場合だけ inline bypass を許可する。separator・改行・引用符・
# 通常引数・別 segment の文字列は許可せず、tokenize 失敗時は `0` を返して安全側に倒す。
inline_bypass="$(
  COMMAND_TEXT="${command}" python3 - <<'PY' 2>/dev/null || printf '0'
import os
import re
import shlex

BYPASS = "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
PUNCTUATION = ";&|(){}"
text = os.environ.get("COMMAND_TEXT", "")

def validate_punctuation(tokens):
    expected = []
    pairs = {"(": ")", "{": "}"}
    for token in tokens:
        if not token or not all(char in PUNCTUATION for char in token):
            continue
        for char in token:
            if char in pairs:
                expected.append(pairs[char])
            elif char in {")", "}"} and (not expected or expected.pop() != char):
                raise ValueError("unbalanced shell punctuation")
    if expected:
        raise ValueError("unbalanced shell punctuation")

try:
    # posix=True validates quoting/escaping; posix=False retains quote markers
    # so a quoted assignment cannot become an override token.
    validator = shlex.shlex(text, posix=True, punctuation_chars=PUNCTUATION)
    validator.whitespace_split = True
    list(validator)
    lexer = shlex.shlex(text, posix=False, punctuation_chars=PUNCTUATION)
    lexer.whitespace_split = True
    tokens = list(lexer)
    validate_punctuation(tokens)
    if "\n" in text or any(token and all(char in PUNCTUATION for char in token) for token in tokens):
        print("0")
        raise SystemExit
except Exception:
    print("0")
    raise SystemExit

index = 0
while index < len(tokens) and ASSIGNMENT.fullmatch(tokens[index]):
    index += 1
if index > 0 and index < len(tokens):
    if tokens[index] == "git" and tokens[index - 1] == BYPASS:
        print("1")
        raise SystemExit

print("0")
PY
)"
if [ "${inline_bypass}" = "1" ]; then
  # telemetry(harness-checkup): 緊急バイパスを記録(黙って通さない)。
  agent_hub_telemetry_log hook_bypass block-destructive-git allow '{"env":"AGENT_HUB_ALLOW_DESTRUCTIVE_GIT"}' 2>/dev/null || true
  allow_json
  exit 0
fi

reset_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+reset([[:space:]][^;&|()]*)?[[:space:]]--hard([[:space:]]|$)" || true)"
if [ -n "${reset_segments}" ]; then
  block_json "git reset --hard"
  exit 0
fi

clean_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+clean([[:space:]]|$)" || true)"
if [ -n "${clean_segments}" ]; then
  while IFS= read -r segment; do
    [ -z "${segment}" ] && continue
    clean_args="$(printf '%s' "${segment}" | sed -E "s#${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+clean([[:space:]]|$)##")"
    if printf '%s' "${clean_args}" | grep -Eq '(^|[[:space:]])(--dry-run|-n|-n[a-zA-Z]*|-[a-zA-Z]*n[a-zA-Z]*)([[:space:]]|$)'; then
      continue
    fi
    # [2026-08-01][fix] `-f` の有無で判定すると設定経由で迂回できる（codex-review Critical）。
    # 背景:
    #   - ユーザー依頼意図: 破壊的 git 操作ガードが「実際に消せるコマンド」を取り逃がさないようにする。
    #   - 守るべき業務ルール: `git clean` は `clean.requireForce=false` を渡すと `-f` 無しで
    #     未追跡ファイルを削除できる。`git -c clean.requireForce=false clean -dx` は `.env` 等の
    #     ローカル秘匿ファイルまで消すため、`-f` を探す実装では素通りする（実測で PASS を確認）。
    #   - 他案不採用理由:
    #     1) `-c clean.requireForce=false` を追加でパターン検出する案は、`GIT_CONFIG_*` 環境変数や
    #        `--config-env`、既存の repo/global 設定でも同じ状態を作れるため、列挙が原理的に閉じない。
    #     2) 実際の設定値を読んで判定する案は、hook が対象 repo を確定できない場面（複合コマンド・
    #        `--git-dir` 指定）で誤判定するため不採用。
    # 対応: dry-run でない `git clean` は一律 deny する。dry-run は上の continue で通過済み。
    block_json "git clean（--dry-run / -n 以外）"
    exit 0
  done <<EOF
${clean_segments}
EOF
fi

checkout_path_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+checkout([[:space:]][^;&|()]*)?[[:space:]]--[[:space:]]+[^[:space:]]+" || true)"
if [ -n "${checkout_path_segments}" ]; then
  block_json "git checkout -- <path>"
  exit 0
fi

# [2026-08-02][fix] `--` なし checkout の曖昧な位置引数を fail-closed にする。
# 背景:
#   - ユーザー依頼意図: 全PJ共通の破壊的Git guardで、`git checkout README.md` や
#     `git checkout .` によるtracked変更の暗黙破棄も確実に止める。
#   - 守るべき業務ルール: checkoutの単一位置引数はbranch名とpathspecを静的に完全判別できないため、
#     読み取りだけでpathだと断定できない場合も安全側へ倒す。branch移動には`git switch`を使う。
#   - 他案不採用理由: 拡張子・`/`・実在pathだけを列挙する案は、拡張子のないfile、glob、
#     `git -C`先のpathを取り逃がす。hook内でGitのref/path解決を実行する案はrepo/cwd境界を誤る。
# 対応: 明示的な新規branch作成（`-b` / `--orphan`）、detach、help/versionだけを許可し、
#   `-p` / `--ours` / `--theirs` / `-B` 等を含む残りのcheckoutは一律denyする。
#   安全optionは最初の位置引数より前にある場合だけ許可し、pathspec後ろのoptionで
#   branch作成/detachへ見せかける並び替えは許可しない。安全モード後も引数個数を固定する。
checkout_ambiguous_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+checkout([[:space:]]|$)" || true)"
if [ -n "${checkout_ambiguous_segments}" ]; then
  while IFS= read -r segment; do
    [ -z "${segment}" ] && continue
    checkout_args="$(printf '%s' "${segment}" | sed -E "s#${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+checkout([[:space:]]|$)##")"
    checkout_tokens=()
    if [ -n "${checkout_args}" ]; then
      read -r -a checkout_tokens <<< "${checkout_args}"
    fi
    checkout_count="${#checkout_tokens[@]}"
    checkout_index=0
    checkout_safe=0
    checkout_invalid=0
    while (( checkout_index < checkout_count )); do
      checkout_token="${checkout_tokens[checkout_index]}"
      case "${checkout_token}" in
        -q|--quiet|-m|--merge)
          checkout_index=$((checkout_index + 1))
          ;;
        --help|--version)
          if (( checkout_index + 1 == checkout_count )); then
            checkout_safe=1
          else
            checkout_invalid=1
          fi
          break
          ;;
        -b|--orphan)
          if (( checkout_index + 2 == checkout_count )); then
            checkout_branch="${checkout_tokens[checkout_index + 1]}"
            if [ -n "${checkout_branch}" ] && [[ "${checkout_branch}" != -* ]]; then
              checkout_safe=1
            else
              checkout_invalid=1
            fi
          else
            checkout_invalid=1
          fi
          break
          ;;
        --detach)
          if (( checkout_index + 1 == checkout_count )); then
            checkout_safe=1
          elif (( checkout_index + 2 == checkout_count )); then
            checkout_ref="${checkout_tokens[checkout_index + 1]}"
            if [ -n "${checkout_ref}" ] && [[ "${checkout_ref}" != -* ]]; then
              checkout_safe=1
            else
              checkout_invalid=1
            fi
          else
            checkout_invalid=1
          fi
          break
          ;;
        *)
          checkout_invalid=1
          break
          ;;
      esac
    done
    if (( checkout_safe == 1 && checkout_invalid == 0 )); then
      continue
    fi
    block_json "git checkout（pathspec ambiguity; use git switch for branches）"
    exit 0
  done <<EOF
${checkout_ambiguous_segments}
EOF
fi

# [2026-06-19][fix]
# 背景:
#   - PRレビューで `git checkout -qf main` / `git checkout -fB branch` のような結合短縮
#     オプションと、`command git reset --hard` / `env git clean -fd` / `sudo git reset --hard` /
#     `bash -lc 'git reset --hard'` などの実行前置きがすり抜けうると判明した。
#   - 守るべき業務ルール: tracked local changes を暗黙に破棄する checkout/switch は、
#     `-f` 単体だけでなく `-qf` 等の結合形も同じく止める。git 実行前置きは
#     実コマンドとして扱うが、`echo git ...` のような説明文は止めない。
#   - 他案不採用理由: 単一 grep だけで簡略化する案は `-[a-z]*f` を落としやすく、
#     2026-06-15 版の安全策を後退させるため不採用。
force_branch_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+(checkout|switch)([[:space:]]|$)" || true)"
if [ -n "${force_branch_segments}" ]; then
  while IFS= read -r segment; do
    [ -z "${segment}" ] && continue
    branch_args="$(printf '%s' "${segment}" | sed -E "s#${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+(checkout|switch)([[:space:]]|$)##")"
    if printf '%s' "${branch_args}" | grep -Eq '(^|[[:space:]])--discard-changes([[:space:]]|$)'; then
      block_json "git switch --discard-changes"
      exit 0
    fi
    if printf '%s' "${branch_args}" | grep -Eq '(^|[[:space:]])(--force|-f|-[A-Za-z]*f[A-Za-z]*)([[:space:]]|$)'; then
      block_json "git checkout/switch --force"
      exit 0
    fi
  done <<EOF
${force_branch_segments}
EOF
fi

restore_segments="$(printf '%s\n' "${command_segments}" | grep -E "${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+restore([[:space:]]|$)" || true)"
if [ -n "${restore_segments}" ]; then
  while IFS= read -r segment; do
    [ -z "${segment}" ] && continue
    restore_args="$(printf '%s' "${segment}" | sed -E "s#${GIT_SEGMENT_START}${GIT_GLOBAL_OPTS}[[:space:]]+restore([[:space:]]|$)##")"
    if printf '%s' "${restore_args}" | grep -Eq '(^|[[:space:]])(--worktree|-W|-[A-Za-z]*W[A-Za-z]*)([[:space:]]|$)'; then
      block_json "git restore --worktree <path>"
      exit 0
    fi
    if printf '%s' "${restore_args}" | grep -Eq '(^|[[:space:]])(--staged|-S|-[A-Za-z]*S[A-Za-z]*)([[:space:]]|$)'; then
      continue
    fi
    block_json "git restore <path>"
    exit 0
  done <<EOF
${restore_segments}
EOF
fi

allow_json
exit 0
