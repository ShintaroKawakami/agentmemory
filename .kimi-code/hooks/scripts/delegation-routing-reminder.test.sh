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
#
# [2026-08-27][test] クレジット残量条件の相乗りテスト追加。
# 背景:
#   - 依頼意図: クレジット残量キャッシュの有無・破損・閾値帯・スロットル・24時間経過・
#     codexbar 非実行を機械的に固定する。
#   - 守るべき業務ルール: テスト内で mktemp へ差し替え、実リポの agents.yaml や
#     ~/.cache/agent-hub/ を汚さない。偽 codexbar を PATH に置き、実行されないことを確認。
# 対応: キャッシュ無し・壊れJSON・warn未満・warn以上・strong以上・同日日付スロットル・
#   帯上昇・24時間以上古い・codexbar非実行の9ケースを追加。

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

run_hook_env() {
  local payload="$1"
  shift
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_PROJECT" "$@" bash "$HOOK"
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

# ===== [2026-08-27] クレジット残量条件テスト =====

# ヘルパー: agents.yaml と credit-usage.json を一時ディレクトリに作る
# [2026-08-27][fix] ケース間でマーカーが持ち越されないようにする
# 背景:
#   - 事象: 残量文言のスロットルは「日付 + 閾値帯」単位のため、マーカーがテストケース間で
#     共有されると、先行ケースが同じ帯で 1 度発火しただけで後続ケースが常に無音になり
#     「1回目で発火しない」と誤検知する（実際に検知した）。
#   - 守るべき業務ルール: 各ケースは独立した初期状態から始める。セッション単位マーカーと
#     日付+帯マーカーの両方をクリアする。
#   - 他案不採用理由: ケースごとに日付を変える案は、hook 側が UTC 日付を自前で取るため
#     テストから制御できず不採用。
setup_credit_test() {
  local tmp_dir="$1"
  mkdir -p "$tmp_dir"
  # 残量スロットルのマーカーを消す（実リポではなくテスト専用 CACHE_DIR のみ）
  find "$CACHE_DIR" -maxdepth 1 -type f -name '*-tier-*' -delete 2>/dev/null || true
}

make_agents_yaml() {
  local path="$1"
  local warn="${2:-55}"
  local strong="${3:-75}"
  cat > "$path" <<EOF
worker_delegation:
  credit_preflight:
    cache_path: "~/.cache/agent-hub/credit-usage.json"
    cache_ttl_seconds: 900
    claude_weekly_warn_percent: $warn
    claude_weekly_strong_percent: $strong
EOF
}

make_credit_cache() {
  local path="$1"
  local weekly="${2:-62}"
  local updated_at="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  cat > "$path" <<EOF
{
  "updatedAt": "$updated_at",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": $weekly, "session": 16, "weekly": $weekly, "willLastToReset": false},
    "glm": {"usedPercent": 2},
    "antigravity": {"usedPercent": 0},
    "kimi": {"usedPercent": 21},
    "codex": {"usedPercent": 70},
    "cursor": {"usedPercent": 79},
    "ocg": {"usedPercent": 0}
  }
}
EOF
}

CREDIT_TMP="$(mktemp -d)"
# テスト終了時にクリーンアップ（trap は既にあるので手動で追加）
# shellcheck disable=SC2064
trap "rm -rf '$CREDIT_TMP'; $(trap -p EXIT | sed "s/trap -- '\(.*\)' EXIT/\1/")" EXIT

# 14) キャッシュが無いとき、従来どおりの文言が出て exit 0
setup_credit_test "$CREDIT_TMP/no-cache"
make_agents_yaml "$CREDIT_TMP/no-cache/agents.yaml" 55 75
no_cache_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-no-cache")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/no-cache/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/no-cache/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$no_cache_output" | grep -q "三役体制" || fail "キャッシュ無しで従来文言が出ない: $no_cache_output"
echo "$no_cache_output" | grep -q "Claude 週次" && fail "キャッシュ無しで残量文言が出てしまう: $no_cache_output" || true

# 15) キャッシュが壊れた JSON のとき、従来どおりの文言が出て exit 0
setup_credit_test "$CREDIT_TMP/bad-cache"
make_agents_yaml "$CREDIT_TMP/bad-cache/agents.yaml" 55 75
printf 'not-json{{{' > "$CREDIT_TMP/bad-cache/credit-usage.json"
bad_cache_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-bad-cache")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/bad-cache/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/bad-cache/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$bad_cache_output" | grep -q "三役体制" || fail "壊れJSONで従来文言が出ない: $bad_cache_output"
echo "$bad_cache_output" | grep -q "Claude 週次" && fail "壊れJSONで残量文言が出てしまう: $bad_cache_output" || true

# 16) routes.claude.weekly が warn 未満のとき、残量文言が出ない
setup_credit_test "$CREDIT_TMP/below-warn"
make_agents_yaml "$CREDIT_TMP/below-warn/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/below-warn/credit-usage.json" 30
below_warn_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-below-warn")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/below-warn/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/below-warn/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$below_warn_output" | grep -q "三役体制" || fail "warn未満で従来文言が出ない: $below_warn_output"
echo "$below_warn_output" | grep -q "Claude 週次" && fail "warn未満で残量文言が出てしまう: $below_warn_output" || true

# 17) warn 以上のとき、残量文言と空き worker 名が出る
setup_credit_test "$CREDIT_TMP/warn"
make_agents_yaml "$CREDIT_TMP/warn/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/warn/credit-usage.json" 62
warn_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-warn")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/warn/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/warn/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$warn_output" | grep -q "三役体制" || fail "warn以上で従来文言が出ない: $warn_output"
echo "$warn_output" | grep -q "Claude 週次 62%" || fail "warn以上で残量文言が出ない: $warn_output"
echo "$warn_output" | grep -q "glm" || fail "warn以上で空きworker名が出ない: $warn_output"

