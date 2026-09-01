#!/usr/bin/env bash
# [2026-09-01][test] ai-worker-watch-enforce.sh の単体テスト。
# 背景:
#   - ユーザー依頼意図:
#     1) 見張り未設置ジョブの警告が出ること（1件・3件の列挙）。
#     2) 同一 job_id の重複記録が無いこと。
#     3) job_id 無し JSON・非 JSON 入力が無音 exit 0 すること（fail-open）。
#     4) 終了済み（status 非 running／.terminal 存在）と記録24時間超の掃除。
#     5) 台帳破損からの復旧・ジョブ置き場不在でも exit 0 で落ちないこと。
#     6) 見張りプロセス検知（watched: true 化・静音化）。
#     7) 並行実行で台帳記録が消失しないこと（flock 排他）。
#     8) job_id の部分一致で誤判定しないこと（完全一致）。
#   - 守るべき業務ルール:
#     1) mktemp -d で隔離し、AI_WORKER_WATCH_LEDGER / AI_WORKER_JOBS_DIR を一時パスへ
#        向ける（実マシンの ~/.cache を汚さない・依存しない）。
#     2) どのケースでも exit 0 を明示的にアサートする。
#     3) プロセス検知は実プロセスに依存しない（AI_WORKER_WATCH_PS_FILE 注入 seam。
#        実マシンの他セッション プロセスをspawn・停止・変更しない）。
#   - 他案不採用理由:
#     1) sleep を spawn した疑似 watch-worker-job.sh プロセスで判定する案 →
#        プロセス起動と生存タイミングに依存してテストが不安定化する（CI・sandbox で
#        ps が拒否される環境もある）ため不採用。実 ps 経路は hook 本体の
#        list_own_process_args() と seam で同じ処理を共有しており、seam 検証で足る。
#     2) 実環境の ~/.cache 台帳を使う案 → テストが実運用の台帳を破壊するため不採用。
# 対応: 20ケース + プロセス検知（seam）1ケース + 並行実行1ケース + 完全一致3ケース +
#       ロック失敗1ケース + ネスト探索5ケースを実装し、最後に PASS を出す。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/ai-worker-watch-enforce.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_no_block_output() {
  if printf "%s" "$1" | grep -Eq '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    fail "$2"
  fi
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-worker-watch-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export AI_WORKER_WATCH_LEDGER="$TMP_DIR/ledger.json"
export AI_WORKER_JOBS_DIR="$TMP_DIR/jobs"
STDERR_FILE="$TMP_DIR/hook-stderr.log"

reset_state() {
  rm -rf "$AI_WORKER_JOBS_DIR"
  rm -f "$AI_WORKER_WATCH_LEDGER" "$STDERR_FILE"
  mkdir -p "$AI_WORKER_JOBS_DIR"
}

make_job() { # $1=job_id $2=status
  printf '{"job_id": "%s", "status": "%s"}\n' "$1" "$2" > "$AI_WORKER_JOBS_DIR/$1.json"
}

delegate_input() { # $1=job_id
  printf '{"session_id":"test-session","tool_name":"mcp__ai-worker-mcp__delegate_impl","tool_input":{},"tool_response":{"job_id":"%s","status":"accepted"}}' "$1"
}

run_hook() { # $1=stdin text（PS_FILE_OVERRIDE があれば seam 経由で渡す）
  local input="$1"
  if [ -n "${PS_FILE_OVERRIDE:-}" ]; then
    # env(1) を介さずパイプライン内の変数前置代入で渡す（sandbox 等で env バイナリが
    # 制限される環境でも動くようにするため）。
    HOOK_STDOUT="$(printf '%s' "$input" | AI_WORKER_WATCH_PS_FILE="$PS_FILE_OVERRIDE" bash "$TARGET_SCRIPT" 2>"$STDERR_FILE")"
    HOOK_EXIT=$?
  else
    HOOK_STDOUT="$(printf '%s' "$input" | bash "$TARGET_SCRIPT" 2>"$STDERR_FILE")"
    HOOK_EXIT=$?
  fi
  assert_no_block_output "$HOOK_STDOUT" "run_hook が decision: \"block\" を返した"
}

