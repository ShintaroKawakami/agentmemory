#!/usr/bin/env bash
set -euo pipefail

# [2026-04-10][test]
# 背景:
#   - 依頼意図: block-main-commit hook の docs-only 例外が再び main 直 push の穴にならないよう、
#     commit / push の軽量変更例外を回帰テストで固定する。
#   - 守るべき業務ルール: main 直コミット/プッシュの例外は Markdown 系ドキュメントと
#     sync-state.json など明示 allowlist だけ。コード変更や HEAD:main は拒否する。
#   - 他案不採用理由: 手動確認だけに戻す案は、同じ制御フロー退行を次回レビューまで見逃すため不採用。
#
# [2026-06-19][test]
# 背景:
#   - PR422 / 配布先レビューで、先頭 `cd` を含む複数行コマンドや redirect 付き push の
#     作業ディレクトリ解決が誤 deny される一方、main 明示 push は拒否し続ける必要があると分かった。
#   - 守るべき業務ルール: feature worktree への安全な push は止めず、main 直 push / HEAD:main /
#     解決不能な `git -C` 経由 push は止める。
#   - 他案不採用理由: 実装コメントだけで済ませる案は、sed 抽出の微妙な退行を次の配布まで見逃すため不採用。

SCRIPT="$(cd "$(dirname "$0")" && pwd)/block-main-commit.sh"
PASS=0
FAIL=0

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# [2026-10-13][test] issue #3920: テストプロセス側の GIT_CONFIG_GLOBAL pin は
# 本テストの sandbox 用の人工物であり、検査対象の hook には見せない。
# hook 内の `git config --global` 読み取りは差し替え済み HOME 経由で同一の
# .gitconfig を見るため挙動は変わらないが、export した GIT_CONFIG_GLOBAL を
# hook へ継承させると upstream-write-guard が「Git target environment
# overrides」として fail-close し、許可側のシナリオを誤判定する。
strip_test_git_config_env() {
  env -u GIT_CONFIG_GLOBAL "$@"
}

run_hook() {
  local cwd="$1"
  local command="$2"
  printf '{"tool_name":"Bash","tool_input":{"cwd":%s,"command":%s}}\n' "$(json_string "$cwd")" "$(json_string "$command")" | strip_test_git_config_env bash "$SCRIPT"
}

run_hook_raw() {
  local payload="$1"
  printf '%s' "$payload" | strip_test_git_config_env bash "$SCRIPT"
}

run_hook_script() {
  local cwd="$1"
  local command="$2"
  local script="$3"
  printf '{"tool_name":"Bash","tool_input":{"cwd":%s,"command":%s}}\n' "$(json_string "$cwd")" "$(json_string "$command")" \
    | strip_test_git_config_env bash "$script"
}

expect_allow() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local out
  out="$(run_hook "$cwd" "$command" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision'; then
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  else
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

expect_block() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local out
  out="$(run_hook "$cwd" "$command" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny'; then
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
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_block_with_script() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local script="$4"
  local out
  out="$(run_hook_script "$cwd" "$command" "$script" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

# [2026-08-13][test] issue #1746 由来。own-repo 証明不能（HEREDOC/複合cd/パイプ）は upstream 文言と混ぜない。
# [2026-08-27][test] block-main-commit-deny-message 対応で、②(パイプ付き -C push)の検査にも
#   このヘルパーを使うため、定義位置を最初の利用箇所(旧 issue #1746 セクション)から
#   共通ヘルパー群の直後へ移動した（bash は呼び出し時点で定義済みである必要があるため）。
#   中身は変更していない。旧位置には移動した旨のコメントだけ残す。
# [2026-08-27][fix] 実装監査指摘: expect_main_branch_deny は「書込先を安全に証明できない」文言の
#   非存在まで見ているのに、本ヘルパーは third-party upstream 文言の非存在しか見ておらず、
#   main の DENY_MSG（「mainブランチへの直接コミット/プッシュはブロックされました」）混入を
#   見ていなかった。対称に main 文言の非存在検査も追加する。
#   自己反証（監査役の補足）: emit_deny()（hook-library/lib/hook-io.sh:106）は JSON を印字した
#   直後に exit 0 するため、現状は 1 回の deny で 2 つの文言が同時に出ることは構造的に起きない。
#   この検査は「将来 _emit_deny_with_telemetry の後方 exit を外すリファクタが入ったとき、
#   分類不能文言のはずが main 文言も混入する」という潜在的な検査漏れへの予防であり、
#   現時点で実際に混入が起きているわけではない。
expect_unclassified_deny() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local reason_fragment="$4"
  local out
  out="$(run_hook "$cwd" "$command" 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny' \
    && printf '%s' "$out" | grep -q '書込先を安全に証明できない' \
    && printf '%s' "$out" | grep -q "$reason_fragment" \
    && ! printf '%s' "$out" | grep -q 'third-party upstream への書込みは禁止' \
    && ! printf '%s' "$out" | grep -q 'mainブランチへの直接コミット/プッシュはブロックされました'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

# [2026-10-03][fix] #3103: 書込先が解決できて session cwd と別リポジトリ/別worktreeの
#   場合は OTHER_TARGET_GIT_GUARD_MSG（別ターゲット文言）で止まることを検査する。
#   main 文言・分類不能文言の混入も否定する（文言の3分類を固定）。
expect_other_target_deny() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local out
  out="$(run_hook "$cwd" "$command" 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny' \
    && printf '%s' "$out" | grep -q '別リポジトリ/別worktree' \
    && ! printf '%s' "$out" | grep -q 'mainブランチへの直接コミット/プッシュはブロックされました' \
    && ! printf '%s' "$out" | grep -q '書込先を安全に証明できない' \
    && ! printf '%s' "$out" | grep -q 'third-party upstream への書込みは禁止'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

tmp="$(mktemp -d)"

# [2026-10-13][test] issue #3920: HOME を差し替えても、外から
# GIT_CONFIG_GLOBAL が設定されていると `git config --global` はそちらの
# 実ファイルへ書き込み、XDG_CONFIG_HOME 配下の git/config も global
# スコープの読み書き対象になりうる（実 ~/.gitconfig への到達経路）。
# 冒頭で外から来た両変数を退避・unset し、trap で元へ戻す。
# 以後 HOME を切り替えるたびに GIT_CONFIG_GLOBAL も同じ HOME 配下へ
# 張り替え、global config の書込先を常にこの sandbox 内に固定する。
_outer_git_config_global_set="${GIT_CONFIG_GLOBAL+set}"
_outer_git_config_global="${GIT_CONFIG_GLOBAL-}"
_outer_xdg_config_home_set="${XDG_CONFIG_HOME+set}"
_outer_xdg_config_home="${XDG_CONFIG_HOME-}"
unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
restore_outer_git_env() {
  rm -rf "$tmp"
  if [ "$_outer_git_config_global_set" = "set" ]; then
    GIT_CONFIG_GLOBAL="$_outer_git_config_global"
    export GIT_CONFIG_GLOBAL
  fi
  if [ "$_outer_xdg_config_home_set" = "set" ]; then
    XDG_CONFIG_HOME="$_outer_xdg_config_home"
    export XDG_CONFIG_HOME
  fi
}
trap restore_outer_git_env EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global github.user TestOwner
# ホストの Cursor / Cloud 環境変数を検査へ漏らさない。
# Linux の Cursor Cloud VM では artifacts 補助信号があるので、検査では明示的に止める。
unset CLAUDE_CODE_REMOTE CURSOR_AGENT CLOUD_AGENT_ALL_SECRET_NAMES
export AGENT_HUB_HOOK_CLOUD_FS=0

# [2026-10-13][test] issue #3920 回帰検査プローブ: 外側から GIT_CONFIG_GLOBAL を
# 向けて起動された子プロセスが、ここまでの隔離手順（退避・unset・HOME pin）と
# 1 回の global 書き込みだけを実行して即終了する。本体全件の再実行を避けつつ、
# 末尾の回帰テストが外側ファイル非変更を検証できる。
if [ "${BMC_TEST_ENV_ISOLATION_PROBE:-}" = "1" ]; then
  exit 0
fi

main_repo="$tmp/main"
feature_repo="$tmp/feature"
third_party_repo="$tmp/third-party"
mkdir -p "$main_repo" "$feature_repo" "$third_party_repo"
git -C "$main_repo" init -q
git -C "$main_repo" checkout -q -b main
git -C "$main_repo" config user.email test@example.com
git -C "$main_repo" config user.name "Test User"
git -C "$main_repo" remote add origin git@github.com:TestOwner/main.git
git -C "$main_repo" remote add upstream git@github.com:ThirdParty/main.git
echo init > "$main_repo/README.md"
git -C "$main_repo" add README.md
git -C "$main_repo" commit -q -m init
git -C "$main_repo" update-ref refs/remotes/origin/main HEAD

echo docs >> "$main_repo/README.md"
git -C "$main_repo" add README.md
expect_block \
  "main上のdocs-only commit は拒否" \
  "$main_repo" \
  "git commit -m docs"
expect_block \
  "main上の先頭空白付きcommit は拒否" \
  "$main_repo" \
  "  git commit -m docs"
expect_block \
  "main上のenv経由commit は拒否" \
  "$main_repo" \
  "env git commit -m docs"
expect_block \
  "main上のenv -u経由commit は拒否" \
  "$main_repo" \
  "env -u UNUSED_FLAG git commit -m docs"
expect_block \
  "main上のcommand経由push は拒否" \
  "$main_repo" \
  "command git push origin main"
expect_block \
  "main上の変数代入 + env経由commit は拒否" \
  "$main_repo" \
  "FOO=1 env git commit -m docs"
expect_block \
  "main上のsingle quote空白値 + commit は拒否" \
  "$main_repo" \
  "FOO='a b' git commit -m docs"
expect_block \
  "main上のdouble quote空白値 + env経由commit は拒否" \
  "$main_repo" \
  'FOO="a b" env git commit -m docs'
expect_block \
  "main上の変数代入 + command経由push は拒否" \
  "$main_repo" \
  "FOO=1 command git push origin main"
git -C "$main_repo" reset -q

echo docs >> "$main_repo/README.md"
git -C "$main_repo" add README.md
expect_block \
  "main上のdocs-only push は拒否" \
  "$main_repo" \
  "git push origin main"
git -C "$main_repo" reset -q

echo docs >> "$main_repo/README.md"
git -C "$main_repo" add README.md
expect_block \
  "main上のdocs-only commit && push は拒否" \
  "$main_repo" \
  "git commit -m docs && git push origin main"
git -C "$main_repo" reset -q

mkdir -p "$main_repo/.cursor/rules" "$main_repo/.codex"
echo rule > "$main_repo/.cursor/rules/project.mdc"
git -C "$main_repo" add .cursor/rules/project.mdc
expect_block \
  "main上の.mdc commit は拒否" \
  "$main_repo" \
  "git commit -m rules"
git -C "$main_repo" reset -q
rm -rf "$main_repo/.cursor"

echo '{}' > "$main_repo/.codex/sync-state.json"
git -C "$main_repo" add .codex/sync-state.json
expect_block \
  "main上のsync-state.json commit は拒否" \
  "$main_repo" \
  "git commit -m sync"
git -C "$main_repo" reset -q
rm -rf "$main_repo/.codex"

mkdir -p "$main_repo/.claude/hooks"
echo v > "$main_repo/.claude/hooks/.hook-library-version"
git -C "$main_repo" add .claude/hooks/.hook-library-version
expect_block \
  "main上のhook library version commit は拒否" \
  "$main_repo" \
  "git commit -m hook-version"
git -C "$main_repo" reset -q
rm -rf "$main_repo/.claude"

