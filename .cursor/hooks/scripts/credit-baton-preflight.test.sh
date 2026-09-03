#!/usr/bin/env bash
set -euo pipefail

# [2026-08-27][test] credit-baton-preflight.sh の単体・統合テスト。
# 背景:
#   - ユーザー依頼意図:
#     1) credit-usage-cache.test.sh と credit-baton-preflight.test.sh を本ファイルを唯一の
#        エントリポイントとして 1 コマンドで実行する。
#     2) キャッシュ無し・壊れたJSONでの無音 exit 0。
#     3) Claude週次の warn未満（委譲文言なし）/ warn以上（通常委譲文言）/ strong以上（強い委譲文言）。
#     4) codexbar を同期実行せず、偽codexbarが5秒眠っても1秒以内に exit 0 することの検証。
#   - 守るべき業務ルール:
#     mktemp -d で隔離環境を作成し、実環境 ~/.cache や agents.yaml を汚染しない。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/credit-baton-preflight.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Step 1: Run credit-usage-cache.test.sh first ---
echo "=== Running credit-usage-cache.test.sh ==="
bash "$SCRIPT_DIR/credit-usage-cache.test.sh"
echo ""

echo "=== Running credit-baton-preflight.test.sh ==="

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/credit-preflight-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_BIN_DIR"
export PATH="$STUB_BIN_DIR:$PATH"

TEST_AGENTS_YAML="$TMP_DIR/agents.yaml"
cat > "$TEST_AGENTS_YAML" <<'YAML'
worker_delegation:
  credit_preflight:
    as_of: "2026-08-27"
    cache_path: "~/.cache/agent-hub/credit-usage.json"
    cache_ttl_seconds: 900
    display_routes: ["claude", "glm", "antigravity", "kimi", "codex", "cursor", "ocg"]
    claude_weekly_warn_percent: 55
    claude_weekly_strong_percent: 75
    rule: "セッション開始時と委譲判定時に読む。hook は codexbar を同期実行せず、キャッシュを読むだけにする。取得不能でも作業は止めない（非ブロック）"
YAML

export AGENTS_YAML_PATH="$TEST_AGENTS_YAML"
export CLAUDE_PROJECT_DIR="$TMP_DIR"
TEST_CACHE_FILE="$TMP_DIR/cache/credit-usage.json"
export CREDIT_USAGE_CACHE_FILE="$TEST_CACHE_FILE"
mkdir -p "$(dirname "$TEST_CACHE_FILE")"

# [2026-09-01][test] 日次基準点ファイルを実 ~/.cache へ書かせない
# 背景: credit-baton-preflight.sh は delegation-reminder-cache.sh の
# resolve_delegation_reminder_cache_dir() を read-only で使い、日次基準点ファイル
# （daily-baseline-<date>.txt）の置き場を決める。DELEGATION_REMINDER_CACHE_DIR を
# 明示しないと実環境の XDG cache 配下にディレクトリが作られてしまうため、
# delegation-routing-reminder.test.sh と同じ方式でテスト専用ディレクトリへ固定する。
export DELEGATION_REMINDER_CACHE_DIR="$TMP_DIR/daily-baseline-cache"
mkdir -p "$DELEGATION_REMINDER_CACHE_DIR"

# --- Test 1: キャッシュが無いとき exit 0 かつ何も表示しないこと ---
rm -f "$TEST_CACHE_FILE"
out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 1: キャッシュ不在時に exit 0 にならない（exit=$exit_code）"
[ -z "$out" ] || fail "Test 1: キャッシュ不在時は無音であるべき: $out"

# --- Test 2: キャッシュが壊れた JSON のとき exit 0 かつ何も表示しないこと ---
printf 'broken json {{{' > "$TEST_CACHE_FILE"
out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 2: 破損JSON時に exit 0 にならない（exit=$exit_code）"
[ -z "$out" ] || fail "Test 2: 破損JSON時は無音であるべき: $out"

# --- Test 3: Claude 週次が warn 閾値未満のとき委譲メッセージを出さないこと ---
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 50, "session": 10, "weekly": 50, "willLastToReset": true},
    "glm": {"usedPercent": 2},
    "antigravity": {"usedPercent": 0},
    "kimi": {"usedPercent": 21},
    "codex": {"usedPercent": 70}
  }
}
JSON