ledger_count() { # $1=job_id → 指定 job_id のエントリ数を出力
  python3 -c "
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
    entries = doc.get('entries', [])
except Exception:
    print(0)
    sys.exit(0)
print(len([e for e in entries if e.get('job_id') == sys.argv[2]]))
" "$AI_WORKER_WATCH_LEDGER" "$1"
}

# --- Test 1: job_id を含む JSON → 台帳に記録され、未設置の警告が出る ---
JID1="11111111-1111-4111-8111-111111111111"
reset_state
make_job "$JID1" "running"
run_hook "$(delegate_input "$JID1")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 1: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 1: 未設置の警告が出ない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "$JID1" || fail "Test 1: 未設置ジョブが警告に含まれない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "watch-worker-job.sh" || fail "Test 1: 立てるべきコマンドが警告に無い: $HOOK_STDOUT"
[ "$(ledger_count "$JID1")" -eq 1 ] || fail "Test 1: 台帳に記録されていない: $(cat "$AI_WORKER_WATCH_LEDGER" 2>/dev/null)"

# --- Test 2: 同じ job_id を2回渡す → 台帳に重複しない ---
run_hook "$(delegate_input "$JID1")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 2: exit 0 にならない（exit=${HOOK_EXIT}）"
[ "$(ledger_count "$JID1")" -eq 1 ] || fail "Test 2: 台帳に同一ジョブが重複している: $(cat "$AI_WORKER_WATCH_LEDGER")"

# --- Test 3: job_id を含まない JSON → 何も出力せず exit 0 ---
run_hook '{"session_id":"test-session","tool_name":"Read","tool_input":{"file_path":"/tmp/x"},"tool_response":{"content":"ok"}}'
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 3: exit 0 にならない（exit=${HOOK_EXIT}）"
[ -z "$HOOK_STDOUT" ] || fail "Test 3: job_id 無しでは無音であるべき: $HOOK_STDOUT"

# --- Test 4: JSON でない文字列 → 何も出力せず exit 0 ---
run_hook 'this is not json {{{'
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 4: exit 0 にならない（exit=${HOOK_EXIT}）"
[ -z "$HOOK_STDOUT" ] || fail "Test 4: 非 JSON 入力では無音であるべき: $HOOK_STDOUT"

# --- Test 5: 台帳にあるジョブの status が succeeded → 警告に出ず台帳から除かれる ---
JID2="22222222-2222-4222-8222-222222222222"
JID3="33333333-3333-4333-8333-333333333333"
reset_state
make_job "$JID2" "running"
run_hook "$(delegate_input "$JID2")"
make_job "$JID2" "succeeded"
make_job "$JID3" "running"
run_hook "$(delegate_input "$JID3")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 5: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "$JID2" && fail "Test 5: 終了済みジョブが警告に出ている: $HOOK_STDOUT" || true
echo "$HOOK_STDOUT" | grep -q "$JID3" || fail "Test 5: 実行中ジョブが警告に出ない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 5: 警告の件数が1件になっていない: $HOOK_STDOUT"
[ "$(ledger_count "$JID2")" -eq 0 ] || fail "Test 5: 終了済みジョブが台帳に残っている: $(cat "$AI_WORKER_WATCH_LEDGER")"

# --- Test 6: <job_id>.terminal が存在 → 警告に出ず台帳から除かれる ---
JID4="44444444-4444-4444-8444-444444444444"
JID5="55555555-5555-4555-8555-555555555555"
reset_state
make_job "$JID4" "running"
run_hook "$(delegate_input "$JID4")"
: > "$AI_WORKER_JOBS_DIR/$JID4.terminal"
make_job "$JID5" "running"
run_hook "$(delegate_input "$JID5")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 6: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "$JID4" && fail "Test 6: .terminal 済みジョブが警告に出ている: $HOOK_STDOUT" || true
echo "$HOOK_STDOUT" | grep -q "$JID5" || fail "Test 6: 実行中ジョブが警告に出ない: $HOOK_STDOUT"
[ "$(ledger_count "$JID4")" -eq 0 ] || fail "Test 6: .terminal 済みジョブが台帳に残っている: $(cat "$AI_WORKER_WATCH_LEDGER")"

