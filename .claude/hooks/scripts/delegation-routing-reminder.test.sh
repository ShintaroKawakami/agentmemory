#!/usr/bin/env bash
set -euo pipefail

# [2026-08-10][test] delegation-routing-reminder.sh の回帰テスト。
# 背景:
#   - 依頼意図: 実装意図キーワード検知・セッション1回スロットル・不正JSON時のfail-openを
#     機械的に固定する（gbrain-recall-preflight.test.sh と同型の quiet-by-default 検証）。
#   - 守るべき業務ルール: CLAUDE_PROJECT_DIR を一時ディレクトリへ切り替え、実リポの
#     .claude/hooks/.delegation-reminder-cache/ を汚染しない。
# 対応: 通常プロンプト無音・キーワード発火・同一セッション2回目無音・不正JSON exit 0 を検証する。
#
# [2026-08-11][test] codexレビュー対応（PR #1558 🟡3件）を反映したケース追加。
# 背景:
#   - 依頼意図: W1（stdin渡し）が長文入力でも exit 0 を維持すること、W2（session_id ハッシュ化）が
#     path traversal を狙った session_id でも cache 外へ書き込まず固定長 hex ファイル名になる
#     ことを機械的に固定する。
# 対応: 200KB 規模の長文プロンプト・`../` や改行を含む不正 session_id のケースを追加する。
#
# [2026-08-11][test] codexレビュー対応（PR #1585 🟡）transcript サイズ上限のケース追加。
# 背景:
#   - 依頼意図: readlines() 全量読み込みをやめ、DELEGATION_REMINDER_MAX_BYTES 上限超過時は
#     末尾側だけを読む変更が、実際に末尾側から正しく検知できることを機械的に固定する。
# 対応: 大量のダミー行でファイルサイズを膨らませ、上限を末尾フラグメントより少しだけ大きく
#   設定して、上限超過時でも末尾の fable+大量読みを検知できることを検証する。
#
# [2026-08-11][test] Fable 大量読み継続リマインダー追補（ctx-save プラン承認・柱1）
# 背景:
#   - 依頼意図: 既存の実装意図キーワード検知（HIT）とは独立の Fable 大量読み検知
#     （HEAVYHIT）を、fable+大量読み／fableでも少量／モデル不明時フォールバック／
#     非ブロックの4観点で機械的に固定する。
#   - 守るべき業務ルール（本 test と hook 双方で同じ定義を使う）: 「直近50件のtool_useブロック」
#     とは、transcript(JSONL) を先頭行から走査し、各行の message.content
#     （message ラッパーが無いフラット形式なら content 直下）から type=="tool_use" の
#     ブロックを出現順に収集し、末尾から window 件（既定50・ツール種別を問わない）を
#     対象窓とする単位である（delegation-routing-reminder.sh 本体のコメントと同一定義）。
# 対応: make_transcript ヘルパーで tool_use ブロックを N 件持つ transcript fixture を生成し、
#   DELEGATION_REMINDER_READ_GREP_THRESHOLD 等の閾値環境変数はデフォルトのまま検証する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/delegation-routing-reminder.sh"

TMP_PROJECT="$(mktemp -d)"
CACHE_DIR="$TMP_PROJECT/runtime-cache"
trap 'rm -rf "$TMP_PROJECT"' EXIT
export DELEGATION_REMINDER_CACHE_DIR="$CACHE_DIR"
mkdir -p "$CACHE_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_hook() {
  local payload="$1"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK"
}

payload() {
  local prompt="$1"
  local session="$2"
  python3 -c 'import json,sys; print(json.dumps({"user_prompt": sys.argv[1], "session_id": sys.argv[2]}))' "$prompt" "$session"
}

payload_with_transcript() {
  local prompt="$1"
  local session="$2"
  local transcript_path="$3"
  python3 -c 'import json,sys; print(json.dumps({"user_prompt": sys.argv[1], "session_id": sys.argv[2], "transcript_path": sys.argv[3]}))' \
    "$prompt" "$session" "$transcript_path"
}