out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 3: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "Claude 週次" || fail "Test 3: Claude 週次表示が無い: $out"
echo "$out" | grep -q "50%" || fail "Test 3: 50% 表示が無い: $out"
# [2026-09-03][fix] Codex 表示名を "Codex(GPT)" へ変更（PR2407 GPT/Spark分離に追従）
echo "$out" | grep -q "GLM 2% / Gemini 0% / Kimi 21% / Codex(GPT) 70%" || fail "Test 3: worker 表示が無い: $out"
if echo "$out" | grep -q "委譲"; then
  fail "Test 3: warn閾値未満なのに委譲メッセージが表示されている: $out"
fi
if echo "$out" | grep -q "⚠"; then
  fail "Test 3: warn閾値未満かつ willLastToReset=true なのに ⚠ が表示されている: $out"
fi

# --- Test 3-bis: Claude 週次が warn 閾値以上 (62%) のとき通常委譲メッセージを出すこと ---
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 62, "session": 16, "weekly": 62, "willLastToReset": false},
    "glm": {"usedPercent": 2},
    "antigravity": {"usedPercent": 0},
    "kimi": {"usedPercent": 21},
    "codex": {"usedPercent": 70}
  }
}
JSON

out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 3-bis: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "Claude 週次" || fail "Test 3-bis: Claude 週次表示が無い: $out"
echo "$out" | grep -q "62%" || fail "Test 3-bis: 62% 表示が無い: $out"
echo "$out" | grep -q "⚠ 尽きる見込み" || fail "Test 3-bis: ⚠ 尽きる見込み が無い: $out"
echo "$out" | grep -q "→ 実装は AI worker へ委譲してください" || fail "Test 3-bis: 委譲メッセージが無い: $out"

# --- Test 4: Claude 週次が strong 閾値以上 (80%) のとき強い委譲メッセージを出すこと ---
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 80, "session": 20, "weekly": 80, "willLastToReset": false},
    "glm": {"usedPercent": 2},
    "antigravity": {"usedPercent": 0},
    "kimi": {"usedPercent": 21},
    "codex": {"usedPercent": 70}
  }
}
JSON

out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 4: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "⛔ Claude 直実装をやめ、AI worker へ委譲してください" || fail "Test 4: 強い委譲メッセージが無い: $out"

# --- Test 5: codexbar を同期実行しないこと（偽codexbarが5秒眠っても1秒以内に exit 0 すること） ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
sleep 5
exit 1
EOF
chmod +x "$STUB_BIN_DIR/codexbar"

export CODEXBAR_BIN="$STUB_BIN_DIR/codexbar"

# キャッシュを未存在（または期限切れ）にし、バックグラウンド更新をトリガーさせる
rm -f "$TEST_CACHE_FILE"

start_time="$(python3 -c 'import time; print(time.time())')"
out="$(bash "$TARGET_SCRIPT")"
exit_code=$?
end_time="$(python3 -c 'import time; print(time.time())')"

duration="$(python3 -c "print($end_time - $start_time)")"
is_fast="$(python3 -c "print(1 if float($duration) < 1.5 else 0)")"

[ "$exit_code" -eq 0 ] || fail "Test 5: exit 0 にならない（exit=$exit_code）"
[ "$is_fast" -eq 1 ] || fail "Test 5: hook が同期ブロックしている（所要時間: ${duration}s, 期待値: < 1.5s）"

# ===== [2026-09-01] 日次/pace 節約モード自動宣言 + 鮮度表示強化テスト =====
unset CODEXBAR_BIN

TEST_AGENTS_YAML_DAILY="$TMP_DIR/agents-daily.yaml"
cat > "$TEST_AGENTS_YAML_DAILY" <<'YAML'
worker_delegation:
  credit_preflight:
    as_of: "2026-08-27"
    cache_path: "~/.cache/agent-hub/credit-usage.json"
    cache_ttl_seconds: 900
    display_routes: ["claude", "glm", "antigravity", "kimi", "codex", "cursor", "ocg"]
    claude_weekly_warn_percent: 55
    claude_weekly_strong_percent: 75
    claude_daily_warn_percent: 12
    claude_daily_strong_percent: 15
    claude_pace_delta_warn_points: 10
    claude_pace_delta_strong_points: 20
    claude_pace_exhaustion_is_strong: true
YAML