# --- Test 7: 記録から25時間経過したエントリ → 台帳から消える ---
JID_OLD="66666666-6666-4666-8666-666666666666"
JID_NEW="77777777-7777-4777-8777-777777777777"
reset_state
make_job "$JID_OLD" "running"
run_hook "$(delegate_input "$JID_OLD")"
python3 - "$AI_WORKER_WATCH_LEDGER" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
doc = json.load(open(path))
for e in doc["entries"]:
    e["recorded_at"] = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
json.dump(doc, open(path, "w"))
PY
make_job "$JID_NEW" "running"
run_hook "$(delegate_input "$JID_NEW")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 7: exit 0 にならない（exit=${HOOK_EXIT}）"
[ "$(ledger_count "$JID_OLD")" -eq 0 ] || fail "Test 7: 25時間経過エントリが台帳に残っている: $(cat "$AI_WORKER_WATCH_LEDGER")"
[ "$(ledger_count "$JID_NEW")" -eq 1 ] || fail "Test 7: 新規ジョブが台帳に記録されていない: $(cat "$AI_WORKER_WATCH_LEDGER")"
echo "$HOOK_STDOUT" | grep -q "$JID_OLD" && fail "Test 7: 期限切れジョブが警告に出ている: $HOOK_STDOUT" || true

# --- Test 8: 未設置が3件ある → 3件すべてが警告に列挙される ---
JA="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
JB="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
JC="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
reset_state
make_job "$JA" "running"
make_job "$JB" "running"
make_job "$JC" "running"
run_hook "$(delegate_input "$JA")"
run_hook "$(delegate_input "$JB")"
run_hook "$(delegate_input "$JC")"
run_hook "$(delegate_input "$JA")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 8: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（3件）" || fail "Test 8: 3件と数えられていない: $HOOK_STDOUT"
for j in "$JA" "$JB" "$JC"; do
  echo "$HOOK_STDOUT" | grep -q "$j" || fail "Test 8: $j が警告に列挙されていない: $HOOK_STDOUT"
done

# --- Test 9: 台帳ファイルが壊れた JSON → exit 0 で復旧し、落ちない ---
JID9="99999999-9999-4999-8999-999999999999"
reset_state
printf 'broken ledger {{{' > "$AI_WORKER_WATCH_LEDGER"
make_job "$JID9" "running"
run_hook "$(delegate_input "$JID9")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 9: 台帳破損時に exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "$JID9" || fail "Test 9: 台帳復旧後の警告に出ない: $HOOK_STDOUT"
grep -q "台帳が壊れている" "$STDERR_FILE" || fail "Test 9: 台帳破損の警告が出ていない: $(cat "$STDERR_FILE" 2>/dev/null)"
[ "$(ledger_count "$JID9")" -eq 1 ] || fail "Test 9: 台帳が復旧されていない: $(cat "$AI_WORKER_WATCH_LEDGER")"

# --- Test 10: ジョブ置き場が存在しない → 台帳の記録だけで判定し exit 0 ---
JID10="10101010-1010-4101-8101-101010101010"
reset_state
rm -rf "$AI_WORKER_JOBS_DIR"
run_hook "$(delegate_input "$JID10")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 10: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "$JID10" || fail "Test 10: ジョブ置き場不在時に台帳のみで警告を出せていない: $HOOK_STDOUT"

# --- Test 11: どの入力経路でも exit 0 であること（明示的最終確認） ---
while IFS= read -r input_case; do
  run_hook "$input_case"
  [ "$HOOK_EXIT" -eq 0 ] || fail "Test 11: exit 0 にならない入力がある（exit=${HOOK_EXIT}）: ${input_case:0:80}"