# transcript(JSONL) fixture 生成: tool_use ブロックを count 件持つ行を書き出す。
# model が空文字なら message.model を持たせない（判定不能ケース用）。
make_transcript() {
  local path="$1" model="$2" count="$3" tool_name="${4:-Read}"
  : > "$path"
  local i
  for ((i = 1; i <= count; i++)); do
    if [ -n "$model" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","model":"%s","content":[{"type":"tool_use","id":"toolu_%d","name":"%s","input":{"file_path":"f%d.txt"}}]}}\n' \
        "$model" "$i" "$tool_name" "$i" >>"$path"
    else
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_%d","name":"%s","input":{"file_path":"f%d.txt"}}]}}\n' \
        "$i" "$tool_name" "$i" >>"$path"
    fi
  done
}

# 1) 通常プロンプトは無音
normal_output="$(run_hook "$(payload "今日は天気だけ確認" "sess-normal")")"
[ -z "$normal_output" ] || fail "通常プロンプトは無音であるべき: $normal_output"

# 2) キーワード一致で発火
impl_output="$(run_hook "$(payload "このバグを修正して実装して" "sess-impl-1")")"
echo "$impl_output" | grep -q "三役体制" || fail "実装意図キーワードで発火しない: $impl_output"

# 3) 同一セッションの2回目は無音（スロットル）
impl_output_2="$(run_hook "$(payload "追加でリファクタして" "sess-impl-1")")"
[ -z "$impl_output_2" ] || fail "同一セッション2回目は無音であるべき: $impl_output_2"

# 4) 別セッションなら再度発火する
impl_output_other="$(run_hook "$(payload "作って" "sess-impl-2")")"
echo "$impl_output_other" | grep -q "三役体制" || fail "別セッションで発火しない: $impl_output_other"

# 5) 不正 JSON でも exit 0（fail-open）
set +e
bad_output="$(printf 'not-json{{{' | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
bad_exit=$?
set -e
[ "$bad_exit" -eq 0 ] || fail "不正JSON入力でexit 0にならない（exit=$bad_exit）: $bad_output"

# 6) 長文プロンプト（約200KB）でも exit 0・stdin 経由で正しく検知する（W1: env var 上限回避）
set +e
long_output="$(
  python3 -c 'import json; print(json.dumps({"user_prompt": "あ" * 200000 + "これを実装して", "session_id": "sess-long-1"}))' |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1
)"
long_exit=$?
set -e
[ "$long_exit" -eq 0 ] || fail "長文入力でexit 0にならない（exit=$long_exit）"
echo "$long_output" | grep -q "三役体制" || fail "長文入力でキーワード検知が発火しない: ${long_output:0:200}"

# 7) session_id に `../` や改行を含んでも cache 外へ書き込まず、固定長 hex ファイル名になる（W2）
find "$CACHE_DIR" -maxdepth 1 -type f | xargs -I{} rm -f {} 2>/dev/null || true
malicious_session=$'../../evil\ninjected'
malicious_payload="$(python3 -c 'import json,sys; print(json.dumps({"user_prompt": sys.argv[1], "session_id": sys.argv[2]}))' "作って" "$malicious_session")"
set +e
malicious_output="$(printf '%s' "$malicious_payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
malicious_exit=$?
set -e
[ "$malicious_exit" -eq 0 ] || fail "不正session_idでexit 0にならない（exit=$malicious_exit）"
echo "$malicious_output" | grep -q "三役体制" || fail "不正session_idでも発火自体はするはず: $malicious_output"
[ ! -e "$TMP_PROJECT/../evil" ] || fail "cache外へ書き込まれた（path traversal 成立）"
[ ! -e "$TMP_PROJECT/.claude/hooks/.delegation-reminder-cache" ] \
  || fail "legacy リポ内 cache が作られてしまった (#1701)"
cache_files="$(find "$CACHE_DIR" -maxdepth 1 -type f -name '*' ! -name '.*' 2>/dev/null)"
[ -n "$cache_files" ] || fail "runtime cache にマーカーが作られていない"
# here-string で読む（パイプにすると while がサブシェルで動き fail の exit が親に伝わらないため）
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) fail "マーカーファイル名がhexハッシュでない: $base" ;;
  esac
done <<< "$cache_files"