# --- Test 6: 日次基準点確立(1回目)では節約モードを宣言しない ---
rm -rf "${DELEGATION_REMINDER_CACHE_DIR:?}"/daily-baseline-* 2>/dev/null || true
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 20, "session": 5, "weekly": 20, "willLastToReset": true, "deltaPercent": 2, "expectedUsedPercent": 18},
    "glm": {"usedPercent": 2}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 6: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "節約モード" && fail "Test 6: 基準点確立1回目で節約モードが出てしまう: $out" || true

# --- Test 7: 基準点=20のまま週次33%（本日約13%）で節約モードを自動宣言する ---
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 33, "session": 8, "weekly": 33, "willLastToReset": true, "deltaPercent": 5, "expectedUsedPercent": 28},
    "glm": {"usedPercent": 2}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 7: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "【節約モード】" || fail "Test 7: 日次閾値超過で節約モードが宣言されない: $out"
echo "$out" | grep -q "実装は ai-worker" || fail "Test 7: 節約モード宣言に分担（実装=ai-worker）が無い: $out"
echo "$out" | grep -q "⛔" && fail "Test 7: warn帯(daily=13%)なのにstrongの⛔が出てしまう: $out" || true

# --- Test 8: willLastToReset:false + claude_pace_exhaustion_is_strong:true で強い宣言になる ---
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 34, "session": 8, "weekly": 34, "willLastToReset": false, "deltaPercent": 3, "expectedUsedPercent": 28, "etaSeconds": 172800},
    "glm": {"usedPercent": 2}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 8: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "⛔【節約モード】" || fail "Test 8: willLastToReset:falseで強い宣言にならない: $out"
echo "$out" | grep -q "枯渇見込み" || fail "Test 8: etaSecondsからの枯渇見込み表示が無い: $out"

# --- Test 9: 鮮度表示の強化。TTLの2倍(1800s)より大きく古い(2時間前)キャッシュには ⚠️ を出す ---
OLD_ISO="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$OLD_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 20, "session": 5, "weekly": 20, "willLastToReset": true},
    "glm": {"usedPercent": 2}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 9: exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "⚠️ クレジット残量" || fail "Test 9: 2時間前の古いキャッシュで ⚠️ 表示にならない: $out"
echo "$out" | grep -q "最新の値ではない可能性があります" || fail "Test 9: 鮮度警告の説明文が出ていない: $out"

# ===== [2026-09-01] Codexレビュー指摘対応: resetsAt（週次カウンタ世代）跨ぎテスト =====
# 指摘: 基準点と同じUTC日の途中でresetsAtを跨ぐと weekly-baseline が負になり max(0,...) で
# 0に潰れ、実際は使っているのに節約モードが発火しない。具体例: 基準点80% → リセット後15%
# 使用 → max(0,15-80)=0 と誤判定。

# --- Test 10: 同じUTC日のうちにresetsAtが変わった（世代切替）ケース:
#     基準点が取り直され、リセット後の使用分（観測値そのもの）が日次として正しくカウントされる ---
rm -rf "${DELEGATION_REMINDER_CACHE_DIR:?}"/daily-baseline-* 2>/dev/null || true
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 80, "session": 40, "weekly": 80, "willLastToReset": true, "resetsAt": "2026-08-30T09:00:00Z"}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 10 (1回目): exit 0 にならない（exit=$exit_code）"
baseline_file_10="$(find "$DELEGATION_REMINDER_CACHE_DIR" -maxdepth 1 -type f -name 'daily-baseline-*' | head -1)"
[ -n "$baseline_file_10" ] || fail "Test 10: 基準点ファイルが作られていない"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('baseline')==80 else 1)" "$baseline_file_10" \
  || fail "Test 10 前提: 1回目の基準点が80になっていない: $(cat "$baseline_file_10")"
# 2回目: 同じUTC日のうちにresetsAtが変わり(=リセット発生)、weekly=15%（旧計算だとmax(0,15-80)=0で誤判定）
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 15, "session": 5, "weekly": 15, "willLastToReset": true, "resetsAt": "2026-09-06T09:00:00Z"}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 10 (2回目): exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "節約モード" || fail "Test 10: 世代切替後、新世代の使用分(15%)で節約モードが発火すべき: $out"
echo "$out" | grep -q "本日約15%" || fail "Test 10: 世代切替後、日次使用量が新世代の観測値(15%)そのもので再カウントされていない: $out"
echo "$out" | grep -q "本日約0%" && fail "Test 10: 旧バグ再現: max(0,15-80)=0に潰れている: $out" || true
echo "$out" | grep -q "週次カウンタ変更直後のため本日分は一部のみ" || fail "Test 10: 世代切替時の『本日分は一部のみ』注記が出ていない: $out"
baseline_file_10b="$(find "$DELEGATION_REMINDER_CACHE_DIR" -maxdepth 1 -type f -name 'daily-baseline-*' | head -1)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('baseline')==15 and d.get('resetsAt')=='2026-09-06T09:00:00Z' else 1)" "$baseline_file_10b" \
  || fail "Test 10: 世代切替後、基準点ファイルが新世代(baseline=15,resetsAt=新値)へ更新されていない: $(cat "$baseline_file_10b")"

