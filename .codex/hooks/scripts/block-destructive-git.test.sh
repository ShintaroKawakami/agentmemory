#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/block-destructive-git.sh"
PASS=0
FAIL=0

run_hook() {
  local command="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$command")" | bash "$SCRIPT"
}

run_hook_raw() {
  local payload="$1"
  printf '%s' "$payload" | bash "$SCRIPT"
}

expect_block() {
  local name="$1"
  local command="$2"
  local out
  out="$(run_hook "$command" 2>&1)"
  if OUT="$out" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["OUT"])
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)

payload = data.get("hookSpecificOutput", {})
if payload.get("hookEventName") != "PreToolUse":
    sys.exit(1)
if payload.get("permissionDecision") != "deny":
    sys.exit(1)
reason = payload.get("permissionDecisionReason", "")
if "[hook:block-destructive-git]" not in reason:
    sys.exit(1)
if "reason" in payload:
    sys.exit(1)
PY
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_allow() {
  local name="$1"
  local command="$2"
  local out
  out="$(run_hook "$command" 2>&1)"
  if printf '%s' "$out" | grep -q '"continue": true'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_allow_inherited_env() {
  local name="$1"
  local command="$2"
  local out
  out="$(AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 run_hook "$command" 2>&1)"
  if printf '%s' "$out" | grep -q '"continue": true'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_block_raw() {
  local name="$1"
  local payload="$2"
  local out
  out="$(run_hook_raw "$payload" 2>&1)"
  if OUT="$out" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["OUT"])
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)

payload = data.get("hookSpecificOutput", {})
if payload.get("hookEventName") != "PreToolUse":
    sys.exit(1)
if payload.get("permissionDecision") != "deny":
    sys.exit(1)
if "[hook:block-destructive-git]" not in payload.get("permissionDecisionReason", ""):
    sys.exit(1)
PY
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_embedded_python_py39() {
  local name="embedded Python blocks parse as Python 3.9"
  local out
  if out="$(HOOK_SCRIPT="$SCRIPT" python3 - <<'PY' 2>&1
import ast
import os
import re

source = open(os.environ["HOOK_SCRIPT"], encoding="utf-8").read()
blocks = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY(?:\n|$)", source, re.S)
if not blocks:
    raise SystemExit("no embedded Python blocks found")
for index, block in enumerate(blocks, 1):
    try:
        tree = ast.parse(block, feature_version=(3, 9))
    except SyntaxError as exc:
        raise SystemExit(f"block {index}: {exc}")
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            returns = node.returns
            if isinstance(returns, ast.BinOp) and isinstance(returns.op, ast.BitOr):
                raise SystemExit(f"block {index}: Python 3.10 union return annotation")
PY
)"; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_double_quote_single_quote_scanner() {
  local name="double quote内single quote後のvariable expansionを検出"
  if HOOK_SCRIPT="$SCRIPT" python3 - <<'PY'
import os
import re

source = open(os.environ["HOOK_SCRIPT"], encoding="utf-8").read()
blocks = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY(?:\n|$)", source, re.S)
scanner_blocks = [block for block in blocks if "def has_unresolved_shell_expansion" in block]
if len(scanner_blocks) != 1:
    raise SystemExit(f"expected one scanner block, got {len(scanner_blocks)}")
namespace = {}
exec(scanner_blocks[0], namespace)
scanner = namespace["has_unresolved_shell_expansion"]
if not scanner('echo "\'"; $PAYLOAD'):
    raise SystemExit("variable expansion after a single quote inside double quotes was missed")
PY
  then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

expect_embedded_python_py39
expect_double_quote_single_quote_scanner
expect_block "git reset --hard deny" "git reset --hard"
expect_block "/usr/bin/git reset --hard deny" "/usr/bin/git reset --hard"
expect_block "command /usr/bin/git clean -fd deny" "command /usr/bin/git clean -fd"
expect_block "quoted /usr/bin/git reset --hard deny" "\"/usr/bin/git\" reset --hard"
expect_block "quoted ./bin/git clean -fd deny" "'./bin/git' clean -fd"
expect_block "quoted path with spaces git reset --hard deny" "\"/tmp/git tools/git\" reset --hard"
expect_block "consecutive-slash /usr//bin/git reset --hard deny" "/usr//bin/git reset --hard"
expect_block "consecutive-slash ./bin//git clean -fd deny" "./bin//git clean -fd"
expect_block "git -C reset --hard deny" "git -C /tmp/repo reset --hard origin/main"
expect_block "git -C path with spaces reset --hard deny" "git -C '/tmp/repo with spaces' reset --hard origin/main"
expect_block "git --git-dir/--work-tree path with spaces clean deny" "git --git-dir='/tmp/repo with spaces/.git' --work-tree '/tmp/repo with spaces' clean -fd"
expect_block "command git reset --hard deny" "command git reset --hard"
expect_block "env git clean -fd deny" "env git clean -fd"
expect_block "/usr/bin/env git clean -fd deny" "/usr/bin/env git clean -fd"
expect_block "/usr/bin/env -u FOO git reset --hard deny" "/usr/bin/env -u FOO git reset --hard"
expect_block "env assignment git checkout -f deny" "env FOO=bar git checkout -f main"
expect_block "sudo git reset --hard deny" "sudo git reset --hard"
expect_block "exec git reset --hard deny" "exec git reset --hard"
expect_block "exec alternate argv0 still finds git" "exec -a harmless /usr/bin/git reset --hard"
expect_block "exec unknown option fail closed" "exec --future-option /usr/bin/git reset --hard"
expect_block "sudo git clean -fd deny" "sudo -n git clean -fd"
expect_block "sudo -u root git reset --hard deny" "sudo -u root git reset --hard"
expect_block "sudo --user root path git reset --hard deny" "sudo --user root /usr/bin/git reset --hard"
expect_block "sudo --user=root path git reset --hard deny" "sudo --user=root /usr/bin/git reset --hard"
expect_block "sudo -- terminator path git reset --hard deny" "sudo -- /usr/bin/git reset --hard"
expect_block "sudo short chdir option still finds git" "sudo -D /tmp /usr/bin/git reset --hard"
expect_block "sudo long chdir option still finds git" "sudo --chdir /tmp /usr/bin/git clean -fd"
expect_block "sudo unknown option fail closed" "sudo --future-option /usr/bin/git reset --hard"
expect_block "sudo env path git reset --hard deny" "sudo env /usr/bin/git reset --hard"
expect_block "command env path git clean -fd deny" "command env /usr/bin/git clean -fd"
expect_block "env -u FOO git clean -fd deny" "env -u FOO git clean -fd"
expect_block "env -S reset payload fail closed" "env -S '/usr/bin/git reset --hard'"
expect_block "env --split-string clean payload fail closed" "env --split-string='/usr/bin/git clean -fd'"
expect_block "env unknown option before git fail closed" "env --future-option /usr/bin/git reset --hard"
expect_block "env ignore-environment still finds git" "env -i /usr/bin/git reset --hard"
expect_block "env attached unset still finds git" "env --unset=FOO /usr/bin/git clean -fd"
expect_block "env option terminator still finds git" "env -- /usr/bin/git reset --hard"
expect_block "time macOS long report still finds git" "/usr/bin/time -l /usr/bin/git reset --hard"
expect_block "time output option still finds git" "/usr/bin/time -o /tmp/timing.txt /usr/bin/git clean -fd"
expect_block "time unknown option before git fail closed" "/usr/bin/time --future-option /usr/bin/git reset --hard"
expect_block "eval path git reset fail closed" "eval /usr/bin/git reset --hard"
expect_block "eval quoted git reset fail closed" "eval 'git reset --hard'"
expect_block "nested eval quoted git reset fail closed" "bash -c 'eval \"git reset --hard\"'"
expect_block "nested eval git clean fail closed" "bash -c 'eval git clean -fd'"
expect_block "variable executable path fail closed" 'G=/usr/bin/git; "$G" reset --hard'
expect_block "variable executable basename fail closed" 'GIT=git; $GIT clean -fd'
expect_block "command substitution executable fail closed" '$(printf /usr/bin/git) reset --hard'
expect_block "zsh equals executable reset fail closed" "=git reset --hard"
expect_block "zsh equals executable clean fail closed" "=git clean -fd"
expect_block "brace group variable executable fail closed" '{ "$G" reset --hard; }'
expect_block "brace group command substitution executable fail closed" '{ $(printf git) clean -fd; }'
expect_block "paren group variable executable fail closed" '( "$G" reset --hard )'
expect_block "function body variable executable fail closed" 'danger(){ "$G" reset --hard; }; danger'
expect_block "function body command substitution executable fail closed" 'danger(){ $(printf git) clean -fd; }; danger'
expect_block "quoted argument command substitution reset deny" 'printf '\''%s'\'' "$(git reset --hard)"'
expect_block "quoted argument command substitution clean deny" 'echo "$(git clean -fd)"'
expect_block "argument process substitution restore deny" 'cat <(git restore src/app.ts)'
expect_block "argument backtick checkout deny" 'printf '\''%s'\'' "`git checkout -f main`"'
nested_backtick_argument='echo "`echo \`git reset --hard\``"'
expect_block "nested legacy backtick reset fail closed" "$nested_backtick_argument"
expect_block "nested argument substitution reset deny" 'printf '\''%s'\'' "$(printf '\''%s'\'' "$(git reset --hard)")"'
expect_block "arithmetic nested substitution clean deny" 'printf '\''%s'\'' "$((1 + $(git clean -fd)))"'
expect_block "case pattern esac text cannot hide reset" 'printf '\''%s'\'' "$(case esac in *esac*) git reset --hard ;; esac)"'
comment_substitution="printf '%s' \"\$( # )
git reset --hard)\""
expect_block "comment close paren cannot hide reset" "$comment_substitution"
comment_continuation_substitution="printf '%s' \$(echo ok # )
g\\
it reset --hard)"
expect_block "comment and line continuation cannot hide reset" "$comment_continuation_substitution"
comment_line_continuation="printf x # foo\\
git reset --hard"
expect_block "comment line continuation cannot swallow next reset" "$comment_line_continuation"
comment_after_separator="printf x; # foo\\
git clean -fd"
expect_block "separator comment continuation cannot swallow next clean" "$comment_after_separator"
comment_crlf_continuation=$'printf x # foo\\\r\n\tgit reset --hard'
expect_block "CRLF comment continuation cannot swallow next reset" "$comment_crlf_continuation"
comment_multiple_continuation=$'printf x # foo\\\ng\\\ni\\\nt clean -fd'
expect_block "comment with multiple continuations cannot hide clean" "$comment_multiple_continuation"
parameter_length_continuation="x=value; : \${#x}; g\\
it reset --hard"
expect_block "parameter length hash is not a comment" "$parameter_length_continuation"
expect_allow "real comment remains inert" 'printf x # git reset --hard'
continued_git="g\\
it reset --hard"
expect_block "line continuation executable reset deny" "$continued_git"
continued_git_multiple="g\\
i\\
t clean -fd"
expect_block "multiple line continuations executable clean deny" "$continued_git_multiple"
continued_git_quoted="printf '%s' \"\$(g\\
it reset --hard)\""
expect_block "double quoted continuation executable reset deny" "$continued_git_quoted"
single_quoted_continuation="printf '%s' 'g\\
it reset --hard'"
expect_block "single quoted continuation remains conservative deny" "$single_quoted_continuation"
expect_block "parameter pattern close paren cannot hide reset" 'printf '\''%s'\'' "$(x=x; : ${x%)}; git reset --hard)"'
heredoc_substitution="printf '%s' \"\$(cat <<EOF
)
EOF
git reset --hard
)\""
expect_block "heredoc close paren remains fail closed" "$heredoc_substitution"
expect_block "regex close paren remains fail closed" 'printf '\''%s'\'' "$(if [[ x =~ x) ]]; then :; fi; git reset --hard)"'
expect_block "top-level question glob executable fail closed" "/usr/bin/g?t reset --hard"
expect_block "top-level character class executable fail closed" "/usr/bin/g[i]t clean -fd"
expect_block "top-level brace executable fail closed" "/usr/bin/g{it} reset --hard"
expect_block "single quote in parent path still finds git" '"/tmp/git'\'' tools/git" reset --hard'
expect_block "double quote in parent path still finds git" "'/tmp/git\" tools/git' reset --hard"
expect_block "bang git reset --hard deny" "! git reset --hard"
expect_block "while git clean -fd deny" "while git clean -fd; do echo retry; done"
expect_block "bash -lc git reset --hard deny" "bash -lc 'git reset --hard'"
expect_block "bash -c quoted path git reset --hard deny" "bash -c '\"/usr/bin/git\" reset --hard'"
expect_block "quoted /bin/bash -c git reset --hard deny" "\"/bin/bash\" -c 'git reset --hard'"
expect_block "quoted /bin/sh -c git reset --hard deny" "\"/bin/sh\" -c 'git reset --hard'"
expect_block "bash -c -- git reset --hard deny" "bash -c -- 'git reset --hard'"
expect_block "bash -lc multiline git reset --hard deny" "bash -lc 'echo ok
git reset --hard'"
expect_block "bash -o pipefail -c git reset --hard deny" "bash -o pipefail -c 'git reset --hard'"
expect_block "zsh -lc git checkout -f deny" "zsh -lc 'git checkout -f main'"
expect_block "nested bash -c git reset --hard deny" "bash -c 'bash -c \"git reset --hard\"'"
expect_block "nested path-qualified quoted shell git reset --hard deny" "\"/bin/bash\" -c '\"/usr/bin/sh\" -c \"git reset --hard\"'"
expect_block "malformed nested shell wrapper fail closed" "bash -c 'bash -c \"git reset --hard'"
# [2026-08-02][test] nested shell body の未解決展開は実行せず fail-closed にする。
expect_block "bash -c variable body fail closed" 'PAYLOAD="git reset --hard"; bash -c "$PAYLOAD"'
expect_block "bash -c braced variable body fail closed" 'bash -c "${PAYLOAD}"'
expect_block "sh -c command substitution body fail closed" "sh -c '\$(printf git) reset --hard'"
dynamic_backtick_body="zsh -c '\`printf git\` reset --hard'"
expect_block "zsh -c backtick body fail closed" "$dynamic_backtick_body"
expect_block "bash -c process substitution body fail closed" "bash -c '<(printf git) reset --hard'"
expect_block "bash -c question glob executable fail closed" "bash -c '/usr/bin/g?t reset --hard'"
expect_block "bash -c character class executable fail closed" "bash -c '/usr/bin/g[i]t clean -fd'"
expect_block "bash -c brace executable fail closed" "bash -c '/usr/bin/g{it} reset --hard'"
expect_block "zsh -c glob qualifier executable fail closed" "zsh -c '/usr/bin/git(.) reset --hard'"
expect_block "bash -c extglob executable fail closed" "bash -c '@(git) reset --hard'"
expect_allow "bash -c escaped dollar remains a static body" 'bash -c '\''printf "\$PAYLOAD"'\'''
expect_allow "bash -c quoted glob remains static" "bash -c 'printf \"?*[{\"'"
expect_allow "bash -c quoted qualifier and extglob remain static" "bash -c 'printf \"(.) @(git)\"'"
nested_shell_command="$(python3 - <<'PY'
import shlex