mkdir -p "$main_repo/src"
echo "export const value = 1;" > "$main_repo/src/app.ts"
git -C "$main_repo" add src/app.ts
expect_block \
  "main上のコード変更 commit は拒否" \
  "$main_repo" \
  "git commit -m code"
git -C "$main_repo" reset -q
rm -rf "$main_repo/src"

git -C "$feature_repo" init -q
git -C "$feature_repo" checkout -q -b feature/test
git -C "$feature_repo" config user.email test@example.com
git -C "$feature_repo" config user.name "Test User"
git -C "$feature_repo" remote add origin git@github.com:TestOwner/feature.git
git -C "$feature_repo" remote add upstream git@github.com:ThirdParty/feature.git
echo init > "$feature_repo/README.md"
git -C "$feature_repo" add README.md
git -C "$feature_repo" commit -q -m init
git -C "$feature_repo" update-ref refs/remotes/origin/main HEAD

git -C "$third_party_repo" init -q
git -C "$third_party_repo" checkout -q -b feature/test
git -C "$third_party_repo" config user.email test@example.com
git -C "$third_party_repo" config user.name "Test User"
git -C "$third_party_repo" remote add origin git@github.com:ThirdParty/feature.git
echo init > "$third_party_repo/README.md"
git -C "$third_party_repo" add README.md
git -C "$third_party_repo" commit -q -m init

owner_home="$HOME"
export HOME="$tmp/empty-home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME"
expect_allow \
  "owner未設定でも非Git操作は許可" \
  "$feature_repo" \
  "echo safe"
expect_block \
  "owner未設定時もgithub.user設定はhook経由で拒否" \
  "$feature_repo" \
  "git config --global github.user TestOwner"
export HOME="$owner_home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"

expect_block \
  "設定済みgithub.userの別owner変更は拒否" \
  "$feature_repo" \
  "git config --global github.user ThirdParty"

expect_block \
  "設定済みgithub.userの短縮-g別owner変更は拒否" \
  "$feature_repo" \
  "git config -g github.user ThirdParty"

expect_block \
  "設定済みgithub.userの解除は拒否" \
  "$feature_repo" \
  "git config --global --unset github.user"
git -C "$feature_repo" branch --set-upstream-to=origin/main feature/test >/dev/null 2>&1 || true

expect_block \
  "feature cwdからenv -C main commitは拒否" \
  "$feature_repo" \
  "env -C $main_repo git commit -m unsafe"

expect_block \
  "feature cwdからenv --chdir main pushは拒否" \
  "$feature_repo" \
  "env --chdir=$main_repo git push"

expect_block \
  "feature cwdからenv -S内のmain commitは拒否" \
  "$feature_repo" \
  "env -S 'git -C $main_repo commit -m unsafe'"

expect_block \
  "feature cwdからenv --split-string内のmain pushは拒否" \
  "$feature_repo" \
  "env --split-string='git -C $main_repo push' ignored"

# [2026-07-12][test]
# 背景: Codex が main checkout を cwd にしたまま専用 worktree へ単発 `git -C` commit する際、
#   conventional commit の scope 括弧や本文のセミコロンを shell 制御演算子と誤認して deny していた。
#   main 保護は維持しつつ、引用済みコミットメッセージ内の文字は引数データとして扱う必要がある。
#   他案不採用理由: conventional commit の括弧だけを例外化するテストでは、引用済みのセミコロンや
#   リダイレクト文字で同じ誤検知が再発するため、引用境界そのものを正負両方向で固定する。
expect_allow \
  "-C feature commit の引用済み scope 括弧を許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'fix(auth): allow feature worktree'"

expect_allow \
  "-C feature commit の引用済みセミコロンを許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'fix: first; second'"

expect_allow \
  "-C feature commit の引用済み > を許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'docs: use > output'"

# [2026-08-02][test] env / VAR= prefix 付き単発 -C feature commit の許可回帰（issue #1344）。
# 背景:
#   - ユーザー依頼意図: 旧 command_uses_env_chdir の貪欲マッチが git 側の -C を env の
#     chdir と誤認し、正当な feature commit を誤 deny していた回帰を固定する。
#   - 守るべき業務ルール: env 自身の -C/--chdir・GIT_DIR 系 assignment の保守的 deny は
#     維持する（許可回帰と deny 回帰を対で置く）。
#   - 他案不採用理由: 許可側だけのテストでは、将来 env 判定を戻した時に chdir バイパスの
#     deny が消えても検知できない。
expect_allow \
  "env prefix の -C feature commit を許可" \
  "$main_repo" \
  "env FOO=bar git -C $feature_repo commit -m docs"
expect_allow \
  "VAR= prefix の -C feature commit を許可" \
  "$main_repo" \
  "FOO=bar git -C $feature_repo commit -m docs"
expect_block \
  "env 自身の -C (chdir) は従来どおり拒否" \
  "$feature_repo" \
  "env -C $main_repo git commit -m docs"
expect_block \
  "env GIT_DIR assignment は従来どおり保守的拒否" \
  "$main_repo" \
  "env GIT_DIR=$main_repo/.git git -C $feature_repo commit -m docs"
# PR #1354 codex-review Critical: 引数付き env オプション越しの chdir バイパスを deny 固定
expect_block \
  "env -u 引数付きの env -C (chdir) main も拒否" \
  "$feature_repo" \
  "env -u FOO -C $main_repo git commit -m docs"
expect_block \
  "env --unset 引数付きの --chdir main も拒否" \
  "$feature_repo" \
  "env --unset FOO --chdir $main_repo git push origin main"
# 注: `env -i git -C <feature> commit` は single_git_c_target_dir が env オプションを
# 解決対象にしないため従来どおり保守的 deny（バイパスではなく安全側・許可回帰は置かない）。

expect_allow \
  "-C feature commit の引用済み < を許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'docs: use < input'"

expect_allow \
  "-C feature commit のdouble quote済みメッセージを許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m \"fix(auth): allow feature worktree\""

# [2026-08-02][test] #1313 / #1256
# 背景: 引用済みの commit message / PR本文に現れる `git push` や `git reset` を
#   実行コマンドと誤認すると、feature worktreeのcommitやガード修正PRを作れない。
# 守るべき業務ルール: 本文系オプションの引数はデータとして扱い、引用外の実コマンドは拒否する。
# 他案不採用理由: message 側の文字列を正規表現の例外へ追加する案は、例外列挙が際限なく増え
#   引用境界の正確な認識という根本対処を先送りするため不採用（PR #1343 codex-review 指摘の補完）。
expect_allow \
  "-C feature commit message内のmain push文字列を許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'docs; git push origin main'"

expect_allow \
  "-C feature commit message内のreset文字列を許可" \
  "$main_repo" \
  "git -C $feature_repo commit --message='docs: git reset --hard は本文'"

expect_allow \
  "single quote内のliteral command substitution文字列を許可" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'docs: literal \$(git push origin main)'"

expect_allow \
  "PR本文内のmain push文字列を許可" \
  "$main_repo" \
  "gh pr create --body 'release note; git push origin main'"

expect_allow \
  "Issue本文のreset文字列を許可" \
  "$main_repo" \
  "gh issue comment 1 --body='docs: git reset --hard は実行しない'"

expect_block \
  "本文の外にあるmain pushは引き続き拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'docs' ; git push origin main"

expect_block \
  "-C feature commit 後の非引用セミコロン複合コマンドは拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m fix; git commit -m unsafe"

expect_block \
  "-C feature commit の command substitution は拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m \"fix: \$(git status)\""

expect_block \
  "-C feature commit の backtick command substitution は拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m \"fix: \`git status\`\""

scanner_fixture="$tmp/scanner-fixture"
mkdir -p "$scanner_fixture/scripts" "$scanner_fixture/lib"
cp "$SCRIPT" "$scanner_fixture/scripts/block-main-commit.sh"
cp "$(dirname "$SCRIPT")/../lib/hook-io.sh" "$scanner_fixture/lib/hook-io.sh"
sed -i.bak 's/COMMAND_TEXT="$1" python3/COMMAND_TEXT="$1" missing-python3/' "$scanner_fixture/scripts/block-main-commit.sh"
rm -f "$scanner_fixture/scripts/block-main-commit.sh.bak"
expect_block_with_script \
  "quote scanner の起動不能は fail-closed" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'fix(auth): allow feature worktree'" \
  "$scanner_fixture/scripts/block-main-commit.sh"

crash_scanner="$scanner_fixture/scanner-exit-2"
printf '#!/usr/bin/env bash\nexit 2\n' > "$crash_scanner"
chmod +x "$crash_scanner"
sed -i.bak "s|COMMAND_TEXT=\"\$1\" missing-python3|COMMAND_TEXT=\"\$1\" $crash_scanner|" "$scanner_fixture/scripts/block-main-commit.sh"
rm -f "$scanner_fixture/scripts/block-main-commit.sh.bak"
expect_block_with_script \
  "quote scanner の異常終了(rc=2)は fail-closed" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'fix(auth): allow feature worktree'" \
  "$scanner_fixture/scripts/block-main-commit.sh"

expect_block \
  "-C feature commit の閉じていない single quote は拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m 'broken"

expect_block \
  "-C feature commit の閉じていない double quote は拒否" \
  "$main_repo" \
  "git -C $feature_repo commit -m \"broken"

expect_block \
  "先頭 cd + 改行後の未知コマンドは宛先を証明できないため拒否" \
  "$main_repo" \
  "cd $feature_repo && git push --force-with-lease
commit body with spaces"

expect_allow \
  "先頭 cd + redirect 付き feature push を許可" \
  "$main_repo" \
  "cd $feature_repo && git push --force-with-lease 2>&1"

expect_block \
  "先頭 cd でも main 明示 push は拒否" \
  "$main_repo" \
  "cd $feature_repo && git push origin main 2>&1"

expect_block \
  "HEAD:main は拒否" \
  "$main_repo" \
  "cd $feature_repo && git push origin HEAD:main"