done <<'CASES'
{"session_id":"test-session","tool_name":"mcp__ai-worker-mcp__delegate_impl","tool_response":{"job_id":"efefefef-efef-4efe-8efe-efefefefefef","status":"accepted"}}
{"tool_name":"Read","tool_response":{}}
not json at all
{"job_id":"../path/traversal-attempt"}
CASES
run_hook ""
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 11: 空入力で exit 0 にならない（exit=${HOOK_EXIT}）"

# --- Test 12: 見張りプロセス検知（AI_WORKER_WATCH_PS_FILE seam）→
#     watched: true に更新され、警告を出さない（他ジョブは警告に出る） ---
JID12="12121212-1212-4121-8121-121212121212"
JID13="13131313-1313-4131-8131-131313131313"
reset_state
make_job "$JID12" "running"
make_job "$JID13" "running"
PS_FILE_OVERRIDE="$TMP_DIR/ps.txt"
{
  printf '  /bin/bash /Users/tester/business/AGENT-HUB/scripts/watch-worker-job.sh %s 1800\n' "$JID12"
  printf '  /bin/bash /Users/tester/business/AGENT-HUB/scripts/watch-worker-job.sh 00000000-0000-4000-8000-000000000000 1800\n'
} > "$PS_FILE_OVERRIDE"
run_hook "$(delegate_input "$JID12")"
run_hook "$(delegate_input "$JID13")"
unset PS_FILE_OVERRIDE
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 12: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "$JID12" && fail "Test 12: 見張りプロセスが見つかっているのに警告に出ている: $HOOK_STDOUT" || true
echo "$HOOK_STDOUT" | grep -q "$JID13" || fail "Test 12: 見張り無しジョブが警告に出ない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 12: 警告の件数が1件になっていない: $HOOK_STDOUT"
python3 -c "
import json, sys
doc = json.load(open(sys.argv[1]))
target = [e for e in doc['entries'] if e['job_id'] == sys.argv[2]]
assert len(target) == 1, 'ledger entry missing'
assert target[0].get('watched') is True, 'watched not updated: %s' % target[0]
" "$AI_WORKER_WATCH_LEDGER" "$JID12" || fail "Test 12: watched が true に更新されていない: $(cat "$AI_WORKER_WATCH_LEDGER")"

# --- Test 13: 台帳ファイルが存在しない → 台帳再作成でも壊れ警告は出ない（未設置は出る）
JID13="10101010-1010-4101-8101-101010101013"
reset_state
rm -f "$AI_WORKER_WATCH_LEDGER"
run_hook "$(delegate_input "$JID13")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 13: 台帳なしで exit 0 にならない（exit=$HOOK_EXIT）"
echo "$HOOK_STDOUT" | grep -q "$JID13" || fail "Test 13: 台帳なしケースで未設置ジョブが警告に出ない: $HOOK_STDOUT"
if grep -q "台帳が壊れている" "$STDERR_FILE"; then
  fail "Test 13: 台帳なしで壊れ警告が出た: $(cat "$STDERR_FILE" 2>/dev/null)"
fi

# --- Test 14: 空の台帳ファイル（0バイト）でも壊れ警告は出ない
JID14="10101010-1010-4101-8101-101010101014"
reset_state
touch "$AI_WORKER_WATCH_LEDGER"
run_hook "$(delegate_input "$JID14")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 14: 空台帳で exit 0 にならない（exit=$HOOK_EXIT）"
echo "$HOOK_STDOUT" | grep -q "$JID14" || fail "Test 14: 空台帳ケースで未設置ジョブが警告に出ない: $HOOK_STDOUT"
if grep -q "台帳が壊れている" "$STDERR_FILE"; then
  fail "Test 14: 空台帳で壊れ警告が出た: $(cat "$STDERR_FILE" 2>/dev/null)"
fi

