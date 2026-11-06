#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/gbrain-recall-preflight.sh"

# [2026-10-04][fix] grep -q の早期終了で echo が SIGPIPE にならないよう、
# here-string で出力を渡す。案内文が長くなっても誤検知で回帰を止めない。
# 他案不採用: pipefail の無効化は本当のパイプ失敗まで見逃すため採らない。

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_hook() {
  local prompt="$1"
  printf '{"user_prompt": "%s"}' "$prompt" | bash "$HOOK"
}

# [2026-10-30][feat] 現在日時の1行は発火語に関係なく毎回出る。それ以外（preflight 本体）は無音のまま。
NOW_LINE_RE='^現在日時: [0-9]{4}-[0-9]{2}-[0-9]{2}（(月|火|水|木|金|土|日)）[0-9]{2}:[0-9]{2} JST'
only_now_line() {
  # 現在日時の1行だけで、preflight 本体が出ていないことを確かめる
  local out="$1"
  [ "$(wc -l <<< "$out" | tr -d ' ')" = "1" ] || return 1
  grep -qE "$NOW_LINE_RE" <<< "$out" || return 1
  ! grep -q "gbrain-recall preflight:" <<< "$out"
}

normal_output="$(run_hook "今日は天気だけ確認")"
only_now_line "$normal_output" || fail "通常プロンプトは現在日時の1行だけであるべき: $normal_output"

# 日付と曜日が date コマンドの値と一致する（日本語曜日は %u から）
expected_wd="$(TZ=Asia/Tokyo LC_ALL=C date +%u)"
expected_date="$(TZ=Asia/Tokyo LC_ALL=C date +%Y-%m-%d)"
case "$expected_wd" in 1) wd=月;; 2) wd=火;; 3) wd=水;; 4) wd=木;; 5) wd=金;; 6) wd=土;; 7) wd=日;; esac
grep -q "現在日時: ${expected_date}（${wd}）" <<< "$normal_output" \
  || fail "現在日時が date の値と合わない（期待 ${expected_date}（${wd}））: $normal_output"

fix_both_output="$(run_hook "修正して")"
grep -qE "$NOW_LINE_RE" <<< "$fix_both_output" || fail "発火語ありでも現在日時の1行が出る: $fix_both_output"
grep -q "My GBrainでsource shintaro-gbrain と tech-gbrain-shared の両方を検索してから着手" <<< "$fix_both_output" \
  || fail "修正プロンプトで両方の案内が出ない: $fix_both_output"

think_both_output="$(run_hook "どう思う？")"
grep -q "My GBrainでsource shintaro-gbrain と tech-gbrain-shared の両方を検索してから着手" <<< "$think_both_output" \
  || fail "どう思うプロンプトで両方の案内が出ない: $think_both_output"

bug_output="$(run_hook "このAPIのバグを直して")"
grep -q "My GBrainでsource shintaro-gbrain と tech-gbrain-shared の両方を検索してから着手" <<< "$bug_output" \
  || fail "直してを含むバグ修正プロンプトで両方の案内が出ない: $bug_output"

business_output="$(run_hook "この施策について相談したい")"
grep -q "My GBrainでsource shintaro-gbrain と tech-gbrain-shared の両方を検索してから着手" <<< "$business_output" \
  || fail "相談プロンプトで両方の案内が出ない: $business_output"

tech_only_output="$(run_hook "なぜこのエラーが出るか調べて")"
grep -q "My GBrainでsource tech-gbrain-shared を検索してから着手" <<< "$tech_only_output" \
  || fail "純粋な障害調査プロンプトで tech-gbrain 案内が出ない: $tech_only_output"
grep -q "両方を検索" <<< "$tech_only_output" \
  && fail "純粋な障害調査プロンプトで両方案内が出てはいけない: $tech_only_output"