# --- Test 11: resetsAtが同一のまま推移する通常ケース: 既存挙動が変わらない（回帰確認） ---
rm -rf "${DELEGATION_REMINDER_CACHE_DIR:?}"/daily-baseline-* 2>/dev/null || true
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 20, "session": 5, "weekly": 20, "willLastToReset": true, "resetsAt": "2026-09-06T09:00:00Z"}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 11 (1回目): exit 0 にならない（exit=$exit_code）"
# resetsAtは同じまま weekly だけ 33% へ増加（日次+13%で warn帯）
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 33, "session": 8, "weekly": 33, "willLastToReset": true, "resetsAt": "2026-09-06T09:00:00Z"}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 11 (2回目): exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "本日約13%" || fail "Test 11: resetsAt不変時は従来どおり増分(13%)で計算されるべき: $out"
echo "$out" | grep -q "週次カウンタ変更直後のため本日分は一部のみ" && fail "Test 11: resetsAt不変なのに世代切替注記が出てしまう: $out" || true

# --- Test 12: resetsAtがキャッシュに無いケース: 世代判定できず fail-open して従来どおり動く ---
rm -rf "${DELEGATION_REMINDER_CACHE_DIR:?}"/daily-baseline-* 2>/dev/null || true
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 20, "session": 5, "weekly": 20, "willLastToReset": true}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 12 (1回目): exit 0 にならない（exit=$exit_code）"
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 33, "session": 8, "weekly": 33, "willLastToReset": true}
  }
}
JSON
out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_DAILY" bash "$TARGET_SCRIPT")"
exit_code=$?
[ "$exit_code" -eq 0 ] || fail "Test 12 (2回目): exit 0 にならない（exit=$exit_code）"
echo "$out" | grep -q "本日約13%" || fail "Test 12: resetsAt欠落時もfail-openで従来どおり増分計算されるべき: $out"

# ===== [2026-09-01][test] agents.yaml 3段フォールバック解決テスト =====
# 背景: 配布先PJ（jtt-cms/jtt-apps/jtt-system/jtt-cafe-pj/hermes/mcp-servers系）には
# agents.yaml が存在せず、これまで hook は毎回無言 exit 0 していた（実測・本PRの主目的）。
# AGENTS_YAML_PATH を明示せず、PJ にも agents.yaml が無い実運用の形を検証する。
# AGENT_HUB_AGENTS_YAML（fable-implementation-guard.sh が既に採用済みの env と同名・同粒度。
# agents.yaml への絶対パスを直接指す）を一時ファイルへ向け、実マシンの
# ~/business/AGENT-HUB/agents.yaml の中身には依存しない。

# --- Test 13: PJ に agents.yaml が無く、AGENT_HUB_AGENTS_YAML フォールバック先に存在する
#     → 閾値が読まれ、残量パネルが出る ---
FALLBACK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/credit-preflight-fallback.XXXXXX")"
FALLBACK_PJ="$FALLBACK_TMP/pj"
mkdir -p "$FALLBACK_PJ/cache" "$FALLBACK_PJ/daily-baseline-cache"

FALLBACK_AGENTS_YAML="$FALLBACK_TMP/agents.yaml"
cat > "$FALLBACK_AGENTS_YAML" <<'YAML'
worker_delegation:
  credit_preflight:
    cache_path: "~/.cache/agent-hub/credit-usage.json"
    cache_ttl_seconds: 900
    display_routes: ["claude", "glm"]
    claude_weekly_warn_percent: 55
    claude_weekly_strong_percent: 75
YAML

FALLBACK_CACHE_FILE="$FALLBACK_PJ/cache/credit-usage.json"
cat > "$FALLBACK_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 62, "session": 16, "weekly": 62, "willLastToReset": false},
    "glm": {"usedPercent": 2}
  }
}
JSON