command = "git reset --hard"
for _ in range(8):
    command = "bash -c " + shlex.quote(command)
print(command)
PY
)"
expect_block "nested shell depth limit fail closed" "$nested_shell_command"
expect_block "if git reset --hard deny" "if git reset --hard; then echo ok; fi"
expect_block "brace git restore deny" "{ git restore src/app.ts; }"
expect_block "git clean -fd deny" "git clean -fd"
expect_block "git checkout -- path deny" "git checkout -- README.md"
expect_block "git checkout path without separator deny" "git checkout README.md"
expect_block "git checkout dot path deny" "git checkout ."
expect_block "git checkout relative path deny" "git checkout ./src/app.ts"
expect_block "git checkout tree and path deny" "git checkout HEAD README.md"
expect_block "git checkout patch path deny" "git checkout -p README.md"
expect_block "git checkout long patch path deny" "git checkout --patch README.md"
expect_block "git checkout ours path deny" "git checkout --ours README.md"
expect_block "git checkout theirs path deny" "git checkout --theirs README.md"
expect_block "git checkout no-overlay path deny" "git checkout --no-overlay README.md"
expect_block "git checkout conflict path deny" "git checkout --conflict=merge README.md"
expect_block "git checkout recurse-submodules path deny" "git checkout --recurse-submodules README.md"
expect_block "git checkout no-guess ambiguity deny" "git checkout --no-guess README.md"
expect_block "git checkout reset branch deny" "git checkout -B feature/reset"
expect_block "git checkout path before branch option deny" "git checkout README.md -b feature/safe"
expect_block "git checkout path before detach option deny" "git checkout README.md --detach"
expect_block "git checkout quoted path before branch option deny" "git checkout 'README.md' '-b' feature/safe"
expect_block "git checkout ref and path before branch option deny" "git checkout HEAD README.md -b feature/safe"
expect_block "git checkout -f deny" "git checkout -f main"
expect_block "git checkout -qf deny" "git checkout -qf main"
expect_block "git checkout -fB deny" "git checkout -fB feature/test"
expect_block "git switch -f deny" "git switch -f feature/test"
expect_block "git switch --force deny" "git switch --force feature/test"
expect_block "git switch --discard-changes deny" "git switch --discard-changes main"
expect_block "git restore path deny" "git restore src/app.ts"
expect_block "sudo -S git restore path deny" "sudo -S git restore src/app.ts"
expect_block "git restore --worktree deny" "git restore --worktree src/app.ts"
expect_block "git restore --staged --worktree deny" "git restore --staged --worktree src/app.ts"
expect_block "multiline git reset --hard deny" "git status
git reset --hard"
expect_block "multiline git clean -fd deny" "echo ok
git clean -fd"
expect_block_raw "Kimi toolInput Shell git reset --hard deny" '{"toolName":"Shell","toolInput":{"command":"git reset --hard"}}'
expect_block "command -p git reset --hard deny" "command -p git reset --hard"
expect_block "command -- path git reset --hard deny" "command -- /usr/bin/git reset --hard"
expect_block "command -p -- path git reset --hard deny" "command -p -- /usr/bin/git reset --hard"
expect_block "builtin -- path git reset --hard deny" "builtin -- /usr/bin/git reset --hard"
expect_block "time -p git clean -fd deny" "time -p git clean -fd"
expect_block "sudo attached user path git reset --hard deny" "sudo -uroot /usr/bin/git reset --hard"
expect_block "nice git reset --hard deny" "nice git reset --hard"
expect_block "nice -n adjustment path git reset --hard deny" "nice -n 10 /usr/bin/git reset --hard"
expect_block "nice attached adjustment git reset --hard deny" "nice -n10 git reset --hard"
expect_block "nohup git clean -fd deny" "nohup git clean -fd"
expect_block "nohup terminator path git clean -fd deny" "nohup -- /usr/bin/git clean -fd"
expect_block "timeout git reset --hard deny" "timeout 5 git reset --hard"
expect_block "timeout git clean -fd deny" "timeout 5 /usr/bin/git clean -fd"
expect_block "timeout kill-after path git reset --hard deny" "timeout --kill-after=2 5 command git reset --hard"
expect_block "timeout unknown option fail closed" "timeout --unknown 5 git reset --hard"
expect_block "timeout missing command fail closed" "timeout 5"
expect_block "timeout invalid duration fail closed" "timeout git reset --hard"
expect_block "timeout dynamic duration fail closed" 'timeout "$DURATION" git status'
expect_block "timeout split duration cannot inject git" "D='5 git'; timeout \$D reset --hard"
expect_block "timeout dynamic signal fail closed" 'timeout -s "$SIGNAL" 5 git status'
expect_block "timeout dynamic kill-after fail closed" 'timeout --kill-after="$DELAY" 5 git status'
expect_allow "timeout help does not run a command" "timeout --help"
expect_block "nice unknown option fail closed" "nice --unknown git reset --hard"
expect_block "nohup unknown option fail closed" "nohup --unknown git clean -fd"
expect_block "nice unresolved adjustment fail closed" "nice -n git reset --hard"
# [2026-08-01][test] `-f` 検出だけでは設定経由で迂回できる（codex-review Critical の回帰）。
# clean.requireForce=false を渡すと -f 無しで未追跡ファイルが実際に消えるため、
# dry-run 以外の git clean は一律 deny する。
expect_block "git -c clean.requireForce=false clean -d deny" "git -c clean.requireForce=false clean -d"
expect_block "git -c clean.requireForce=false clean -dx deny" "git -c clean.requireForce=false clean -dx"
expect_block "git clean -d (force なし) deny" "git clean -d"
expect_block "git clean (引数なし) deny" "git clean"
expect_allow "git restore --staged allow" "git restore --staged src/app.ts"
expect_allow "git clean -nfd allow" "git clean -nfd"
expect_allow "git clean --dry-run allow" "git clean --dry-run -d"
expect_allow "git status allow" "git status --short"
expect_allow "git checkout new branch allow" "git checkout -b feature/safe-branch"
expect_allow "git checkout quiet new branch allow" "git checkout -q -b feature/safe-branch"
expect_allow "git checkout orphan branch allow" "git checkout --orphan feature/orphan"
expect_allow "git checkout detached ref allow" "git checkout --detach HEAD"
expect_allow "git checkout help allow" "git checkout --help"
expect_allow "git checkout quiet detach allow" "git checkout --quiet --detach HEAD"
expect_allow "dynamic argument with static executable allow" 'printf "%s\\n" "$PAYLOAD"'
expect_allow "safe quoted command substitution allow" 'printf '\''%s'\'' "$(pwd)"'
expect_allow "safe backtick substitution allow" 'printf '\''%s'\'' "`pwd`"'
safe_continued_argument="printf '%s' g\\
it"
expect_allow "line continuation inside a static argument allow" "$safe_continued_argument"
joined_hash_word="printf '%s' foo\\
#bar"
expect_allow "line continuation before hash keeps one word" "$joined_hash_word"
expect_allow "hash inside a word is not a shell comment" 'printf '\''%s'\'' "$(printf foo#bar)"'
expect_allow "single quoted parameter text stays literal" 'printf '\''%s'\'' "$(printf '\''${x%)}'\'')"'
expect_allow "single quoted substitution text allow" 'echo '\''$(git reset --hard)'\'''
expect_allow "escaped substitution text allow" 'echo "\$(git reset --hard)"'
expect_allow "test builtin brackets remain static" 'if [ 1 = 1 ]; then printf ok; fi'
expect_allow "brace group remains static" '{ printf ok; }'
expect_allow "non-git basename path containing git allow" "\"/tmp/git tools/notgit\" reset --hard"
expect_allow "quoted git checkout text allow" "echo 'git checkout -f main is dangerous'"
expect_allow "plain echoed git checkout text allow" "echo git checkout -f main is dangerous"
expect_allow "plain echoed bash -lc text allow" "echo bash -lc 'git reset --hard'"
expect_allow "git grep bash -lc text allow" "git grep \"bash -lc 'git reset --hard'\" -- README.md"
expect_allow "quoted command git text allow" "echo 'command git reset --hard is dangerous'"
expect_allow "quoted brace git text allow" "echo '{ git restore src/app.ts; }'"
expect_allow "bash --norc is not -c allow" "bash --norc"
expect_allow "explicit override allows reset" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git reset --hard origin/main"
expect_allow_inherited_env "inherited env override allows reset" "git reset --hard origin/main"
expect_block "inline override does not allow later semicolon segment" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git status; git reset --hard"
expect_block "inline override does not allow later and segment" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git status && git reset --hard"
expect_block "inline override does not allow later pipe segment" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git status | git reset --hard"
expect_block "printf assignment then git reset remains deny" "printf '%s\\n' AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 x; git reset --hard"
expect_block "quoted assignment text then git reset remains deny" "printf '%s\\n' 'AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git reset --hard'; git reset --hard"
expect_block "assignment as git argument remains deny" "git reset --hard AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 x"
expect_block "quoted assignment token remains deny" "'AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1' git reset --hard"
expect_block "syntax error cannot enable inline bypass" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git reset --hard '"
expect_block "unbalanced punctuation cannot enable inline bypass" "AGENT_HUB_ALLOW_DESTRUCTIVE_GIT=1 git reset --hard }"