force_output="$(printf '{"user_prompt": "ただの雑談"}' | GBRAIN_RECALL_PREFLIGHT_FORCE=1 bash "$HOOK")"
grep -q "gbrain-recall preflight:" <<< "$force_output" || fail "FORCE時の preflight が出ない: $force_output"
grep -q "該当キーワードなし" <<< "$force_output" || fail "FORCE時に無該当メッセージが出ない: $force_output"

for status in AVAILABLE NOT_SELECTED RUNTIME_UNAVAILABLE UNPROVEN; do
  grep -q "$status" <<< "$fix_both_output" \
    || fail "availability status $status の案内が出ない: $fix_both_output"
done
grep -q "catalog 探索・MCP tool 呼出しは自動実行しない" <<< "$fix_both_output" \
  || fail "hookが自動探索・自動呼出しをしない案内を出さない: $fix_both_output"
grep -q "tool-availability-resolution.md" <<< "$fix_both_output" \
  || fail "共通availability ruleへの参照が出ない: $fix_both_output"

# --- [2026-09-26][feat] 出パンダ区分・権限リマインダー（独立 policy） ---------------------

depanda_hit_output="$(run_hook "リーダーだけが使える権限にしたい")"
grep -q "区分・権限の正本は出パンダ。スキル depanda-staff-roles を読んでから進める。" <<< "$depanda_hit_output" \
  || fail "区分・権限プロンプトで depanda-staff-roles 案内が出ない: $depanda_hit_output"

depanda_nohit_output="$(run_hook "今日は天気だけ確認")"
only_now_line "$depanda_nohit_output" \
  || fail "無関係なプロンプトで depanda-staff-roles 案内が出てはいけない: $depanda_nohit_output"

depanda_missing_json_output="$(DEPANDA_ROLES_POLICY_PATH=/tmp/does-not-exist-depanda-roles-policy.json run_hook "権限を変えたい")"
only_now_line "$depanda_missing_json_output" \
  || fail "depanda-roles-policy.json が無い時は無言で終わるべき: $depanda_missing_json_output"

grep -q "depanda-staff-roles" <<< "$fix_both_output" \
  && fail "既存の相談・判断プロンプトで depanda-staff-roles 案内が意図せず出ている: $fix_both_output"

# --- [2026-11-02][feat] 説明の依頼の案内（独立 policy） ----------------------------------

EXPLAIN_MSG_RE="説明の依頼: 先に My GBrain『分かりやすいのレパートリー』を読む"

explain_hit_output="$(run_hook "やった内容をわかりやすくビフォーアフターで教えて")"
grep -q "$EXPLAIN_MSG_RE" <<< "$explain_hit_output" \
  || fail "説明の依頼プロンプトで説明の案内が出ない: $explain_hit_output"

explain_plain_output="$(run_hook "これを分かりやすくまとめて")"
grep -q "$EXPLAIN_MSG_RE" <<< "$explain_plain_output" \
  || fail "「分かりやすく」だけの依頼で説明の案内が出ない: $explain_plain_output"

explain_nohit_output="$(run_hook "今日の天気を教えて")"
only_now_line "$explain_nohit_output" \
  || fail "「教えて」だけの依頼で説明の案内が出てはいけない: $explain_nohit_output"

explain_missing_json_output="$(EXPLAIN_VISUAL_POLICY_PATH=/tmp/does-not-exist-explain-visual-policy.json run_hook "分かりやすく説明して修正して")"
grep -q "$EXPLAIN_MSG_RE" <<< "$explain_missing_json_output" \
  && fail "explain-visual-policy.json が無い時に説明の案内が出てはいけない: $explain_missing_json_output"
grep -q "My GBrainでsource shintaro-gbrain と tech-gbrain-shared の両方を検索してから着手" <<< "$explain_missing_json_output" \
  || fail "台帳が無い時も既存の相談・判断の案内は変わってはいけない: $explain_missing_json_output"

grep -q "$EXPLAIN_MSG_RE" <<< "$fix_both_output" \
  && fail "既存の相談・判断プロンプトで説明の案内が意図せず出ている: $fix_both_output"

echo "PASS: gbrain-recall-preflight"