fallback_out="$(
  env -u AGENTS_YAML_PATH \
    AGENT_HUB_AGENTS_YAML="$FALLBACK_AGENTS_YAML" \
    CLAUDE_PROJECT_DIR="$FALLBACK_PJ" \
    CREDIT_USAGE_CACHE_FILE="$FALLBACK_CACHE_FILE" \
    DELEGATION_REMINDER_CACHE_DIR="$FALLBACK_PJ/daily-baseline-cache" \
    bash "$TARGET_SCRIPT"
)"
fallback_exit=$?
[ "$fallback_exit" -eq 0 ] || fail "Test 13: exit 0 にならない（exit=$fallback_exit）"
echo "$fallback_out" | grep -q "Claude 週次" || fail "Test 13: PJ に agents.yaml が無くAGENT_HUB_AGENTS_YAMLフォールバックでも残量パネルが出ない: $fallback_out"
echo "$fallback_out" | grep -q "62%" || fail "Test 13: フォールバック時の62%表示が無い: $fallback_out"
rm -rf "$FALLBACK_TMP"

# --- Test 14: PJ にも AGENT_HUB_AGENTS_YAML フォールバック先にも agents.yaml が無い
#     → これまで通り無言で exit 0（fail-open。エラーを出さない） ---
FALLBACK_TMP2="$(mktemp -d "${TMPDIR:-/tmp}/credit-preflight-nofallback.XXXXXX")"
mkdir -p "$FALLBACK_TMP2/pj"
no_fallback_out="$(
  env -u AGENTS_YAML_PATH \
    AGENT_HUB_AGENTS_YAML="$FALLBACK_TMP2/agent-hub-missing/agents.yaml" \
    CLAUDE_PROJECT_DIR="$FALLBACK_TMP2/pj" \
    bash "$TARGET_SCRIPT"
)"
no_fallback_exit=$?
[ "$no_fallback_exit" -eq 0 ] || fail "Test 14: agents.yaml が完全に無い時に exit 0 にならない（exit=$no_fallback_exit）"
[ -z "$no_fallback_out" ] || fail "Test 14: agents.yaml が完全に無い時は無音であるべき: $no_fallback_out"
rm -rf "$FALLBACK_TMP2"

# [2026-09-03][test] Test 15: Codex(GPT) と Spark が別枠で表示されること（PR2407 再発防止）
# 背景: 伸太郎殿指摘「Codex 96% は Spark、GPT は余裕がある」。routes.codex と
# routes["codex-spark"] を両方持つキャッシュを与え、display_routes を明示せず
# スクリプト既定（agents.yaml のデフォルト値と一致させた display_routes）を使わせた時、
# "Codex(GPT) 74% / Spark 96%" のように2本別々に出ること。
TEST_AGENTS_YAML_SPARK="$TMP_DIR/agents-spark.yaml"
cat > "$TEST_AGENTS_YAML_SPARK" <<'YAML'
worker_delegation:
  credit_preflight:
    as_of: "2026-08-27"
    cache_path: "~/.cache/agent-hub/credit-usage.json"
    cache_ttl_seconds: 900
    display_routes: ["claude", "glm", "antigravity", "kimi", "codex", "codex-spark", "cursor", "ocg"]
    claude_weekly_warn_percent: 55
    claude_weekly_strong_percent: 75
    rule: "テスト専用: codex-spark 分離表示の確認"
YAML

NOW_ISO_SPARK="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
cat > "$TEST_CACHE_FILE" <<JSON
{
  "updatedAt": "$NOW_ISO_SPARK",
  "source": "codexbar CLI",
  "routes": {
    "claude": {"usedPercent": 30, "session": 5, "weekly": 30, "willLastToReset": true},
    "codex": {"usedPercent": 74},
    "codex-spark": {"usedPercent": 96}
  }
}
JSON

spark_out="$(AGENTS_YAML_PATH="$TEST_AGENTS_YAML_SPARK" bash "$TARGET_SCRIPT")"
spark_exit=$?
[ "$spark_exit" -eq 0 ] || fail "Test 15: exit 0 にならない（exit=$spark_exit）"
echo "$spark_out" | grep -q "Codex(GPT) 74%" || fail "Test 15: Codex(GPT) 74% 表示が無い: $spark_out"
echo "$spark_out" | grep -q "Spark 96%" || fail "Test 15: Spark 96% 表示が無い: $spark_out"

echo "PASS: credit-baton-preflight"