# [2026-08-02][test] Wave B / #1256: here-doc 本文の危険文字列はデータ扱い。
# 背景:
#   - ユーザー依頼意図: commit message / gh body に `git reset --hard` と書いただけで
#     hook が止まり、ガード改善の記録自体ができない friction を直す。
#   - 守るべき業務ルール: 実実行される shell/git 破壊操作は fail-closed のまま。
#   - 他案不採用理由: git commit だけの特例許可は gh/cat 同型摩擦を残す。
commit_heredoc_data="git commit -F - <<'EOF'
document friction: git reset --hard was blocked as data
EOF"
expect_allow "commit -F heredoc danger text allow" "$commit_heredoc_data"
bash_heredoc_script="bash <<'EOF'
git reset --hard
EOF"
expect_block "bash heredoc script reset deny" "$bash_heredoc_script"
gh_body_heredoc="gh issue comment 1 --body \"\$(cat <<'EOF'
body mentions git reset --hard as documentation
EOF
)\""
expect_allow "gh body quoted cat heredoc danger text allow" "$gh_body_heredoc"
cat_then_reset="true \$(cat <<'EOF'
safe body
EOF
; git reset --hard)"
expect_block "cat heredoc then reset in substitution deny" "$cat_then_reset"
unquoted_expand_heredoc="printf '%s' \"\$(cat <<EOF
\$(git reset --hard)
EOF
)\""
expect_block "unquoted cat heredoc nested reset deny" "$unquoted_expand_heredoc"

