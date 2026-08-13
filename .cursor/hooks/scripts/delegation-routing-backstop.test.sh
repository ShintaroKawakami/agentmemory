#!/usr/bin/env bash
set -euo pipefail

# [2026-08-10][test] delegation-routing-backstop.sh の回帰テスト。
# 背景:
#   - 依頼意図: reminder（UserPromptSubmit）の検知漏れセッションで、最初の Edit/Write/MultiEdit
#     後に1回だけフィードバックが出ることと、reminder発火済みセッションでは無音であることを
#     機械的に固定する。PostToolUse からのフィードバック経路は本リポ初の技術検証のため、
#     stderr-only 縮退フラグの挙動も固定する。
#   - 守るべき業務ルール: CLAUDE_PROJECT_DIR を一時ディレクトリへ切り替え、実リポの
#     .claude/hooks/.delegation-reminder-cache/ を汚染しない。
# 対応: マーカー無し初回発火・2回目無音・reminder発火済みセッションで無音・STDERR_ONLY縮退を検証する。
#
# [2026-08-11][test] codexレビュー対応（PR #1558 🟡3件）を反映したケース追加・修正。
# 背景:
#   - 依頼意図: W1（stdin渡し）が長文 tool_input でも exit 0 を維持すること、W2（session_id
#     ハッシュ化）で reminder マーカーが sha256 hex ファイル名になったことを反映する。
#     旧テストは生の session_id をそのままファイル名として書き込んでおり、ハッシュ化後は
#     一致しないため reminder 既発火判定が機能しなくなっていた（要修正）。
# 対応: reminder マーカー作成をハッシュ化後のファイル名へ修正し、長文入力・不正 session_id の
#   ケースを追加する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/delegation-routing-backstop.sh"

TMP_PROJECT="$(mktemp -d)"
CACHE_DIR="$TMP_PROJECT/runtime-cache"
trap 'rm -rf "$TMP_PROJECT"' EXIT
export DELEGATION_REMINDER_CACHE_DIR="$CACHE_DIR"
mkdir -p "$CACHE_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

payload() {
  local session="$1"
  python3 -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Edit", "tool_input": {"file_path": "foo.py"}}))' "$session"
}

session_hash() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8", errors="surrogatepass")).hexdigest())' "$1"
}

# 1) マーカー無し初回 Edit は JSON フィードバックを出す
out1="$(printf '%s' "$(payload "sess-a")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
echo "$out1" | grep -q '"decision"' || fail "初回Editでdecision JSONが出ない: $out1"
echo "$out1" | grep -q '"block"' || fail "初回Editでblock decisionでない: $out1"

# 2) 同一セッションの2回目は無音
out2="$(printf '%s' "$(payload "sess-a")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
[ -z "$out2" ] || fail "backstop2回目は無音であるべき: $out2"

# 3) reminder が既に発火済みのセッションでは無音（マーカーは sha256 hex ファイル名）
: > "$CACHE_DIR/$(session_hash "sess-b")"
out3="$(printf '%s' "$(payload "sess-b")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
[ -z "$out3" ] || fail "reminder発火済みセッションでbackstopが鳴った: $out3"

# 4) STDERR_ONLY 縮退: stdout は空、stderr にメッセージ
out4="$(printf '%s' "$(payload "sess-c")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" DELEGATION_BACKSTOP_STDERR_ONLY=1 bash "$HOOK" 2>"$TMP_PROJECT/stderr.txt")"
[ -z "$out4" ] || fail "STDERR_ONLY時にstdoutへ出力された: $out4"
grep -q "三役体制" "$TMP_PROJECT/stderr.txt" || fail "STDERR_ONLY時にstderrへメッセージが出ない"

# 5) session_id が取れない場合は無音・exit 0
set +e
out5="$(printf 'not-json{{{' | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
exit5=$?
set -e
[ "$exit5" -eq 0 ] || fail "session_id 不明時にexit 0にならない（exit=$exit5）: $out5"
[ -z "$out5" ] || fail "session_id 不明時は無音であるべき: $out5"

# [2026-08-11][fix]
# 背景:
#   - 依頼意図: 200KB級の日本語payloadでもbackstopのstdin経路を実機で検証する。
#   - 守るべき業務ルール: テスト自身がmacOSのARG_MAXを超えず、payload生成失敗も見逃さない。
#   - 他案不採用理由: 長文をshell変数からPython argvへ渡す案は、hook起動前に
#     Argument list too long となり得るため不採用。
# 対応: Python標準出力をhookのstdinへ直結し、pipefailを明示して生成側失敗も検知する。
# 6) 長文 tool_input（約200KB）でも exit 0・stdin 経由で正しく検知する（W1: env var 上限回避）
set -o pipefail
set +e
long_output="$(
  python3 -c 'import json; print(json.dumps({"session_id": "sess-long-1", "tool_name": "Edit", "tool_input": {"file_path": "foo.py", "new_string": "あ" * 200000}}))' |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1
)"
long_exit=$?
set -e
[ "$long_exit" -eq 0 ] || fail "長文tool_inputでexit 0にならない（exit=$long_exit）"
echo "$long_output" | grep -q '"decision"' || fail "長文tool_inputでdecision JSONが出ない: ${long_output:0:200}"

# 7) session_id に `../` や改行を含んでも cache 外へ書き込まず、固定長 hex ファイル名になる（W2）
find "$CACHE_DIR" -maxdepth 1 -type f | xargs -I{} rm -f {} 2>/dev/null || true
malicious_session=$'../../evil\ninjected'
malicious_payload="$(payload "$malicious_session")"
set +e
malicious_output="$(printf '%s' "$malicious_payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
malicious_exit=$?
set -e
[ "$malicious_exit" -eq 0 ] || fail "不正session_idでexit 0にならない（exit=$malicious_exit）"
echo "$malicious_output" | grep -q '"decision"' || fail "不正session_idでも発火自体はするはず: $malicious_output"
cache_files="$(find "$CACHE_DIR" -maxdepth 1 -type f -name '*' ! -name '.*' 2>/dev/null)"
[ -n "$cache_files" ] || fail "cacheディレクトリにマーカーが作られていない"
# here-string で読む（パイプにすると while がサブシェルで動き fail の exit が親に伝わらないため）
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  base="${base%.backstop}"
  case "$base" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) fail "マーカーファイル名がhexハッシュでない: $base" ;;
  esac
done <<< "$cache_files"

echo "PASS: delegation-routing-backstop"