# 18) strong 以上のとき、強い表現になる
setup_credit_test "$CREDIT_TMP/strong"
make_agents_yaml "$CREDIT_TMP/strong/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/strong/credit-usage.json" 80
strong_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-strong")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/strong/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/strong/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$strong_output" | grep -q "三役体制" || fail "strong以上で従来文言が出ない: $strong_output"
echo "$strong_output" | grep -q "⛔" || fail "strong以上で強い表現が出ない: $strong_output"

# 19) 実装キーワードが無い会話では、warn でも strong でも残量文言を出さない
# 残量の状況把握は SessionStart パネル（credit-baton-preflight.sh）が担うため、
# UserPromptSubmit 側は「実装へ着手しようとした瞬間」だけに絞る（重複とノイズの回避）。
setup_credit_test "$CREDIT_TMP/tier-throttle"
make_agents_yaml "$CREDIT_TMP/tier-throttle/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/tier-throttle/credit-usage.json" 62
# warn 帯・実装キーワード無し → 無音
tier_output1="$(
  printf '%s' "$(payload "今日は天気だけ確認" "sess-tier-1")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/tier-throttle/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/tier-throttle/credit-usage.json" bash "$HOOK" 2>&1
)"
[ -z "$tier_output1" ] || fail "実装キーワード無し・warn 帯では無音であるべき: $tier_output1"
# strong 帯へ上げても、実装キーワードが無ければ無音のまま
make_credit_cache "$CREDIT_TMP/tier-throttle/credit-usage.json" 80
tier_output3="$(
  printf '%s' "$(payload "今日は天気だけ確認" "sess-tier-3")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/tier-throttle/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/tier-throttle/credit-usage.json" bash "$HOOK" 2>&1
)"
[ -z "$tier_output3" ] || fail "実装キーワード無し・strong 帯でも無音であるべき: $tier_output3"

# 20) HIT ありの場合、帯が warn → strong に上がったら再度出る
setup_credit_test "$CREDIT_TMP/tier-throttle"
make_agents_yaml "$CREDIT_TMP/tier-throttle/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/tier-throttle/credit-usage.json" 62
# 1回目: warn 帯で発火
tier_output1="$(
  printf '%s' "$(payload "このバグを修正して" "sess-tier-1")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/tier-throttle/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/tier-throttle/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$tier_output1" | grep -q "Claude 週次" || fail "tierスロットル1回目で発火しない: $tier_output1"
# 同じ warn 帯の 2回目: スロットルされ無音（HITは別セッションなので三役体制は出るが残量は出ない）
tier_output2="$(
  printf '%s' "$(payload "このバグを修正して" "sess-tier-2")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/tier-throttle/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/tier-throttle/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$tier_output2" | grep -q "三役体制" || fail "tierスロットル2回目で従来文言が出ない: $tier_output2"
# 残量文言が出ていないことを確認（CREDIT_LINE は出力されないはず）
# ただし HIT=1 なので三役体制メッセージは出る。CREDIT_LINE の有無を確認。
echo "$tier_output2" | grep -q "Claude 週次" && fail "同じ帯の2回目で残量文言が出てしまう: $tier_output2" || true
# 帯を strong に上げて再度実行
make_credit_cache "$CREDIT_TMP/tier-throttle/credit-usage.json" 80
tier_output3="$(
  printf '%s' "$(payload "このバグを修正して" "sess-tier-3")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/tier-throttle/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/tier-throttle/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$tier_output3" | grep -q "⛔" || fail "帯がstrongに上がったら再通知されるべき: $tier_output3"

# 21) キャッシュが 24 時間以上古いとき、残量文言が出ない
setup_credit_test "$CREDIT_TMP/old-cache"
make_agents_yaml "$CREDIT_TMP/old-cache/agents.yaml" 55 75
# 25時間前のタイムスタンプ
old_time="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
make_credit_cache "$CREDIT_TMP/old-cache/credit-usage.json" 80 "$old_time"
old_cache_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-old-cache")" |
    CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/old-cache/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/old-cache/credit-usage.json" bash "$HOOK" 2>&1
)"
echo "$old_cache_output" | grep -q "三役体制" || fail "古いキャッシュで従来文言が出ない: $old_cache_output"
echo "$old_cache_output" | grep -q "Claude 週次" && fail "24時間以上古いキャッシュで残量文言が出てしまう: $old_cache_output" || true

# 22) codexbar を実行しないこと（偽 codexbar を PATH に置く）
FAKE_BIN="$CREDIT_TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codexbar" <<'EOF'
#!/bin/bash
echo "FAKE_CODEXBAR_CALLED=1"
exit 1
EOF
chmod +x "$FAKE_BIN/codexbar"
setup_credit_test "$CREDIT_TMP/no-exec"
make_agents_yaml "$CREDIT_TMP/no-exec/agents.yaml" 55 75
make_credit_cache "$CREDIT_TMP/no-exec/credit-usage.json" 62
no_exec_output="$(
  printf '%s' "$(payload "このバグを修正して" "sess-no-exec")" |
    PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$TMP_PROJECT" AGENTS_YAML_PATH="$CREDIT_TMP/no-exec/agents.yaml" CREDIT_CACHE_PATH="$CREDIT_TMP/no-exec/credit-usage.json" bash "$HOOK" 2>&1
)"
[ -z "$(echo "$no_exec_output" | grep "FAKE_CODEXBAR_CALLED")" ] || fail "codexbar が呼ばれている: $no_exec_output"
echo "$no_exec_output" | grep -q "Claude 週次" || fail "codexbar非実行テストで残量文言が出ない: $no_exec_output"

echo "PASS: delegation-routing-reminder"