# [2026-08-02][test] issue #1313 実測誤検知3ケースの許可回帰 + #1344 見逃し2件の deny 回帰。
# 背景:
#   - ユーザー依頼意図: 引用内改行を含むデータ引数（commit message / PR body）と git 無縁の
#     nested body が deny される摩擦（1セッション3〜6回実測）を解消しつつ、独立敵対的レビューが
#     指摘した「データ値の中のコマンド置換は実行される」経路の deny を明示回帰で固定する。
#   - 守るべき業務ルール: 許可回帰と deny 回帰を必ず対で足し、検知力を片側にしか動かさない。
#   - 他案不採用理由: 許可側だけのテストは、将来の実装変更で置換検査が外れても気づけない。
multiline_commit_msg='git commit -m "fix stuff (#1321)

refresh を実行して確認した。

Co-Authored-By: X <a@b.c>
Session: https://claude.ai/code/x"'
expect_allow "multiline commit -m message stays data" "$multiline_commit_msg"
multiline_body='gh pr create --title "t" --body "## 概要
- \`scripts/refresh-project-mcp.py\` を実行
- pre-pr-check PASS"'
expect_allow "multiline gh body with backticks stays data" "$multiline_body"
expect_allow "bash -c non-git body with special params" \
  'bash -c '\''python3 x.py > /tmp/a.txt 2>&1; echo "exit=$?"; tail -3 /tmp/a.txt'\'''
expect_allow "chained add and multiline commit" 'git add -A && git commit -m "one
two"'
expect_block "commit -m command substitution still denied" 'git commit -m "$(git reset --hard)"'
# push --force は本 hook の守備範囲外（ローカル変更破壊系のみ）のため、置換ペイロードは
# 守備範囲内の reset --hard で「データ引数内の置換も deny」を固定する
expect_block "gh body command substitution still denied" 'gh pr create --body "$(git reset --hard)"'
expect_block "bash -c variable body still denied after relaxation" 'bash -c "$BODY"'
# PR #1354 codex-review Critical: 実行 wrapper の引数経由で任意コマンド化する経路を deny 固定
expect_block "bash -c eval variable payload denied" 'bash -c '\''eval $PAYLOAD'\'''
expect_block "bash -c env variable payload denied" 'bash -c '\''env $PAYLOAD'\'''
expect_block "bash -c interpreter variable code denied" 'bash -c '\''python3 -c $CODE'\'''
dash_heredoc='dash <<'\''EOF'\''
git reset --hard
EOF'
expect_block "dash heredoc destructive body deny" "$dash_heredoc"
ksh_heredoc='ksh <<'\''EOF'\''
git clean -fd
EOF'
expect_block "ksh heredoc destructive body deny" "$ksh_heredoc"
expect_block "dash -c destructive body deny" "dash -c 'git reset --hard'"

# [2026-08-02][test] xargs wrapper 経由の破壊的 Git 検査（jtt-cms PR #1542 codex-review Critical）。
# 背景:
#   - ユーザー依頼意図: xargs 経由の破壊的 Git が引数位置に見えて素通りしていた迂回を deny 固定し、
#     非 git 用途の xargs（rm 等）や安全 subcommand を巻き込まないことを対で固定する。
#   - 守るべき業務ルール: 任意引数 option（bare -l 等）は静的境界不能として fail-closed。
#   - 他案不採用理由: deny 側のみのテストは、whitelist 縮小で日常 xargs が全滅しても気づけない。
expect_block "xargs -n1 destructive reset deny" "printf 'HEAD\n' | xargs -n1 git reset --hard"
expect_block "xargs -I replace destructive clean deny" "xargs -I{} git clean -fd"
expect_block "xargs bare optional-arg option fail closed" "xargs -l git reset --hard"
expect_allow "xargs non-git command stays allowed" "ls | xargs -n1 rm -f"
expect_allow "xargs safe git subcommand stays allowed" "printf 'x\n' | xargs git log --oneline"

TOTAL=$((PASS + FAIL))
printf '\n=== block-destructive-git.test.sh: %d/%d PASS ===\n' "$PASS" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