# --- Test 15: 中身のある壊れた JSON は壊れ警告が stderr のみで出る
JID15="10101010-1010-4101-8101-101010101015"
reset_state
printf 'broken ledger {{{' > "$AI_WORKER_WATCH_LEDGER"
run_hook "$(delegate_input "$JID15")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 15: 破損台帳で exit 0 にならない（exit=$HOOK_EXIT）"
echo "$HOOK_STDOUT" | grep -q "$JID15" || fail "Test 15: 破損台帳の警告が出ない: $HOOK_STDOUT"
if ! grep -q "台帳が壊れている" "$STDERR_FILE"; then
  fail "Test 15: 破損台帳で壊れ警告が出ない: $(cat "$STDERR_FILE" 2>/dev/null)"
fi

# --- Test 16: 並行実行 → 同じ台帳に複数プロセスから別々の job_id を投入し、全て残る ---
reset_state
JID16A="16161616-1616-4161-8161-161616161616"
JID16B="16161616-1616-4161-8161-161616161617"
JID16C="16161616-1616-4161-8161-161616161618"
make_job "$JID16A" "running"
make_job "$JID16B" "running"
make_job "$JID16C" "running"
# 3プロセスをバックグラウンドで同時起動
export AI_WORKER_WATCH_LEDGER
export AI_WORKER_JOBS_DIR
for j in "$JID16A" "$JID16B" "$JID16C"; do
  printf '%s' "$(delegate_input "$j")" | bash "$TARGET_SCRIPT" >/dev/null 2>&1 &
done
wait
for j in "$JID16A" "$JID16B" "$JID16C"; do
  cnt="$(ledger_count "$j")"
  [ "$cnt" -eq 1 ] || fail "Test 16: 並行実行後 $j の台帳エントリが $cnt 件（期待 1）"
done

# --- Test 17: 包含関係の誤判定 → job-a-old だけが見張りにある状態で job-a は未設置として警告 ---
reset_state
JID17="job-a"
make_job "$JID17" "running"
PS_FILE_OVERRIDE="$TMP_DIR/ps17.txt"
{
  printf '/bin/bash /Users/tester/scripts/watch-worker-job.sh job-a-old 1800\n'
} > "$PS_FILE_OVERRIDE"
run_hook "$(delegate_input "$JID17")"
unset PS_FILE_OVERRIDE
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 17: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 17: job-a が未設置として警告されない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "job-a" || fail "Test 17: job-a が警告に含まれない: $HOOK_STDOUT"

# --- Test 18: 完全一致 → watch-worker-job.sh job-a がある → job-a は警告されない ---
reset_state
JID18="job-a"
make_job "$JID18" "running"
PS_FILE_OVERRIDE="$TMP_DIR/ps18.txt"
{
  printf '/bin/bash /Users/tester/scripts/watch-worker-job.sh job-a 1800\n'
} > "$PS_FILE_OVERRIDE"
run_hook "$(delegate_input "$JID18")"
unset PS_FILE_OVERRIDE
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 18: exit 0 にならない（exit=${HOOK_EXIT}）"
[ -z "$HOOK_STDOUT" ] || fail "Test 18: 完全一致で見張り有りなのに警告が出ている: $HOOK_STDOUT"

# --- Test 19: 偶然の混入 → 別プロセス引数に job_id が含まれるが watch-worker-job.sh の直後ではない ---
reset_state
JID19="job-a"
make_job "$JID19" "running"
PS_FILE_OVERRIDE="$TMP_DIR/ps19.txt"
{
  printf '/usr/bin/python3 /some/other/script.py job-a --watch\n'
} > "$PS_FILE_OVERRIDE"
run_hook "$(delegate_input "$JID19")"
unset PS_FILE_OVERRIDE
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 19: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 19: 偶然混入で job-a が未設置として警告されない: $HOOK_STDOUT"