# 8) fable + 大量読み（Read が閾値20回以上）で発火する
fable_heavy_transcript="$TMP_PROJECT/fable-heavy.jsonl"
make_transcript "$fable_heavy_transcript" "claude-fable" 25 "Read"
fable_heavy_output="$(run_hook "$(payload_with_transcript "今日は天気だけ確認" "sess-fable-heavy" "$fable_heavy_transcript")")"
echo "$fable_heavy_output" | grep -q "大量読み" || fail "fable+大量読みで発火しない: $fable_heavy_output"

# 9) fable でも大量読みでなければ（閾値未満）非発火
fable_light_transcript="$TMP_PROJECT/fable-light.jsonl"
make_transcript "$fable_light_transcript" "claude-fable" 3 "Read"
fable_light_output="$(run_hook "$(payload_with_transcript "今日は天気だけ確認" "sess-fable-light" "$fable_light_transcript")")"
[ -z "$fable_light_output" ] || fail "fableでも少量読みは非発火であるべき: $fable_light_output"

# 10) モデル判定不能（message.model なし）でも大量読みなら共通文言へフォールバックして発火する
unknown_model_transcript="$TMP_PROJECT/unknown-model-heavy.jsonl"
make_transcript "$unknown_model_transcript" "" 25 "Grep"
unknown_model_output="$(run_hook "$(payload_with_transcript "今日は天気だけ確認" "sess-unknown-heavy" "$unknown_model_transcript")")"
echo "$unknown_model_output" | grep -q "大量読み" || fail "モデル判定不能時のフォールバックで発火しない: $unknown_model_output"

# 11) 同一セッションの2回目は無音（HEAVYHIT 側のスロットル確認）
unknown_model_output_2="$(run_hook "$(payload_with_transcript "今日は天気だけ確認" "sess-unknown-heavy" "$unknown_model_transcript")")"
[ -z "$unknown_model_output_2" ] || fail "HEAVYHIT の同一セッション2回目は無音であるべき: $unknown_model_output_2"

# 12) transcript_path が存在しない・不正でも非ブロック（exit 0）を維持する
set +e
missing_transcript_output="$(
  run_hook "$(payload_with_transcript "今日は天気だけ確認" "sess-missing-transcript" "$TMP_PROJECT/does-not-exist.jsonl")"
)"
missing_transcript_exit=$?
set -e
[ "$missing_transcript_exit" -eq 0 ] || fail "存在しないtranscript_pathでexit 0にならない（exit=$missing_transcript_exit）"
[ -z "$missing_transcript_output" ] || fail "存在しないtranscript_pathは非発火であるべき: $missing_transcript_output"

# 13) transcript がサイズ上限を超える場合、末尾側のみ読んでも fable+大量読みを検知できる
#     （DELEGATION_REMINDER_MAX_BYTES）
huge_transcript="$TMP_PROJECT/huge-fable.jsonl"
: > "$huge_transcript"
i=1
while [ "$i" -le 2000 ]; do
  printf '{"type":"user","message":{"role":"user","content":"filler %d"}}\n' "$i" >>"$huge_transcript"
  i=$((i + 1))
done
tail_fragment="$TMP_PROJECT/huge-fable-tail.jsonl"
make_transcript "$tail_fragment" "claude-fable" 25 "Read"
cat "$tail_fragment" >>"$huge_transcript"
huge_size="$(wc -c <"$huge_transcript" | tr -d ' ')"
tail_size="$(wc -c <"$tail_fragment" | tr -d ' ')"
small_max_bytes=$((tail_size + 500))
[ "$small_max_bytes" -lt "$huge_size" ] || fail "テスト前提が崩れている: 上限がファイル全体を含んでしまう"
huge_output="$(
  printf '%s' "$(payload_with_transcript "今日は天気だけ確認" "sess-huge-fable" "$huge_transcript")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" DELEGATION_REMINDER_MAX_BYTES="$small_max_bytes" bash "$HOOK"
)"
echo "$huge_output" | grep -q "大量読み" || fail "サイズ上限超過時に末尾から検知できない: $huge_output"

echo "PASS: delegation-routing-reminder"
