#!/usr/bin/env bash
set -euo pipefail

# [2026-08-12][test] fable-implementation-guard.sh の回帰テスト。
# 背景:
#   - 依頼意図: Fable セッションで Edit/Write/MultiEdit が使われた直後に1回だけ
#     「Fable は実装者ではない」リマインダーが出ること、Fable でないセッションや
#     2回目以降は無音であることを機械的に固定する。model 判定が stdin JSON 直下 →
#     transcript_path の JSONL 末尾（tail 200行）の2段フォールバックであることも固定する。
#   - 守るべき業務ルール: CLAUDE_PROJECT_DIR を一時ディレクトリへ切り替え、実リポの
#     .claude/hooks/.delegation-reminder-cache/ を汚染しない。
# 対応: 非Fableモデル無音・Fable初回発火・2回目無音・transcriptフォールバック発火・
#   tail窓外は無音・FABLE_GUARD_DISABLED・不正session_idでもexit0・stdin不正でもexit0、を検証する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/fable-implementation-guard.sh"

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
  # $1=session_id $2=model(空文字可) $3=transcript_path(空文字可)
  python3 -c '
import json, sys
session, model, transcript = sys.argv[1], sys.argv[2], sys.argv[3]
obj = {"session_id": session, "tool_name": "Edit", "tool_input": {"file_path": "foo.py"}}
if model:
    obj["model"] = model
if transcript:
    obj["transcript_path"] = transcript
print(json.dumps(obj))
' "$1" "$2" "$3"
}

session_hash() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8", errors="surrogatepass")).hexdigest())' "$1"
}

# 1) 非Fableモデル（stdin直下）は無音
out1="$(printf '%s' "$(payload "sess-a" "claude-sonnet-5" "")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
[ -z "$out1" ] || fail "非FableモデルなのにJSONが出た: $out1"

# 2) Fableモデル（stdin直下）初回 Edit は JSON フィードバックを出す
out2="$(printf '%s' "$(payload "sess-b" "us.anthropic.fable-5" "")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
echo "$out2" | grep -q '"decision"' || fail "Fable初回Editでdecision JSONが出ない: $out2"
echo "$out2" | grep -q '"block"' || fail "Fable初回Editでblock decisionでない: $out2"
echo "$out2" | grep -q 'Fable' || fail "reasonにFable言及が無い: $out2"

# 3) 同一セッションの2回目は無音
out3="$(printf '%s' "$(payload "sess-b" "us.anthropic.fable-5" "")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
[ -z "$out3" ] || fail "2回目は無音であるべき: $out3"

# 4) model 大文字小文字混在（"FABLE"）でも検知する（新規セッション）
out4="$(printf '%s' "$(payload "sess-c" "FABLE-Preview" "")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
echo "$out4" | grep -q '"decision"' || fail "大文字FABLEでdecision JSONが出ない: $out4"

# 5) stdin直下にmodelが無く、transcript_path のJSONL末尾（tail圏内）にFableが出てくる場合に発火する
TRANSCRIPT_OK="$TMP_PROJECT/transcript-ok.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"hi"}}'
  echo '{"type":"assistant","message":{"model":"claude-sonnet-5","content":"..."}}'
  echo '{"type":"assistant","message":{"model":"fable-5-2026","content":"..."}}'
} > "$TRANSCRIPT_OK"
out5="$(printf '%s' "$(payload "sess-d" "" "$TRANSCRIPT_OK")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
echo "$out5" | grep -q '"decision"' || fail "transcriptフォールバックでdecision JSONが出ない: $out5"

# 6) transcript の tail 圏外（200行より前）にだけ Fable がある場合は無音（全体を読み込まない設計の確認）
TRANSCRIPT_OUT_OF_WINDOW="$TMP_PROJECT/transcript-out-of-window.jsonl"
{
  echo '{"type":"assistant","message":{"model":"fable-5-2026","content":"..."}}'
  i=0
  while [ "$i" -lt 250 ]; do
    echo '{"type":"assistant","message":{"model":"claude-sonnet-5","content":"..."}}'
    i=$((i + 1))
  done
} > "$TRANSCRIPT_OUT_OF_WINDOW"
out6="$(printf '%s' "$(payload "sess-e" "" "$TRANSCRIPT_OUT_OF_WINDOW")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK")"
[ -z "$out6" ] || fail "tail窓外のFableで発火してしまった（全体走査になっている）: $out6"

# 7) transcript_path が存在しない/読めない場合は無音・exit 0（fail-open）
set +e
out7="$(printf '%s' "$(payload "sess-f" "" "$TMP_PROJECT/does-not-exist.jsonl")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
exit7=$?
set -e
[ "$exit7" -eq 0 ] || fail "transcript読めない時にexit 0にならない（exit=$exit7）: $out7"
[ -z "$out7" ] || fail "transcript読めない時は無音であるべき: $out7"

# 8) FABLE_GUARD_DISABLED=1 は Fable モデルでも常に無音
out8="$(printf '%s' "$(payload "sess-g" "fable-5" "")" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" FABLE_GUARD_DISABLED=1 bash "$HOOK")"
[ -z "$out8" ] || fail "FABLE_GUARD_DISABLED=1でも発火した: $out8"

# 9) session_id が不正でも exit 0・固定長hexの marker ファイル名になる（W2と同型の対策）
find "$CACHE_DIR" -maxdepth 1 -type f -name 'fable-guard-*' | xargs -I{} rm -f {} 2>/dev/null || true
malicious_session=$'../../evil\ninjected'
malicious_payload="$(payload "$malicious_session" "fable-5" "")"
set +e
malicious_output="$(printf '%s' "$malicious_payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
malicious_exit=$?
set -e
[ "$malicious_exit" -eq 0 ] || fail "不正session_idでexit 0にならない（exit=$malicious_exit）: $malicious_output"
echo "$malicious_output" | grep -q '"decision"' || fail "不正session_idでも発火自体はするはず: $malicious_output"
cache_files="$(find "$CACHE_DIR" -maxdepth 1 -type f -name 'fable-guard-*' 2>/dev/null)"
[ -n "$cache_files" ] || fail "fable-guard-* marker が作られていない"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  suffix="${base#fable-guard-}"
  case "$suffix" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) fail "marker ファイル名がhexハッシュでない: $base" ;;
  esac
done <<< "$cache_files"

# 10) 壊れたJSON stdinでも exit 0・無音
set +e
out10="$(printf 'not-json{{{' | CLAUDE_PROJECT_DIR="$TMP_PROJECT" bash "$HOOK" 2>&1)"
exit10=$?
set -e
[ "$exit10" -eq 0 ] || fail "不正JSON入力でexit 0にならない（exit=$exit10）: $out10"
[ -z "$out10" ] || fail "不正JSON入力時は無音であるべき: $out10"

echo "PASS: fable-implementation-guard"