# [2026-07-18][test]
# 全CLI配布物へ同じ回帰テストを展開する際、Claude/Cursor/Geminiのhook-ioはKimi固有payloadを
# 入力契約に持たない。別CLIのI/O契約まで要求せず、Kimi/Codex/正本でだけKimi payloadを検証する。
case "$SCRIPT" in
  */.claude/*|*/.cursor/*|*/.gemini/*)
    printf '[SKIP] Kimi Shell toolInput の HEAD:main は対象外ランタイム\n'
    ;;
  *)
    expect_block_raw \
      "Kimi Shell toolInput の HEAD:main は拒否" \
      "{\"toolName\":\"Shell\",\"toolInput\":{\"cwd\":$(json_string "$main_repo"),\"command\":$(json_string "cd $feature_repo && git push origin HEAD:main")}}"
    ;;
esac

git -C "$feature_repo" config push.default matching
expect_block \
  "push.default=matching の bare push は拒否" \
  "$main_repo" \
  "cd $feature_repo && git push"

git -C "$feature_repo" config push.default upstream
expect_block \
  "upstream が main の bare push は拒否" \
  "$main_repo" \
  "cd $feature_repo && git push --force-with-lease"

# [2026-10-17][test] クラウド判定（Claude / Cursor Cloud 信号）があっても
# push.default=upstream かつ @{upstream}=origin/main の bare push は拒否のまま。
export CLAUDE_CODE_REMOTE=true
export CURSOR_AGENT=1
export CLOUD_AGENT_ALL_SECRET_NAMES=
expect_block \
  "クラウド判定中でも upstream が main の bare push は拒否" \
  "$main_repo" \
  "cd $feature_repo && git push --force-with-lease"
unset CLAUDE_CODE_REMOTE CURSOR_AGENT CLOUD_AGENT_ALL_SECRET_NAMES

git -C "$feature_repo" config push.default current
expect_block \
  "複数 cd は解決不能として拒否" \
  "$main_repo" \
  "cd $feature_repo && cd .. && git push"

# [2026-07-11][test] jtt-apps 本番タグ push 事例（v2.4.37）
# 背景: single_git_c_target_dir()（PR #820）は単発 `git -C <dir> commit/push` のうち
#   実効ブランチが非main・かつ安全な push だけを許可する設計に変わっているが、本テストが
#   旧仕様（-C は常に解決不能=拒否）のまま残っていて、この設計変更を検出できずにいた。
#   合わせて、コマンドに `2>&1` 等のリダイレクトが含まれるだけで誤って解決不能扱いになる
#   問題（DEPLOY_CHECKLIST.md のタグ push 手順が worktree 経由でも実行できなくなる不具合）
#   も本ファイル修正で解消したため、そのケースも固定する。
expect_allow \
  "-C 経由でも非mainブランチへの安全な push は許可" \
  "$main_repo" \
  "git -C $feature_repo push origin feature/test"

expect_allow \
  "-C 経由 + redirect(2>&1) 付きの安全な push も許可" \
  "$main_repo" \
  "git -C $feature_repo push origin feature/test 2>&1"

expect_block \
  "-C 経由でも main 宛て push は拒否" \
  "$main_repo" \
  "git -C $feature_repo push origin main"

expect_block \
  "複数-Cは解決不能として拒否" \
  "$main_repo" \
  "git -C $tmp -C feature commit -m unsafe"

# [2026-08-02][test] Wave B / #1258 / #1090 H1
# 背景:
#   - ユーザー依頼意図: main cwd から別リポ feature worktree へ commit/push する経路が
#     「無い」ように見える摩擦を、正本の実挙動（既に allow）で固定したい。
#   - 守るべき業務ルール: 先頭単一 `cd <feature> && git commit/push` と単発
#     `git -C <feature> commit/push` は non-main なら許可。複合への -C 対称化はしない。
#   - 他案不採用理由: helper 再発明や -C の複合対称化は後続 main 書き込みの誤許可を招く。
# 注: 本 fixture の main_repo と feature_repo は別 git init（クロスリポ相当）。
expect_allow \
  "クロスリポ相当: 先頭 cd + feature commit を許可" \
  "$main_repo" \
  "cd $feature_repo && git commit --allow-empty -m 'chore: cross-repo feature commit'"

expect_allow \
  "クロスリポ相当: 単発 -C feature commit を許可" \
  "$main_repo" \
  "git -C $feature_repo commit --allow-empty -m 'chore: cross-repo -C commit'"

expect_block \
  "-C feature の後続 commit へ対称化しない（複合は拒否）" \
  "$main_repo" \
  "git -C $feature_repo status && git commit --allow-empty -m unsafe"

# [2026-08-27][fix] issue: block-main-commit-deny-message
# 背景:
#   - 依頼意図: `git -C <feature-worktree> push -u origin feature/x 2>&1 | tail -6` が
#     main 文言(DENY_MSG=「mainブランチへの直接コミット/プッシュはブロックされました」)で
#     拒否され、既に feature branch で作業している AI が「main を直接触った」と誤解して
#     人間へブランチ作成を依頼する誤誘導が実際に発生した。
#     真の拒否理由は main 保護ではなく、パイプ(`| tail`)付き複合コマンドでは
#     `-C` の書込先(worktree)を安全に証明できないため（single_git_c_target_dir の
#     has_unquoted_shell_control が `|` を shell 制御とみなし解決不能=空を返す）。
#   - 守るべき業務ルール: 止める条件・許可条件は 1 文字も変えない（新たに通るコマンドを作らない）。
#     変えるのは「止めた理由の説明文」だけ。
#   - 他案不採用理由: パイプ検知自体を緩める案は shell control 検知全般を弱め fail-open を招くため不採用。
#     既存 expect_block（deny か否かのみ判定）で押さえる案は、文言が入れ替わっても緑になり
#     今回の誤誘導を再発検知できないため不採用。
# 対応: DENY_MSG(main文言)と UNCLASSIFIED_GIT_GUARD_MSG(分類不能文言)を区別して検査する
#   expect_main_branch_deny を追加し、①〜⑥の実測挙動を固定する。
#   ②は本体修正前の現状(DENY_MSG)を固定し、Step 3 で expect_unclassified_deny へ切り替える。
expect_main_branch_deny() {
  local name="$1"
  local cwd="$2"
  local command="$3"
  local out
  out="$(run_hook "$cwd" "$command" 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny' \
    && printf '%s' "$out" | grep -q 'mainブランチへの直接コミット/プッシュはブロックされました' \
    && ! printf '%s' "$out" | grep -q '書込先を安全に証明できない' \
    && ! printf '%s' "$out" | grep -q 'third-party upstream への書込みは禁止'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_allow \
  "① -C 経由 push（パイプなし）は許可" \
  "$main_repo" \
  "git -C $feature_repo push -u origin feature/x"

expect_unclassified_deny \
  "② -C 経由 push をパイプ(| tail)に繋ぐと分類不能メッセージで拒否（main 文言と誤誘導しない）" \
  "$main_repo" \
  "git -C $feature_repo push -u origin feature/x 2>&1 | tail -6" \
  "piped or compound command"

expect_allow \
  "③ -C 経由 push + リダイレクトのみ(2>&1)は許可" \
  "$main_repo" \
  "git -C $feature_repo push -u origin feature/x 2>&1"

# [2026-08-27][fix] 実装監査指摘: ④の名前が実体とずれていた（push先は main ではなく feature/x）。
# このケースが検証しているのは「refspec に `:` を含むため has_unsafe_push が unsafe 判定し、
# 書込先(-C先)自体は解決できている（＝分類不能ではない）ので main 文言のまま止まる」こと。
# アサーション・コマンドは変更せず、名前だけ実体に合わせて修正した。
# [2026-10-03][fix] #3103: 書込先が別リポジトリと解決できた unsafe push は、
#   作業場所のずれが分かる別ターゲット文言(OTHER_TARGET_GIT_GUARD_MSG)へ切り替わった。
expect_other_target_deny \
  "④ -C 経由 push の : 付き refspec は unsafe 判定で別ターゲット文言で拒否" \
  "$main_repo" \
  "git -C $feature_repo push origin HEAD:refs/heads/feature/x"

# [2026-10-03][test] #3103: -C 先が session cwd と同一リポジトリなら、別ターゲット文言ではなく
#   従来どおり main 文言で止まることを固定する（cwd ずれ無し＝文言切替条件を満たさない）。
expect_main_branch_deny \
  "④同一repo -C 経由 push の : 付き refspec は main 文言のまま拒否" \
  "$main_repo" \
  "git -C $main_repo push origin HEAD:refs/heads/feature/x"

# [2026-08-27][test] ④に対応する「本当に main 宛ての colon refspec」ケースを追加。
# 背景: 上の④は push 先が feature/x（main ではない）で、colon 付き refspec というだけで
#   unsafe 判定される経路を検証していた。「main 宛て refspec」を実際に main 名で確認する
#   ケースがまだ無かった（"-C 経由でも main 宛て push は拒否" は colon なしの ref=main の別経路）。
#   本ケースは colon 付きで dst が refs/heads/main のケースを固定する。
expect_main_branch_deny \
  "④' -C 経由 push の main 宛て(colon refspec)は main 文言のまま拒否" \
  "$main_repo" \
  "git -C $feature_repo push origin HEAD:refs/heads/main"

msg_file="$tmp/pipe-fix-msg.txt"
echo "chore: message file commit" > "$msg_file"
expect_allow \
  "⑤ -C 経由 commit -F <file> は許可" \
  "$main_repo" \
  "git -C $feature_repo commit -F $msg_file"

echo pipe-fix >> "$main_repo/README.md"
git -C "$main_repo" add README.md
expect_main_branch_deny \
  "⑥ cwd(main) への直接 commit は main 文言のまま拒否" \
  "$main_repo" \
  "git commit -m docs"
git -C "$main_repo" reset -q

expect_main_branch_deny \
  "⑥ cwd(main) からの直接 push は main 文言のまま拒否" \
  "$main_repo" \
  "git push origin main"

# [2026-09-05][test] Claude Code on the web（クラウド）で `git config --global
# github.user` が存在しない状態でも fork の feature branch へ通常 push できることを
# 固定する回帰テスト。third-party push 拒否と main 直 push 拒否は緩めない。
# 背景:
#   - 依頼意図: jtt-system spike/cloud-hub-probe の実測（2026-09-05・
#     docs/spike-cloud-hub-probe.md「push経路の追加実測」）で、クラウドコンテナに
#     github.user が無く、同一セッション内で設定変更も拒否されるため、fork内の
#     feature branch push まで恒久的に fail-close していた（AIはGitHub API
#     経由のfallbackで push した）。
#   - 守るべき業務ルール: フォールバックは Claude Code on the web
#     （CLAUDE_CODE_REMOTE=true）と Cursor Cloud（CURSOR_AGENT +
#     CLOUD_AGENT_ALL_SECRET_NAMES）だけ。third-party owner・main直pushの拒否は緩めない。
cloud_test_home="$HOME"
export HOME="$tmp/empty-home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export CLAUDE_CODE_REMOTE=true
expect_allow \
  "クラウドでgithub.user未設定でもorigin ownerへのfeature pushは許可" \
  "$feature_repo" \
  "git push origin feature/test"
expect_block \
  "クラウドでgithub.user未設定でもthird-party upstream pushは拒否" \
  "$feature_repo" \
  "git push upstream feature/test"
expect_main_branch_deny \
  "クラウドでgithub.user未設定でもmain直pushは main 文言のまま拒否" \
  "$main_repo" \
  "git push origin main"
unset CLAUDE_CODE_REMOTE
export CURSOR_AGENT=1
export CLOUD_AGENT_ALL_SECRET_NAMES=
expect_allow \
  "Cursor Cloudでgithub.user未設定でもorigin ownerへのfeature pushは許可" \
  "$feature_repo" \
  "git push origin feature/test"
unset CURSOR_AGENT
unset CLOUD_AGENT_ALL_SECRET_NAMES
expect_block \
  "CLAUDE_CODE_REMOTE未設定・github.user未設定ならfeature pushも従来どおり拒否" \
  "$feature_repo" \
  "git push origin feature/test"
export HOME="$cloud_test_home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"

expect_block \
  "先頭 cd でも対象が main なら commit 拒否" \
  "$main_repo" \
  "cd $main_repo && git commit --allow-empty -m 'docs: still main'"

expect_allow \
  "読み取り検索内の git push 文字列は許可" \
  "$main_repo" \
  'rg -n "git push|post-merge-gate|workflow" hook-library scripts'

# [2026-08-13][test] issue #1672: 同一 -C 複合 add+commit と merge cleanup の push --delete
# 背景:
#   - ユーザー依頼意図: feature worktree 内 `git -C … add && git -C … commit` と
#     merge 済み枝の `git push origin --delete …` が main 直 push と誤 deny されていた。
#   - 守るべき業務ルール: リモート main 削除は deny のまま。commit 同梱の delete push は commit 側で deny。
#   - 他案不採用理由: push 全面許可の回帰テストは main 保護を弱めるため不採用。
expect_allow \
  "同一 -C 複合 add+commit を許可" \
  "$main_repo" \
  "git -C $feature_repo add README.md && git -C $feature_repo commit -m docs"

expect_allow \
  "push --delete 単独を許可" \
  "$main_repo" \
  "git push origin --delete feature/old-branch"

expect_allow \
  "push --delete 複数枝を許可" \
  "$main_repo" \
  "git push origin --delete branch1 branch2 branch3"

# [2026-08-27][test] issue: push-delete-main-order
# 背景:
#   - ユーザー依頼意図: `--delete <remote> <branch>` の語順（--delete の直後が remote 名）でも
#     merge cleanup（feature 枝削除）は従来どおり許可され続けることを固定する。
#   - 守るべき業務ルール: 語順違いで許可が狭まってはいけない（本来の用途を壊さない）。
#   - 他案不採用理由: なし（既存「push --delete 単独を許可」の語順違いバリアントとして必要）。
expect_allow \
  "push --delete 語順違い(--delete <remote> <branch>)でも許可" \
  "$main_repo" \
  "git push --delete origin feature/old-branch"

# [2026-08-13][test]
# 背景:
#   - ユーザー依頼意図: 全PJでthird-party upstream writeを禁止し、fork内writeだけを許可する。
#   - 守るべき業務ルール: remote名・URL・CLI短縮形・環境変数・複合commandに関係なく、
#     global github.user と一致するownerだけを書込み先として許可する。
#   - 他案不採用理由: 基本形だけのsmoke testでは有効なGit/gh省略構文による回避を検出できず、
#     文書だけの禁止では誤操作を実行時に止められないため不採用。
expect_allow \
  "fork owner のfeature pushは許可" \
  "$feature_repo" \
  "git push origin feature/test"

expect_block \
  "third-party upstream pushは拒否" \
  "$feature_repo" \
  "git push upstream feature/test"

expect_block \
  "third-party URL直指定pushは拒否" \
  "$feature_repo" \
  "git push git@github.com:ThirdParty/feature.git feature/test"

expect_block \
  "git -c pushurl上書きによるthird-party pushは拒否" \
  "$feature_repo" \
  "git -c remote.origin.pushurl=git@github.com:ThirdParty/feature.git push origin feature/test"

expect_block \
  "git短縮-c pushurl上書きによるthird-party pushは拒否" \
  "$feature_repo" \
  "git -cremote.origin.pushurl=git@github.com:ThirdParty/feature.git push origin feature/test"

expect_block \
  "git短縮-C pushはfail-close" \
  "$feature_repo" \
  "git -C$feature_repo push origin feature/test"

expect_block \
  "GIT_DIR上書きのthird-party pushは拒否" \
  "$feature_repo" \
  "GIT_DIR=$third_party_repo/.git git push origin feature/test"

expect_block \
  "GIT_CONFIG環境上書きpushは拒否" \
  "$feature_repo" \
  "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=git@github.com:ThirdParty/feature.git git push origin feature/test"

# [2026-10-03][test] issue #3239: 無害 GIT_CONFIG_* 環境（Claude Code が常駐させる
# credential.interactive / credential.guiPrompt）で、feature worktree からの正当な
# origin 宛 push が「cannot prove Git push target ... GIT_CONFIG_* environment」で
# 止まらないこと。緩和は厳格な単純形だけなので、cd 前置き（literal + `&&`・1回）と
# remote 省略は通し、宛先すり替え経路・複合形・third-party cd 先は従来どおり拒否する。
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=credential.interactive
GIT_CONFIG_VALUE_0=never
GIT_CONFIG_KEY_1=credential.guiPrompt
GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
expect_allow \
  "無害GIT_CONFIG環境のfeature pushは許可" \
  "$feature_repo" \
  "git push origin feature/test"
expect_allow \
  "無害GIT_CONFIG環境のcd前置きpushは許可" \
  "$main_repo" \
  "cd $feature_repo && git push origin feature/test"
expect_allow \
  "無害GIT_CONFIG環境のremote省略pushは許可" \
  "$feature_repo" \
  "git push"
expect_block \
  "無害GIT_CONFIG環境でもcd先third-party pushは拒否" \
  "$feature_repo" \
  "cd $third_party_repo && git push origin feature/test"
expect_block \
  "無害GIT_CONFIG環境でもcd前置きのpush option付きは拒否" \
  "$feature_repo" \
  "cd $feature_repo && git push -o ci.skip origin feature/test"
expect_block \
  "無害GIT_CONFIG環境でもcdの;区切りpushは拒否" \
  "$main_repo" \
  "cd $feature_repo; git push origin feature/test"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1

expect_block \
  "git global option経由のthird-party pushは拒否" \
  "$feature_repo" \
  "git --no-pager push upstream feature/test"

expect_block \
  "絶対path git経由のthird-party pushは拒否" \
  "$feature_repo" \
  "/usr/bin/git push upstream feature/test"

expect_block \
  "cd先third-party originへのpushは拒否" \
  "$feature_repo" \
  "cd $third_party_repo && git push origin feature/test"

expect_block \
  "remote変更後のthird-party pushは拒否" \
  "$feature_repo" \
  "git remote set-url origin git@github.com:ThirdParty/feature.git && git push origin feature/test"

expect_block \
  "絶対path remote変更後のthird-party pushは拒否" \
  "$feature_repo" \
  "/usr/bin/git remote set-url origin git@github.com:ThirdParty/feature.git && /usr/bin/git push origin feature/test"

expect_block \
  "git -C remote変更後のthird-party pushは拒否" \
  "$feature_repo" \
  "git -C $feature_repo remote set-url origin git@github.com:ThirdParty/feature.git && git push origin feature/test"

git -C "$feature_repo" remote set-url --add --push origin git@github.com:TestOwner/feature.git
git -C "$feature_repo" remote set-url --add --push origin git@github.com:ThirdParty/feature.git
expect_block \
  "複数pushurlにthird-partyを含むpushは拒否" \
  "$feature_repo" \
  "git push origin feature/test"
git -C "$feature_repo" config --unset-all remote.origin.pushurl

expect_block \
  "pushurl変更後のthird-party pushは拒否" \
  "$feature_repo" \
  "git config remote.origin.pushurl git@github.com:ThirdParty/feature.git && git push origin feature/test"

expect_block \
  "bash -c内のthird-party pushは拒否" \
  "$feature_repo" \
  "bash -c 'git push upstream feature/test'"

expect_block \
  "command substitution内のthird-party pushは拒否" \
  "$feature_repo" \
  "echo \$(git push upstream feature/test)"

expect_block \
  "backtick内のthird-party pushは拒否" \
  "$feature_repo" \
  'echo `git push upstream feature/test`'

expect_block \
  "Git pushInsteadOf設定変更は拒否" \
  "$feature_repo" \
  "git config --global url.git@github.com:ThirdParty/.pushInsteadOf https://github.com/TestOwner/"

git -C "$feature_repo" config alias.publish '!git push upstream'
expect_block \
  "Git alias経由のthird-party pushは拒否" \
  "$feature_repo" \
  "git publish"

expect_block \
  "inline Git alias経由のthird-party pushは拒否" \
  "$feature_repo" \
  "git -calias.publish='!git push upstream' publish"

expect_block \
  "未知Git subcommandはfail-close" \
  "$feature_repo" \
  "git unknown-writer"

expect_allow \
  "fork内PR作成は許可" \
  "$feature_repo" \
  "gh pr create --repo TestOwner/feature --base main --head feature/test"

expect_block \
  "third-party upstream PR作成は拒否" \
  "$feature_repo" \
  "gh pr create --repo ThirdParty/feature --base main --head TestOwner:feature/test"

expect_block \
  "gh global --repo経由のthird-party PR作成は拒否" \
  "$feature_repo" \
  "gh --repo ThirdParty/feature pr create --base main --head TestOwner:feature/test"

expect_block \
  "重複--repo指定のthird-party PR作成は拒否" \
  "$feature_repo" \
  "gh pr create --repo TestOwner/feature --repo ThirdParty/feature --base main --head TestOwner:feature/test"

expect_block \
  "短縮-R直結のthird-party PR作成は拒否" \
  "$feature_repo" \
  "gh pr create -RThirdParty/feature --base main --head TestOwner:feature/test"

expect_block \
  "短縮-R等号のthird-party PR作成は拒否" \
  "$feature_repo" \
  "gh pr create -R=ThirdParty/feature --base main --head TestOwner:feature/test"

expect_block \
  "shell変数repo指定のthird-party PR作成は拒否" \
  "$feature_repo" \
  "TARGET_REPO=ThirdParty/feature; gh pr create --repo \"\$TARGET_REPO\" --base main --head TestOwner:feature/test"

expect_block \
  "eval経由のthird-party PR作成は拒否" \
  "$feature_repo" \
  "eval 'gh pr create --repo ThirdParty/feature --base main --head TestOwner:feature/test'"

expect_block \
  "Python wrapper経由のthird-party pushは拒否" \
  "$feature_repo" \
  "python3 -c 'import subprocess; subprocess.run([\"git\",\"push\",\"upstream\",\"feature/test\"])'"

expect_block \
  "env -S wrapper経由のthird-party pushは拒否" \
  "$feature_repo" \
  "env -S 'git push upstream feature/test'"

expect_block \
  "GH_REPO経由のthird-party PR作成は拒否" \
  "$feature_repo" \
  "GH_REPO=ThirdParty/feature gh pr create --base main --head TestOwner:feature/test"

export GH_REPO=ThirdParty/feature
expect_block \
  "既存環境GH_REPO経由のthird-party PR作成は拒否" \
  "$feature_repo" \
  "gh pr create --base main --head TestOwner:feature/test"
unset GH_REPO

expect_block \
  "export GH_REPO後のthird-party PR作成は拒否" \
  "$feature_repo" \
  "export GH_REPO=ThirdParty/feature; gh pr create --base main --head TestOwner:feature/test"

expect_block \
  "sh -c内のthird-party PR作成は拒否" \
  "$feature_repo" \
  "sh -c 'gh pr create --repo ThirdParty/feature --base main --head TestOwner:feature/test'"

expect_allow \
  "GitHub owner大小文字差のfork writeは許可" \
  "$feature_repo" \
  "gh issue create --repo testowner/feature --title test --body test"

expect_block \
  "third-party PR mergeは拒否" \
  "$feature_repo" \
  "gh pr merge --repo ThirdParty/feature 123 --merge"

expect_block \
  "third-party Issue作成は拒否" \
  "$feature_repo" \
  "gh issue create --repo ThirdParty/feature --title test --body test"

expect_block \
  "third-party Release作成は拒否" \
  "$feature_repo" \
  "gh release create --repo ThirdParty/feature v1.0.0"

expect_block \
  "third-party repo位置引数の削除は拒否" \
  "$feature_repo" \
  "gh repo delete ThirdParty/feature --yes"

expect_block \
  "third-party PR URLのmergeは拒否" \
  "$feature_repo" \
  "gh pr merge https://github.com/ThirdParty/feature/pull/123 --merge"

expect_block \
  "third-party --owner指定writeは拒否" \
  "$feature_repo" \
  "gh repo create test --owner ThirdParty --private"

expect_block \
  "gh alias実行はfail-close" \
  "$feature_repo" \
  "gh publish"

expect_allow \
  "third-party PR閲覧はread-onlyとして許可" \
  "$feature_repo" \
  "gh pr view --repo ThirdParty/feature 123"

expect_allow \
  "third-party repo forkはread-only upstreamからのfork作成として許可" \
  "$feature_repo" \
  "gh repo fork ThirdParty/feature --clone=false"

expect_block \
  "third-party orgへのfork作成は拒否" \
  "$feature_repo" \
  "gh repo fork ThirdParty/feature --org ThirdParty --clone=false"

expect_block \
  "third-party REST PR作成は拒否" \
  "$feature_repo" \
  "gh api -X POST repos/ThirdParty/feature/pulls -f head=TestOwner:feature/test -f base=main"

expect_block \
  "third-party REST --method=POST query付きは拒否" \
  "$feature_repo" \
  "gh api --method=POST 'repos/ThirdParty/feature/pulls?draft=true' -f head=TestOwner:feature/test"

expect_block \
  "gh global option経由のthird-party REST writeは拒否" \
  "$feature_repo" \
  "gh --hostname github.com api --method=POST repos/ThirdParty/feature/pulls -f head=TestOwner:feature/test"

expect_block \
  "third-party REST -XPOSTは拒否" \
  "$feature_repo" \
  "gh api -XPOST repos/ThirdParty/feature/issues/1/comments -f body=test"

expect_block \
  "third-party REST PATCHは拒否" \
  "$feature_repo" \
  "gh api --method PATCH repos/ThirdParty/feature/issues/1 -f state=closed"

expect_block \
  "third-party REST DELETEは拒否" \
  "$feature_repo" \
  "gh api -X DELETE repos/ThirdParty/feature/git/refs/heads/old"

expect_block \
  "owner不明のREST writeは拒否" \
  "$feature_repo" \
  "gh api --method=PUT user/starred/ThirdParty/feature"

expect_allow \
  "fork ownerのREST writeは許可" \
  "$feature_repo" \
  "gh api --method=PATCH repos/TestOwner/feature/issues/1 -f state=closed"

# [2026-09-05][test] クラウド(CLAUDE_CODE_REMOTE=true)でgithub.user未設定でも、
# origin owner一致のREST writeは許可し、third-party REST writeは拒否のままにする回帰テスト。
# 背景・守るべき業務ルールは直前の git push 回帰テスト（本ファイル同日コメント）と同じ。
cloud_api_test_home="$HOME"
export HOME="$tmp/empty-home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export CLAUDE_CODE_REMOTE=true
expect_allow \
  "クラウドでgithub.user未設定でもfork owner一致のREST writeは許可" \
  "$feature_repo" \
  "gh api --method=PATCH repos/TestOwner/feature/issues/1 -f state=closed"
expect_block \
  "クラウドでgithub.user未設定でもthird-party REST writeは拒否" \
  "$feature_repo" \
  "gh api -X POST repos/ThirdParty/feature/pulls -f head=TestOwner:feature/test -f base=main"

# [2026-09-05][test] Codex 🟡: gh api REST write分岐だけ current_cwd を直接使い、
# segment内の `cd <dir> &&` を反映する effective_cwd を経由していなかった非対称を固定する。
expect_allow \
  "クラウドでgithub.user未設定でもcd越しのfork owner一致REST writeは許可" \
  "$main_repo" \
  "cd $feature_repo && gh api --method PATCH repos/TestOwner/feature/issues/1 -f state=closed"
expect_block \
  "クラウドでgithub.user未設定でもcd越しのthird-party REST writeは拒否" \
  "$main_repo" \
  "cd $feature_repo && gh api --method PATCH repos/ThirdParty/feature/issues/1 -f state=closed"
unset CLAUDE_CODE_REMOTE
export CURSOR_AGENT=1
export CLOUD_AGENT_ALL_SECRET_NAMES=
expect_allow \
  "Cursor Cloudでgithub.user未設定でもfork owner一致のREST writeは許可" \
  "$feature_repo" \
  "gh api --method=PATCH repos/TestOwner/feature/issues/1 -f state=closed"
unset CURSOR_AGENT
unset CLOUD_AGENT_ALL_SECRET_NAMES
expect_block \
  "CLAUDE_CODE_REMOTE未設定・github.user未設定ならREST writeも従来どおり拒否" \
  "$feature_repo" \
  "gh api --method=PATCH repos/TestOwner/feature/issues/1 -f state=closed"
export HOME="$cloud_api_test_home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"

# [2026-08-27][test] issue: push-delete-main-order
# 背景:
#   - ユーザー依頼意図: read-only 診断ドライバで実測した「remote main 削除の穴」を回帰固定する。
#     `--delete main`（直後が main）と `--delete <remote> main`（間に remote 名を挟む語順）の
#     両方を、cwd=main と `-C <feature worktree>` 経由の両方で deny させる。`-d`（短縮形）は
#     従来どおり deny のまま（許可を広げていないことの固定）。
#   - 守るべき業務ルール: リモート main 削除はどの語順・どの -C 経由でも deny。
#   - 他案不採用理由: `-d` を allowlist へ足す案・allowlist 自体を撤廃する案は
#     hook-library/scripts/block-main-commit.sh の push_is_safe_remote_branch_deletion 直上の
#     CaD コメントに記載（不採用理由の重複記載を避けるため、ここでは要点のみ）。
expect_main_branch_deny \
  "push --delete main は拒否（--delete の直後が main）" \
  "$main_repo" \
  "git push origin --delete main"

expect_main_branch_deny \
  "push --delete 語順違い(--delete <remote> main)は拒否 ← 今回の本命" \
  "$main_repo" \
  "git push --delete origin main"

expect_main_branch_deny \
  "-C <feature WT> 経由 push origin --delete main は拒否" \
  "$main_repo" \
  "git -C $feature_repo push origin --delete main"

expect_main_branch_deny \
  "-C <feature WT> 経由 push --delete origin main は拒否 ← 今回の本命" \
  "$main_repo" \
  "git -C $feature_repo push --delete origin main"

expect_main_branch_deny \
  "-C <feature WT> 経由 push -d origin main は拒否（-d の挙動は変えていない固定）" \
  "$main_repo" \
  "git -C $feature_repo push -d origin main"

expect_block \
  "push --delete と commit 同梱は拒否" \
  "$main_repo" \
  "git push origin --delete feature/old && git commit -m docs"

# [2026-08-13][test] issue #1733: git cherry と複合 read-only closeout 監査を誤停止しない
# 背景:
#   - ユーザー依頼意図: status/diff/log/cherry だけの複合 read-only 監査を通し、
#     未分類サブコマンドの文言を third-party upstream 書込みと混同させない。
#   - 守るべき業務ルール: cherry 単体と read-only 複合は許可。同じ複合に commit/push があれば
#     従来どおり fail-closed。未知サブコマンドは分類不能メッセージで deny。
#   - 他案不採用理由: cherry を全面許可せず cherry-pick だけ既知のままにする案は、
#     closeout 監査の複合コマンドを毎回分割させるため不採用。
expect_allow \
  "git cherry 単体は許可" \
  "$feature_repo" \
  "git cherry origin/main feature/test"

expect_allow \
  "status/diff/log/cherry の複合 read-only は許可" \
  "$feature_repo" \
  "git status --short --branch && git diff --stat && git log --oneline && git cherry origin/main feature/test"

expect_block \
  "read-only 複合に third-party push を混ぜると拒否" \
  "$feature_repo" \
  "git status --short && git diff --stat && git log --oneline && git cherry origin/main feature/test && git push upstream feature/test"

expect_block \
  "read-only 複合に main commit を混ぜると拒否" \
  "$main_repo" \
  "git status --short && git cherry origin/main feature/test && git commit --allow-empty -m unsafe"

unclassified_out="$(run_hook "$feature_repo" "git not-a-real-subcommand" 2>&1 || true)"
if printf '%s' "$unclassified_out" | grep -q 'permissionDecision.*deny' \
  && printf '%s' "$unclassified_out" | grep -q '書込先を安全に証明できない' \
  && ! printf '%s' "$unclassified_out" | grep -q 'third-party upstream への書込みは禁止'; then
  printf '[PASS] %s\n' "未知サブコマンドは分類不能メッセージで拒否（upstream文言と混同しない）"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s: %s\n' "未知サブコマンドは分類不能メッセージで拒否（upstream文言と混同しない）" "$unclassified_out"
  FAIL=$((FAIL + 1))
fi

# [2026-08-13][test] issue #1746: own-repo 証明不能（HEREDOC/複合cd/パイプ）は upstream 文言と混ぜない
# 背景:
#   - ユーザー依頼意図: shell substitution / opaque payload / piped cd の deny が fork 誘導しないこと。
#   - 守るべき業務ルール: deny 自体は維持。本物の third-party write は従来の upstream 文言のまま。
#   - 他案不採用理由: HEREDOC commit の静的許可は fail-open リスクがあるため今回やらない。
# 注: expect_unclassified_deny 関数の定義は 2026-08-27 に共通ヘルパー群（run_hook 等の直後）へ移動済み。
#   ②(-C push + パイプ)の検査でも同ヘルパーを使うため、bash の「呼び出し前に定義済み」制約に合わせた。
# [2026-10-10][test] issue #1361 事象2: upstream-write-guard の shell substitution
#   検査が「置換の内側テキスト」だけを見る判定に変わったため、置換の内側が
#   `cat <<'EOF'` だけだと証明できる commit は許可側へ移動した。
#   置換の内側に git が残る形（次の対テスト）は従来どおり拒否する。
expect_allow \
  "置換の内側が cat heredoc だけの commit は許可" \
  "$feature_repo" \
  'git commit -m "$(cat <<'\''EOF'\''
docs only
EOF
)"'

expect_unclassified_deny \
  "置換の内側に git push が残る commit は従来どおり拒否" \
  "$feature_repo" \
  'git commit -m "$(git push origin main)"' \
  "through shell substitution"

expect_unclassified_deny \
  "opaque python payload の write は分類不能メッセージで拒否" \
  "$feature_repo" \
  'python3 -c "import os; os.system(\"git push origin feature/test\")"' \
  "through opaque"

# [2026-08-27][test] issue: hyphen-token-word-boundary
# 背景:
#   - ユーザー依頼意図: hook-library/lib/upstream-write-guard.py の
#     opaque_payload_mentions_repository_write() が `\b` 単語境界で判定していたため、
#     ハイフン区切りのブランチ名・ディレクトリ名（ai-worker-git-push-text-pattern 等）の
#     内部にある git / push を独立コマンドトークンと誤判定し、git を一切含まない
#     `cd <dir> && python3 <script>` が「書込先を証明できない」で拒否されていた。
#     トークン一致化した修正を回帰固定する。
#   - 守るべき業務ルール: ハイフン語内部の git / push は誤検知しない一方、実際に git 書き込みへ
#     言及する不透明ペイロードと github.com URL は従来どおり fail-closed で拒否する
#     （許可回帰と deny 回帰を対で置く）。
#   - 他案不採用理由: 許可側だけのテストでは、将来トークン判定を緩めたときに
#     実書き込みペイロードの deny が消えても検知できないため不採用。
hyphen_repo="$tmp/ai-worker-git-push-text-pattern"
mkdir -p "$hyphen_repo"
expect_allow \
  "ハイフン語ディレクトリへの cd + python3 実行は許可" \
  "$feature_repo" \
  "cd $hyphen_repo && python3 /abs/script.py"

expect_allow \
  "ファイル名にハイフンで git-push を含む python3 実行は許可" \
  "$feature_repo" \
  "python3 /abs/path/to/my-git-push-helper.py"

expect_allow \
  "ハイフン語の refspec 風パスへの cd + python3 実行は許可" \
  "$feature_repo" \
  "cd $tmp/feature/git-push-fix && python3 /abs/script.py"

expect_unclassified_deny \
  "opaque python payload 引数内の git push は分類不能メッセージで拒否" \
  "$feature_repo" \
  "python3 /abs/script.py git -C /repo push origin main" \
  "through opaque"

expect_unclassified_deny \
  "opaque node payload 内の github.com URL は分類不能メッセージで拒否" \
  "$feature_repo" \
  "node -e \"fetch('https://github.com/ThirdParty/feature')\"" \
  "through opaque"

expect_unclassified_deny \
  "piped cd 付き push は分類不能メッセージで拒否" \
  "$feature_repo" \
  "cd /tmp | git push origin feature/test" \
  "across conditional or piped cd"

real_upstream_out="$(run_hook "$feature_repo" "git push upstream feature/test" 2>&1 || true)"
if printf '%s' "$real_upstream_out" | grep -q 'permissionDecision.*deny' \
  && printf '%s' "$real_upstream_out" | grep -q 'third-party upstream への書込みは禁止' \
  && ! printf '%s' "$real_upstream_out" | grep -q '書込先を安全に証明できない'; then
  printf '[PASS] %s\n' "本物の third-party push は upstream 文言のまま"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s: %s\n' "本物の third-party push は upstream 文言のまま" "$real_upstream_out"
  FAIL=$((FAIL + 1))
fi

# [2026-09-22][test] worktree add の作成先が $HOME 直下なら拒否する。
# primary checkout そのものでの通常 git と、登録ルートの隣への add は許可する。
expect_block \
  "HOME直下への worktree add は拒否" \
  "$feature_repo" \
  "git worktree add \"$HOME/jtt-system-interview-document\""
expect_block \
  "tilde の HOME 直下 worktree add は拒否" \
  "$feature_repo" \
  "git worktree add ~/jtt-system-interview-document"
expect_allow \
  "登録ルートの隣への worktree add は許可" \
  "$feature_repo" \
  "git worktree add \"$HOME/business/AGENT-HUB-slug\" -b feat/x origin/main"
expect_allow \
  "worktree list は HOME 上でも許可" \
  "$HOME" \
  "git worktree list"
expect_allow \
  "worktree remove は add ではないので許可" \
  "$feature_repo" \
  "git worktree remove \"$HOME/jtt-system-interview-document\""
expect_allow \
  "primary checkout での git status は許可" \
  "$HOME/jtt-system" \
  "git status"
expect_block \
  "cd して HOME 直下へ作る worktree add は拒否" \
  "$feature_repo" \
  "cd \"$HOME\" && git worktree add ./jtt-system-interview-document"
expect_allow \
  "primary の配下への worktree add は許可" \
  "$feature_repo" \
  "git worktree add \"$HOME/jtt-system/feature-x\" -b feat/x"
expect_allow \
  "commit メッセージ内の worktree add 言及は許可" \
  "$feature_repo" \
  "git commit -m 'note about worktree add'"

home_child_out="$(run_hook "$feature_repo" "git worktree add \"$HOME/jtt-system-interview-document\"" 2>&1 || true)"
if printf '%s' "$home_child_out" | grep -q 'direct child of $HOME' \
  && printf '%s' "$home_child_out" | grep -q '/Users/shintaro/jtt-system-interview-document' \
  && printf '%s' "$home_child_out" | grep -q 'permissionDecision":"deny'; then
  printf '[PASS] %s\n' "HOME直下拒否の理由は1行で禁止例を含む"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s: %s\n' "HOME直下拒否の理由は1行で禁止例を含む" "$home_child_out"
  FAIL=$((FAIL + 1))
fi

# [2026-10-03][test] issue #2897: 書込み系を1つも含まない複合コマンドの誤拒否を回帰固定。
# 背景:
#   - ユーザー依頼意図: `cd <repo> && cat f | head && git worktree list | grep x` が
#     「conditional or piped cd」で、`gh issue list --search "... python3 ..."` が
#     「opaque runtime payload」で誤拒否され、調査コマンドの都度分割を強いられていた。
#   - 守るべき業務ルール: deny 側（書込みを含む piped cd 複合、opaque payload 内の
#     write 言及、変数間接指定）は従来どおり fail-closed を維持する。
#   - 他案不採用理由: 許可側だけのテストでは、将来早期許可を緩めたときに deny 回帰を
#     検知できないため不採用（許可・拒否を対で置く）。
expect_allow \
  "read-only 複合（cd + cat|head + echo + git worktree list|grep）は許可" \
  "$feature_repo" \
  "cd $feature_repo && cat README.md | head -30 && echo \"===worktrees===\" && git worktree list | grep -i repo"

expect_allow \
  "gh issue list の --search 文字列内の python3 語は許可" \
  "$feature_repo" \
  'gh issue list --repo example/repo --search "block-main-commit python3 unresolved command wrapper" --state all --limit 20'

expect_allow \
  "read-only gh の後ろのスクリプト実行（ペイロードに write 言及なし）は許可" \
  "$feature_repo" \
  "gh issue list && python3 analyze.py"

expect_allow \
  "gh --version 等の書込みえない gh は許可" \
  "$feature_repo" \
  "gh --version"

expect_unclassified_deny \
  "read-only 複合に混ざった piped push は従来どおり拒否" \
  "$feature_repo" \
  "cd $feature_repo && git status | head -1 && git push origin feature/test | tail -1" \
  "across conditional or piped cd"

expect_unclassified_deny \
  "eval 経由の push は証明不能として拒否" \
  "$feature_repo" \
  'eval "git push origin feature/test"' \
  "through eval"

# [2026-10-04][test] 括弧groupもowner guardを通す。cdのsubshell scopeは
# 平坦化して推測せず拒否し、通常group/引用引数/read-onlyは許可する。
expect_block "括弧groupのthird-party pushは拒否" "$feature_repo" \
  "(git push upstream feature/test)"
expect_block "nested括弧groupのthird-party pushは拒否" "$feature_repo" \
  "( (git push upstream feature/test) )"
expect_block "括弧groupのthird-party gh API POSTは拒否" "$feature_repo" \
  "(gh api -X POST repos/ThirdParty/feature/issues -f title=test)"
expect_block "括弧pipelineのthird-party pushは拒否" "$feature_repo" \
  "true|(git push upstream feature/test)"
expect_block "括弧group内cdのthird-party pushは拒否" "$feature_repo" \
  "(cd $third_party_repo && git push origin feature/test)"
expect_block "subshell cdでgroup外originを取り違えない" "$third_party_repo" \
  "(cd $feature_repo) && git push origin feature/test"
expect_allow "括弧groupのown pushはowner検査後に許可" "$feature_repo" \
  "(git push origin feature/test)"
expect_allow "nested括弧groupのown pushは許可" "$feature_repo" \
  "( (git push origin feature/test) )"
expect_allow "括弧read-only groupは許可" "$feature_repo" \
  "(git status --short && git log --oneline)"
expect_allow "括弧内cdでもread-only groupは許可" "$feature_repo" \
  "(cd $third_party_repo && git status --short)"
expect_allow "引用引数の括弧git文字列は実行名と混同しない" "$feature_repo" \
  'printf "%s" "(git push upstream feature/test)"'
expect_allow "引数cdはgroup書込のcwd変更と混同しない" "$feature_repo" \
  "printf '%s' cd && (git push origin feature/test)"
expect_block "prefixed cdのgroup書込は既存guardで拒否" "$feature_repo" \
  "(MODE=test cd $third_party_repo && git push origin feature/test)"
expect_allow "read-only groupの引数pythonは実行名と混同しない" "$feature_repo" \
  "(cd $third_party_repo && printf '%s' python)"

# [2026-10-06][test] issue #3674: git/gh を含まない複数行・heredoc コマンドの誤拒否を回帰固定。
# 背景:
#   - 依頼意図: /tmp 編集だけを行う複数行コマンドが
#     「ambiguous repository command or shell separator」で third-party upstream 文言の
#     誤拒否になっていた実害を固定する。
#   - 守るべき業務ルール: git/gh 言及を含む解析不能コマンドは分類不能文言で拒否し、
#     本物の third-party push は upstream 文言のまま（許可・拒否を対で置く）。
#   - 他案不採用理由: 許可側だけのテストでは、言及チェックを緩めた将来の変更で
#     git 言及コマンドの fail-closed が消えても検知できないため不採用。
expect_allow \
  "heredoc + python3 改行続き（git 無し）は許可" \
  "$feature_repo" \
  "cat > /tmp/x3674.py <<'EOF'
print('hi')
EOF
python3 -c \"print(1)\""

expect_allow \
  "python3 heredoc + node 改行続き（git 無し）は許可" \
  "$feature_repo" \
  "python3 - <<'EOF'
import sys
EOF
node /tmp/x3674.mjs"

expect_allow \
  "複数行 sed + grep（git 無し・引数の \$F）は許可" \
  "$feature_repo" \
  "sed -i '' -e 's/a/b/' \$F
grep -n 'b' \$F"

# [2026-10-10][test] issue #1361: quoted heredoc 本体を空白化した結果、
#   heredoc 後の `git push upstream` は解析不能ではなく third-party upstream 宛てと
#   静的に分類できるようになった。分類不能文言ではなく upstream 文言で拒否する
#   ことを固定する（deny 自体は不変・文言の分類がより正確になった）。
upstream_after_heredoc_out="$(run_hook "$feature_repo" "cat > /tmp/x3674.py <<'EOF'
print('x')
EOF
git push upstream feature/test" 2>&1 || true)"
if printf '%s' "$upstream_after_heredoc_out" | grep -q 'permissionDecision.*deny' \
  && printf '%s' "$upstream_after_heredoc_out" | grep -q 'third-party upstream への書込みは禁止' \
  && ! printf '%s' "$upstream_after_heredoc_out" | grep -q '書込先を安全に証明できない'; then
  printf '[PASS] %s\n' "heredoc 後の third-party push は upstream 文言で拒否"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s: %s\n' "heredoc 後の third-party push は upstream 文言で拒否" "$upstream_after_heredoc_out"
  FAIL=$((FAIL + 1))
fi

# [2026-10-07][test] issue #2012: 行継続（`\`+改行）を含むコマンドの誤拒否を回帰固定。
# 背景:
#   - 依頼意図: `gh pr create --repo <fork> \` + 改行 が「ambiguous repository
#     command or shell separator」として誤拒否されていた。行継続は shell の
#     標準的な書き方なので、検査も連結後の形で行う。
#   - 守るべき業務ルール: third-party upstream 宛の書込み・同一コマンド内の宛先
#     すり替えは連結後も従来どおり拒否する。`\\`+改行（偶数個の `\` の末尾）は
#     継続ではなく改行区切りとして残るため、その後の git push を必ず検査する
#     （fail-open を作らない）。
expect_allow \
  "行継続を含む gh pr create（自分のfork宛）は許可" \
  "$feature_repo" \
  'gh pr create --repo TestOwner/feature \
    --title "test title" \
    --body-file /tmp/body.md'

expect_allow \
  "行継続を含む git push（自分のfork宛）は許可" \
  "$feature_repo" \
  'git push origin \
    feature/test'

expect_allow \
  "行継続を含む read-only gh pr view は許可" \
  "$feature_repo" \
  'gh pr \
    view 123 --repo TestOwner/feature'

expect_block \
  "行継続を含む third-party PR作成は拒否" \
  "$feature_repo" \
  'gh pr create --repo ThirdParty/feature \
    --title test \
    --body test'

expect_block \
  "行継続を挟んだ remote set-url + push の宛先すり替えは拒否" \
  "$feature_repo" \
  'git remote set-url origin https://github.com/ThirdParty/feature.git \
    && git push origin feature/test'

expect_block \
  '`\\`+改行は継続ではなく後続の third-party push を検査して拒否' \
  "$feature_repo" \
  'true\\
git push upstream feature/test'

continued_upstream_out="$(run_hook "$feature_repo" 'git push upstream \
    feature/test' 2>&1 || true)"
if printf '%s' "$continued_upstream_out" | grep -q 'permissionDecision.*deny' \
  && printf '%s' "$continued_upstream_out" | grep -q 'third-party upstream への書込みは禁止' \
  && ! printf '%s' "$continued_upstream_out" | grep -q '書込先を安全に証明できない'; then
  printf '[PASS] %s\n' "行継続を含む third-party push も upstream 文言で拒否"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s: %s\n' "行継続を含む third-party push も upstream 文言で拒否" "$continued_upstream_out"
  FAIL=$((FAIL + 1))
fi

# [2026-10-09][test] issue #2240: 書込先を解決してから判定する回帰固定。
# 背景:
#   - 依頼意図: 判定が session cwd の branch に依存していたため、Codex の workdir 指定で
#     別リポジトリの feature branch への通常確定が親の main 扱いで誤拒否され、
#     逆に session が feature のとき `git -C <main> commit` / `cd <main> && git commit` 等が
#     素通りしていた（fail-open）。「対象 repository と現在 branch を解決してから判定」を固定する。
#   - 守るべき業務ルール: 解決先が非 main で安全なら許可し、解決先が main /
#     解決不能 / 別 worktree 宛ての不安全 push は session cwd の branch に関係なく拒否する。
#   - 他案不採用理由: 許可側だけのテストでは fail-open 側（feature cwd → main 宛て書込）の
#     回帰を検知できないため不採用。許可・拒否を対で置く。
space_repo="$tmp/f with space"
non_repo_dir="$tmp/non-repo"
mkdir -p "$space_repo" "$non_repo_dir"
git -C "$space_repo" init -q
git -C "$space_repo" checkout -q -b feature/space
git -C "$space_repo" config user.email test@example.com
git -C "$space_repo" config user.name "Test User"
git -C "$space_repo" remote add origin git@github.com:TestOwner/space.git
echo init > "$space_repo/README.md"
git -C "$space_repo" add README.md
git -C "$space_repo" commit -q -m init

# 許可側: 解決できる feature 宛ては引用符・空白含みでも許可する
expect_allow \
  "main cwd + 二重引用 -C feature commit は許可" \
  "$main_repo" \
  "git -C \"$feature_repo\" commit -m x"
expect_allow \
  "main cwd + 単一引用 -C feature commit は許可" \
  "$main_repo" \
  "git -C '$feature_repo' commit -m x"
expect_allow \
  "main cwd + 二重引用 cd feature && commit は許可" \
  "$main_repo" \
  "cd \"$feature_repo\" && git commit -m x"
expect_allow \
  "main cwd + 単一引用 cd feature && commit は許可" \
  "$main_repo" \
  "cd '$feature_repo' && git commit -m x"
expect_allow \
  "main cwd + 空白含み引用 -C feature commit は許可" \
  "$main_repo" \
  "git -C \"$space_repo\" commit -m x"
expect_allow \
  "main cwd + 空白含み引用 cd feature && commit は許可" \
  "$main_repo" \
  "cd \"$space_repo\" && git commit -m x"
expect_allow \
  "main cwd + 改行区切り cd feature + commit は許可" \
  "$main_repo" \
  "$(printf 'cd %s\ngit commit -m x' "$feature_repo")"
# 書込が dir 差し替えを持たない複合は session cwd(feature) 宛てと証明できるため許可
expect_allow \
  "feature cwd + read系 -C + 素の commit は cwd 宛てで許可" \
  "$feature_repo" \
  "git -C $main_repo status && git commit -m x"
expect_allow \
  "feature cwd + read系 -C パイプ + 素の commit は cwd 宛てで許可" \
  "$feature_repo" \
  "git -C $main_repo log | git commit -m x"
expect_allow \
  "非repo cwd + -C feature commit は許可" \
  "$non_repo_dir" \
  "git -C $feature_repo commit -m x"

# 拒否側: 解決先が main / 解決不能なら session cwd が feature でも拒否する
expect_other_target_deny \
  "feature cwd + -C main commit は拒否" \
  "$feature_repo" \
  "git -C $main_repo commit -m x"
expect_other_target_deny \
  "feature cwd + cd main && commit は拒否" \
  "$feature_repo" \
  "cd $main_repo && git commit -m x"
expect_other_target_deny \
  "feature cwd + 改行区切り cd main + commit は拒否" \
  "$feature_repo" \
  "$(printf 'cd %s\ngit commit -m x' "$main_repo")"
expect_other_target_deny \
  "feature cwd + -C main push feature は拒否" \
  "$feature_repo" \
  "git -C $main_repo push origin feature/test"
expect_unclassified_deny \
  "feature cwd + subshell 内 cd main commit は解決不能で拒否" \
  "$feature_repo" \
  "(cd $main_repo && git commit -m x)" \
  "cannot prove -C/cd write target"
expect_unclassified_deny \
  "feature cwd + write側に別 -C が混在する複合は解決不能で拒否" \
  "$feature_repo" \
  "git -C $feature_repo status && git -C $main_repo commit -m x" \
  "cannot prove -C/cd write target"
expect_unclassified_deny \
  "feature cwd + 変数展開を含む -C commit は解決不能で拒否" \
  "$feature_repo" \
  'git -C "$BMC_TARGET" commit -m x' \
  "cannot prove -C/cd write target"
expect_main_branch_deny \
  "非repo cwd + -C main commit は拒否" \
  "$non_repo_dir" \
  "git -C $main_repo commit -m x"

# [2026-10-09][test] issue #1779: own-repo read-only の piped/複合 cd 誤拒否を回帰固定。
# 背景:
#   - ユーザー依頼意図: `cd <repo> && gh pr view "$N" | cat` や for ループ内の
#     `cd "$d" && git fetch` のような read-only 複合が、引数位置の $VAR で
#     read-only 証明を落ちた後「conditional or piped cd」「wrapped cd」で
#     誤拒否され、調査コマンドの分割を強いられていた（#1746 の再発）。
#   - 守るべき業務ルール: write を起こしうる形（push・gh 書込系・実行名位置の
#     $VAR 間接指定・`$(...)` 置換・不透明実行）を含む cd 複合と、group 内で
#     実際に実行される cd は従来どおり拒否する（fail-open を作らない）。
#   - 他案不採用理由: 許可側だけのテストでは、将来 write 判定のゲートを緩めた
#     ときに deny 回帰を検知できないため不採用（許可・拒否を対で置く）。
expect_allow \
  "cd + 引数変数の gh pr view をパイプしても許可" \
  "$feature_repo" \
  "cd $feature_repo && gh pr view \"\$PR_NUM\" | cat"

expect_allow \
  "cd + git log を変数パターンの grep にパイプしても許可" \
  "$feature_repo" \
  "cd $feature_repo && git log --oneline | grep \"\$PAT\""

expect_allow \
  "for ループ内の cd + git fetch は許可" \
  "$feature_repo" \
  "for d in $feature_repo $main_repo; do cd \"\$d\" && git fetch origin; done"

expect_allow \
  "cd + for ループの gh pr view をパイプしても許可" \
  "$feature_repo" \
  "cd $feature_repo && for pr in 1 2; do gh pr view \"\$pr\"; done | cat"

expect_unclassified_deny \
  "cd + gh pr create のパイプは従来どおり拒否" \
  "$feature_repo" \
  "cd $feature_repo && gh pr create --title x | cat" \
  "across conditional or piped cd"

expect_unclassified_deny \
  "for ループ内の cd + git push は従来どおり拒否" \
  "$feature_repo" \
  "for d in $feature_repo; do cd \"\$d\" && git push origin feature/test; done" \
  "wrapped cd"

expect_unclassified_deny \
  "実行名が変数の piped cd 複合は従来どおり拒否" \
  "$feature_repo" \
  "cd $feature_repo | \$G push" \
  "across conditional or piped cd"

expect_unclassified_deny \
  "cd + 置換内の git push は従来どおり拒否" \
  "$feature_repo" \
  "cd $feature_repo && cat \$(git push)" \
  "through shell substitution"

# [2026-10-10][test] issue #1361 事象1: 本番リリース正規手順の tag push を回帰固定。
# 背景:
#   - ユーザー依頼意図: `git tag r-v1.31.0 <sha> && git push origin refs/tags/r-v1.31.0`
#     （本番リリース正規手順）が main checkout から「main 直 push」として誤 deny
#     されていた。tag push は main の HEAD を動かさないため許可する。
#   - 守るべき業務ルール: 短縮タグ名（branch との曖昧性）・--tags/--follow-tags・
#     colon refspec・main 混在・commit 同梱・third-party upstream 宛ては従来どおり
#     拒否する（fail-closed は緩めない）。
#   - 他案不採用理由: 許可側だけのテストでは、将来 tag-only 判定を緩めたときに
#     deny 回帰を検知できないため不採用（許可・拒否を対で置く）。
expect_allow \
  "main cwd で git tag 作成 + refs/tags push（リリース正規手順）は許可" \
  "$main_repo" \
  "git tag r-v1.31.0 HEAD && git push origin refs/tags/r-v1.31.0"

expect_allow \
  "main cwd で単発 refs/tags push は許可" \
  "$main_repo" \
  "git push origin refs/tags/r-v1.31.0"

expect_allow \
  "main cwd で複数 refs/tags push は許可" \
  "$main_repo" \
  "git push origin refs/tags/v1 refs/tags/v2"

expect_allow \
  "feature cwd で refs/tags push は従来どおり許可" \
  "$feature_repo" \
  "git push origin refs/tags/v1"

expect_main_branch_deny \
  "main cwd で短縮タグ名 push は拒否（branch名と区別不能）" \
  "$main_repo" \
  "git push origin r-v1.31.0"

expect_main_branch_deny \
  "main cwd で --tags 一括 push は拒否" \
  "$main_repo" \
  "git push origin --tags"

expect_main_branch_deny \
  "main cwd で --follow-tags は拒否" \
  "$main_repo" \
  "git push origin --follow-tags"

expect_main_branch_deny \
  "main cwd で refs/tags と main 混在 push は拒否" \
  "$main_repo" \
  "git push origin refs/tags/v1 main"

expect_main_branch_deny \
  "main cwd で colon 付き refs/tags refspec は拒否" \
  "$main_repo" \
  "git push origin refs/tags/v1:refs/tags/v2"

expect_main_branch_deny \
  "main cwd で tag push + commit 同梱は拒否" \
  "$main_repo" \
  "git push origin refs/tags/v1 && git commit --allow-empty -m x"

expect_block \
  "feature cwd で upstream への refs/tags push は拒否" \
  "$feature_repo" \
  "git push upstream refs/tags/v1"

# [2026-10-10][test] issue #1361 事象2: heredoc 本文内の git 文字列を回帰固定。
# 背景:
#   - ユーザー依頼意図: `cat <<'EOF'` や `gh issue create --body "$(cat <<'EOF' ...)"`
#     の heredoc 本文に git/gh 文字列があるだけで誤 deny されていた。heredoc 本体は
#     stdin データであり実行されないため許可する。
#   - 守るべき業務ルール: 本体が実行プログラムになる形（python3/sh 等の不透明実行が
#     同じパイプラインにいる、非引用デリミタ内の $(...) は実行されうる）は従来どおり
#     拒否する（fail-closed は緩めない）。
#   - 他案不採用理由: 許可側だけのテストでは、将来 heredoc 走査を緩めたときに
#     deny 回帰を検知できないため不採用（許可・拒否を対で置く）。
expect_allow \
  "cat heredoc 本文内の git push 文字列は許可" \
  "$main_repo" \
  "cat > $tmp/body1361.md <<'EOF'
release steps: git push origin main / gh pr list
EOF"

expect_allow \
  "gh --body の heredoc 内 git push 文字列は許可" \
  "$main_repo" \
  'gh issue create --body "$(cat <<'"'"'EOF'"'"'
release note

run: git push origin main
EOF
)"'

expect_allow \
  "quoted heredoc 内の literal \$(git push) 文字列は許可" \
  "$main_repo" \
  "cat <<'EOF'
literal \$(git push origin main)
EOF"

expect_unclassified_deny \
  "python3 heredoc 本文の git 文字列は実行プログラムのため拒否" \
  "$main_repo" \
  "python3 - <<'PYEOF'
print('git push origin main')
PYEOF" \
  "through opaque"

expect_main_branch_deny \
  "sh heredoc 内の git push は実行されるため拒否" \
  "$main_repo" \
  "sh <<'EOF'
git push origin main
EOF"

expect_unclassified_deny \
  "非引用 heredoc 内の \$(git push) は置換実行のため拒否" \
  "$feature_repo" \
  'cat <<EOF
$(git push origin main)
EOF' \
  "through shell substitution"

expect_main_branch_deny \
  "heredoc 後の実 git push は拒否" \
  "$main_repo" \
  "cat <<'EOF'
body
EOF
git push origin main"

# [2026-10-13][test] issue #3922: 読み取り専用の $() 置換と、非シェル系
#   インタプリタの stdin になる quoted heredoc 本体の誤拒否を回帰固定。
# 背景:
#   - ユーザー依頼意図: `until s=$(gh run view ...)`・`T=$(git describe ...)`・
#     `python3 - <<'EOF'`（ファイル書換だけ・本体に git 言及）のような、
#     git/gh 書込みを含まないコマンドが shell substitution / ambiguous parse で
#     誤拒否され、都度単発コマンドへの分割を強いられていた。
#   - 守るべき業務ルール: 置換内側の書込み系（git push / gh pr create /
#     未知サブコマンド）は従来どおり拒否し、python 本体の git push 文字列は
#     opaque 検査で拒否を維持する（許可・拒否を対で置く）。
#   - 他案不採用理由: 許可側だけのテストでは、将来置換検査を緩めたときに
#     書込み置換の deny が消えても検知できないため不採用。
expect_allow \
  "置換内側が read-only gh run view だけの代入は許可" \
  "$feature_repo" \
  "s=\$(gh run view 123 --json status,conclusion --jq '.status'); echo \$s"

expect_allow \
  "until ループ内の read-only gh 置換ポーリングは許可" \
  "$feature_repo" \
  "until s=\$(gh run view 123 --json status --jq '.status'); [[ \"\$s\" == \"completed\" ]]; do sleep 30; done; echo \$s"

expect_allow \
  "置換内側が read-only git describe だけの代入は許可" \
  "$feature_repo" \
  "T=\$(git describe --tags 2>/dev/null); echo \$T"

expect_allow \
  "cd + for 内 merge-base + git describe 置換の複合は許可" \
  "$main_repo" \
  "cd $feature_repo && for c in a b; do git merge-base --is-ancestor \$c HEAD || echo no; done; T=\$(git describe --tags 2>/dev/null); echo \$T"

expect_allow \
  "python3 heredoc 本体の git 言及のみ（書込みなし）は許可" \
  "$feature_repo" \
  "python3 - <<'EOF'
from pathlib import Path
p = Path('f.ts')
p.write_text(\"describe('git merge flow')\")
EOF"

expect_unclassified_deny \
  "置換内側の git push は従来どおり拒否" \
  "$feature_repo" \
  "x=\$(git push origin main)" \
  "through shell substitution"

expect_unclassified_deny \
  "置換内側の gh pr create は従来どおり拒否" \
  "$feature_repo" \
  "x=\$(gh pr create --title t)" \
  "through shell substitution"

expect_unclassified_deny \
  "置換内側の未知 git サブコマンドは従来どおり拒否" \
  "$feature_repo" \
  "x=\$(git unknownalias)" \
  "through shell substitution"

expect_unclassified_deny \
  "python3 heredoc 本体の git push 実行は opaque で拒否" \
  "$main_repo" \
  "python3 - <<'EOF'
subprocess.run(['git', 'push', 'origin', 'main'])
EOF" \
  "through opaque"

# 文字列化の境界: 終端行は引用の外に残す。包みすぎると後続コマンドが本体に
# 癒着し git/gh 実行が見えなくなる（codex-review 指摘の回帰固定）。
expect_allow \
  "python3 heredoc 後の git status は本体と癒着せず許可" \
  "$feature_repo" \
  "python3 - <<'EOF'
print('x')
EOF
git status"

expect_unclassified_deny \
  "python3 heredoc 後の実 git push は癒着せず opaque で拒否" \
  "$main_repo" \
  "python3 - <<'EOF'
print('x')
EOF
git push origin main" \
  "through opaque"

# 同一行の複数 heredoc: 本体が連続しても引用境界が壊れないこと。
expect_allow \
  "python3 への複数 heredoc（git 言及あり）は許可" \
  "$feature_repo" \
  "python3 - <<'A' <<'B'
git status read
A
git log read
B"

# [2026-10-13][test] issue #3920 回帰: 外側で GIT_CONFIG_GLOBAL を別ファイルへ
# 向けて起動されても、冒頭の退避・unset・HOME pin により外側ファイルは
# 変更されない。プローブモードの子実行が「HOME 差し替え + git config
# --global 書き込み」だけを本スクリプトの同一経路で再現するため、センチネル
# 内容の外側ファイルが無傷なことをここで固定する（失敗時は子 rc 非 0 または
# 内容差分として FAIL）。
outer_cfg="$tmp/outer-global.gitconfig"
printf '[github]\n\tuser = OuterOwner\n' > "$outer_cfg"
outer_cfg_before="$(cat "$outer_cfg")"
if GIT_CONFIG_GLOBAL="$outer_cfg" BMC_TEST_ENV_ISOLATION_PROBE=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 \
  && [ "$(cat "$outer_cfg")" = "$outer_cfg_before" ]; then
  printf '[PASS] %s\n' "外側 GIT_CONFIG_GLOBAL のファイルは変更されない（issue #3920）"
  PASS=$((PASS + 1))
else
  printf '[FAIL] %s\n' "外側 GIT_CONFIG_GLOBAL のファイルは変更されない（issue #3920）"
  FAIL=$((FAIL + 1))
fi

# [2026-10-15][test] Context Mode 試験導入 F0 / T-08:
# ctx のコード実行系（ctx_execute / ctx_execute_file / ctx_batch_execute）は入力が
# `command` ではなく `code` / `commands[].command` のため、従来は main への
# git commit / push が素通りした。既存 Bash のケースは変えず、ctx 経由でも同じ判定になることを固定する。
run_hook_ctx() {
  local cwd="$1"
  local tool="$2"
  local input_json="$3"
  printf '{"tool_name":%s,"cwd":%s,"tool_input":%s}\n' "$(json_string "$tool")" "$(json_string "$cwd")" "$input_json" \
    | (cd "$cwd" && strip_test_git_config_env bash "$SCRIPT")
}

expect_ctx_block() {
  local name="$1" cwd="$2" tool="$3" input_json="$4" out
  out="$(run_hook_ctx "$cwd" "$tool" "$input_json" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision.*deny'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_ctx_allow() {
  local name="$1" cwd="$2" tool="$3" input_json="$4" out
  out="$(run_hook_ctx "$cwd" "$tool" "$input_json" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision'; then
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  else
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

expect_ctx_ask() {
  local name="$1" cwd="$2" tool="$3" input_json="$4" out
  out="$(run_hook_ctx "$cwd" "$tool" "$input_json" 2>&1)"
  if printf '%s' "$out" | grep -q 'permissionDecision":"ask"'; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: %s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

CTX_EXEC="mcp__context-mode__ctx_execute"
CTX_FILE="mcp__context-mode__ctx_execute_file"
CTX_BATCH="mcp__context-mode__ctx_batch_execute"

expect_ctx_block \
  "T-08 ctx_execute(shell) で main への git push は拒否" \
  "$main_repo" "$CTX_EXEC" '{"language":"shell","code":"git push origin main"}'
expect_ctx_block \
  "T-08 ctx_execute(shell) で main への git commit は拒否" \
  "$main_repo" "$CTX_EXEC" '{"language":"shell","code":"echo hi\ngit commit -m docs"}'
expect_ctx_block \
  "T-08 ctx_execute(python) の文字列中 git push は拒否" \
  "$main_repo" "$CTX_EXEC" '{"language":"python","code":"import subprocess\nsubprocess.run([\"git\", \"push\", \"origin\", \"main\"])"}'
expect_ctx_block \
  "T-08 ctx_execute(python) の1行 os.system git push も拒否" \
  "$main_repo" "$CTX_EXEC" '{"language":"python","code":"import os; os.system(\"git push origin main\")"}'
expect_ctx_block \
  "T-08 ctx_execute_file の code で main への git push は拒否" \
  "$main_repo" "$CTX_FILE" '{"path":"README.md","language":"shell","code":"git push origin main"}'
expect_ctx_block \
  "T-08 ctx_batch_execute の2件目の git commit(main) は拒否" \
  "$main_repo" "$CTX_BATCH" '{"commands":[{"label":"a","command":"git status"},{"label":"b","command":"git commit -m docs"}],"queries":["x"]}'
expect_ctx_ask \
  "T-08 ctx_execute で feature ブランチへの push は止めず、確認(ask)になる" \
  "$feature_repo" "$CTX_EXEC" '{"language":"shell","code":"git push origin feature/test"}'
expect_ctx_ask \
  "T-08 ctx_execute の git 無関係コードは止めず、確認(ask)になる" \
  "$main_repo" "$CTX_EXEC" '{"language":"python","code":"print(1+1)"}'
expect_ctx_ask \
  "T-08 ctx_batch_execute の読み取りだけ(git status)は止めず、確認(ask)になる" \
  "$main_repo" "$CTX_BATCH" '{"commands":[{"label":"a","command":"git status"}],"queries":["x"]}'
expect_ctx_allow \
  "T-08 ctx_execute 空コードは何もせず許可" \
  "$main_repo" "$CTX_EXEC" '{"language":"shell","code":""}'
expect_ctx_block \
  "T-08 ctx_upgrade は常に拒否（版の自動更新をしない）" \
  "$main_repo" "mcp__context-mode__ctx_upgrade" '{}'
expect_ctx_block \
  "T-08 ctx_insight は常に拒否（外部への送信をしない）" \
  "$main_repo" "mcp__context-mode__ctx_insight" '{}'
# [2026-10-16] Codex review: 大きい入力（環境変数・引数の上限を超える長さ）でも素通りしない
CTX_BIG_PAD=$(python3 -c 'print("# " + "x" * 300000)')
expect_ctx_block \
  "T-08 ctx_execute の大きい code（約300KB）でも main への git push は拒否" \
  "$main_repo" "$CTX_EXEC" "{\"language\":\"shell\",\"code\":\"${CTX_BIG_PAD}\\ngit push origin main\"}"
expect_ctx_ask \
  "T-08 ctx_execute の大きい code（約300KB）の無関係コードも素通りせず確認(ask)になる" \
  "$main_repo" "$CTX_EXEC" "{\"language\":\"python\",\"code\":\"${CTX_BIG_PAD}\\nprint(1)\"}"
# [2026-10-16] Codex review 2: 内部検査が異常終了したら確認(ask)へ進めず止める
CTX_FAIL_DIR=$(mktemp -d)
mkdir -p "$CTX_FAIL_DIR/scripts"
ln -s "$(cd "$(dirname "$SCRIPT")/../lib" && pwd)" "$CTX_FAIL_DIR/lib"
sed 's|bash "${BASH_SOURCE\[0\]}" 2>/dev/null|bash -c "exit 23" 2>/dev/null|' "$SCRIPT" > "$CTX_FAIL_DIR/scripts/block-main-commit.sh"
CTX_SAVED_SCRIPT="$SCRIPT"
SCRIPT="$CTX_FAIL_DIR/scripts/block-main-commit.sh"
expect_ctx_block \
  "T-08 内部検査が異常終了したら確認(ask)ではなく拒否" \
  "$main_repo" "$CTX_EXEC" '{"language":"python","code":"print(1)"}'
SCRIPT="$CTX_SAVED_SCRIPT"
rm -rf "$CTX_FAIL_DIR"
# 範囲外ツールの `code` 欄は読まない（matcher 外・従来どおり）
expect_ctx_allow \
  "T-08 対象外ツールの code 欄は検査しない" \
  "$main_repo" "mcp__other__run" '{"code":"git push origin main"}'

TOTAL=$((PASS + FAIL))
printf '\n=== block-main-commit.test.sh: %d/%d PASS ===\n' "$PASS" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