# --- Test 20: ロック取得失敗 → 別プロセスが flock(LOCK_EX) を取得したままにして hook を実行 ---
reset_state
JID20="20202020-2020-4202-8202-202020202020"
make_job "$JID20" "running"
LOCK_FILE="$AI_WORKER_WATCH_LEDGER.lock"
# 別プロセスでロックを取得したままにする
# [2026-09-01][fix] ロック保持を stdin 依存から時間指定へ変える。
# 背景: 以前は sys.stdin.read() で待たせていたが、テストを非対話で実行すると stdin が即 EOF となり
#   保持プロセスが即終了してロックが外れていた。hook 側がロック取得を短時間で諦める実装だった間は
#   偶然この経路を通っていたが、期限つき再試行（3秒）へ変えた時点で hook がロックを取得できてしまい、
#   「ロックが取れない」経路を検証できなくなった（2026-09-01 実測）。
# 他案不採用理由: hook 側の待機時間を縮めてテストを通す案は、並行実行での記録取りこぼしを再発させる
#   ため不採用。テスト側でロックを確実に保持する。
python3 -c "
import fcntl, sys, time
lock_path = sys.argv[1]
hold_seconds = float(sys.argv[2])
with open(lock_path, 'w') as f:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    # hook の待機期限（3秒）より確実に長く保持する。stdin に依存しない。
    time.sleep(hold_seconds)
" "$LOCK_FILE" 10 &
LOCK_PID=$!
sleep 0.2
run_hook "$(delegate_input "$JID20")"
kill "$LOCK_PID" 2>/dev/null || true
wait "$LOCK_PID" 2>/dev/null || true
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 20: ロック失敗時に exit 0 にならない（exit=${HOOK_EXIT}）"
assert_no_block_output "$HOOK_STDOUT" "Test 20: ロック失敗時に decision:block を返した"
grep -q "ロックが取れない" "$STDERR_FILE" || fail "Test 20: ロック取得失敗の指摘が stderr に無い: $(cat "$STDERR_FILE" 2>/dev/null)"

# --- Test 21: ネストした tool_response から job_id を取得できる ---
JID21="21212121-2121-4121-8121-212121212121"
reset_state
make_job "$JID21" "running"
run_hook "{\"session_id\":\"test-session\",\"tool_name\":\"mcp__ai-worker-mcp__delegate_impl\",\"tool_input\":{},\"tool_response\":{\"result\":{\"data\":{\"job_id\":\"${JID21}\",\"status\":\"accepted\"}}}}"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 21: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 21: ネストした応答からの警告が出ない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "$JID21" || fail "Test 21: ネストした job_id が警告に含まれない: $HOOK_STDOUT"
[ "$(ledger_count "$JID21")" -eq 1 ] || fail "Test 21: ネストした応答の job_id が台帳に記録されていない: $(cat "$AI_WORKER_WATCH_LEDGER" 2>/dev/null)"

# --- Test 22: リストを挟んだ形でも job_id を取得できる ---
JID22="22222222-2222-4222-8222-222222222222"
reset_state
make_job "$JID22" "running"
run_hook "{\"session_id\":\"test-session\",\"tool_name\":\"mcp__ai-worker-mcp__delegate_impl\",\"tool_input\":{},\"tool_response\":{\"items\":[{\"job_id\":\"${JID22}\",\"status\":\"accepted\"}]}}"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 22: exit 0 にならない（exit=${HOOK_EXIT}）"
echo "$HOOK_STDOUT" | grep -q "見張りが未設置です（1件）" || fail "Test 22: リスト経由の警告が出ない: $HOOK_STDOUT"
echo "$HOOK_STDOUT" | grep -q "$JID22" || fail "Test 22: リスト経由の job_id が警告に含まれない: $HOOK_STDOUT"
[ "$(ledger_count "$JID22")" -eq 1 ] || fail "Test 22: リスト経由の job_id が台帳に記録されていない: $(cat "$AI_WORKER_WATCH_LEDGER" 2>/dev/null)"

# --- Test 23: ネストした位置に不正な形式の job_id しか無い → 採用せず exit 0 ---
reset_state
run_hook "{\"session_id\":\"test-session\",\"tool_name\":\"mcp__ai-worker-mcp__delegate_impl\",\"tool_input\":{},\"tool_response\":{\"result\":{\"data\":{\"job_id\":\"../../../etc/passwd\",\"status\":\"accepted\"}}}}"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 23: exit 0 にならない（exit=${HOOK_EXIT}）"
[ -z "$HOOK_STDOUT" ] || fail "Test 23: 不正形式の job_id で無音であるべき: $HOOK_STDOUT"

