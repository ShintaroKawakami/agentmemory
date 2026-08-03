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

run_hook() {
  local cwd="$1"
  local command="$2"
  printf '{"tool_name":"Bash","tool_input":{"cwd":%s,"command":%s}}\n' "$(json_string "$cwd")" "$(json_string "$command")" | bash "$SCRIPT"
}

run_hook_raw() {
  local payload="$1"
  printf '%s' "$payload" | bash "$SCRIPT"
}

run_hook_script() {
  local cwd="$1"
  local command="$2"
  local script="$3"
  printf '{"tool_name":"Bash","tool_input":{"cwd":%s,"command":%s}}\n' "$(json_string "$cwd")" "$(json_string "$command")" \
    | bash "$script"
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

main_repo="$tmp/main"
feature_repo="$tmp/feature"
mkdir -p "$main_repo" "$feature_repo"
git -C "$main_repo" init -q
git -C "$main_repo" checkout -q -b main
git -C "$main_repo" config user.email test@example.com
git -C "$main_repo" config user.name "Test User"
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
echo init > "$feature_repo/README.md"
git -C "$feature_repo" add README.md
git -C "$feature_repo" commit -q -m init
git -C "$feature_repo" update-ref refs/remotes/origin/main HEAD
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

expect_allow \
  "先頭 cd + multiline の feature push を許可" \
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

expect_block \
  "先頭 cd でも対象が main なら commit 拒否" \
  "$main_repo" \
  "cd $main_repo && git commit --allow-empty -m 'docs: still main'"

expect_allow \
  "読み取り検索内の git push 文字列は許可" \
  "$main_repo" \
  'rg -n "git push|post-merge-gate|workflow" hook-library scripts'

TOTAL=$((PASS + FAIL))
printf '\n=== block-main-commit.test.sh: %d/%d PASS ===\n' "$PASS" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