# --- Test 24: tool_input のネスト位置に job_id があり tool_response に無い → 採用しない ---
JID24="24242424-2424-4242-8242-242424242424"
reset_state
make_job "$JID24" "running"
run_hook "{\"session_id\":\"test-session\",\"tool_name\":\"mcp__ai-worker-mcp__delegate_impl\",\"tool_input\":{\"nested\":{\"job_id\":\"${JID24}\"}},\"tool_response\":{\"status\":\"accepted\"}}"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 24: exit 0 にならない（exit=${HOOK_EXIT}）"
[ -z "$HOOK_STDOUT" ] || fail "Test 24: tool_input の job_id を拾ってはいけない: $HOOK_STDOUT"
[ "$(ledger_count "$JID24")" -eq 0 ] || fail "Test 24: tool_input の job_id が台帳に記録されている: $(cat "$AI_WORKER_WATCH_LEDGER" 2>/dev/null)"

# --- Test 25: ネスト探索経路でも exit 0 かつ decision:block を返さない ---
JID25="25252525-2525-4252-8252-252525252525"
reset_state
make_job "$JID25" "running"
run_hook "{\"session_id\":\"test-session\",\"tool_name\":\"mcp__ai-worker-mcp__delegate_impl\",\"tool_input\":{},\"tool_response\":{\"result\":{\"data\":{\"job_id\":\"${JID25}\",\"status\":\"accepted\"}}}}"
assert_no_block_output "$HOOK_STDOUT" "Test 25: ネスト探索で decision:block を返した"

# --- Test 26: 出力契約を明示する（decision は必ず approve・reason に指摘本文） ---
# [2026-09-01][test] Codexレビュー指摘: 実装は decision:"approve" を返すのに CaD は
# 「decision/block と同型」と書いており、契約がテストで固定されていなかった。
# 「block でない」だけでなく「approve である」ことを明示して固定する。
reset_state
JID26="26262626-2626-4262-8262-262626262626"
make_job "${JID26}" "running"
run_hook "$(delegate_input "${JID26}")"
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 26: exit 0 にならない（exit=${HOOK_EXIT}）"
printf "%s" "$HOOK_STDOUT" | grep -Eq '"decision"[[:space:]]*:[[:space:]]*"approve"' \
  || fail "Test 26: decision が approve になっていない: $HOOK_STDOUT"
printf "%s" "$HOOK_STDOUT" | grep -q '"reason"' \
  || fail "Test 26: reason が出ていない: $HOOK_STDOUT"
printf "%s" "$HOOK_STDOUT" | grep -q "見張りが未設置です" \
  || fail "Test 26: reason に指摘本文が入っていない: $HOOK_STDOUT"

# --- Test 27: 見張り起動コマンドのパスが AGENT_HUB_ROOT で解決される ---
# [2026-09-01][test] Codexレビュー指摘: 案内パスが ~/business/AGENT-HUB 固定だと、
# AGENT-HUB の配置が違う環境で案内どおりに実行できない。env で上書きできることを固定する。
reset_state
JID27="27272727-2727-4272-8272-272727272727"
make_job "${JID27}" "running"
CUSTOM_ROOT="${TMP_DIR}/custom-agent-hub"
HOOK_STDOUT="$(printf '%s' "$(delegate_input "${JID27}")" | AGENT_HUB_ROOT="${CUSTOM_ROOT}" bash "$TARGET_SCRIPT" 2>"$STDERR_FILE")"
HOOK_EXIT=$?
[ "$HOOK_EXIT" -eq 0 ] || fail "Test 27: exit 0 にならない（exit=${HOOK_EXIT}）"
printf "%s" "$HOOK_STDOUT" | grep -q "${CUSTOM_ROOT}/scripts/watch-worker-job.sh" \
  || fail "Test 27: AGENT_HUB_ROOT が案内パスへ反映されていない: $HOOK_STDOUT"

echo "PASS: ai-worker-watch-enforce"
exit 0
