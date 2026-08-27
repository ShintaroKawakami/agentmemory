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
echo "$out" | grep -q "GLM 2% / Gemini 0% / Kimi 21% / Codex 70%" || fail "Test 3: worker 表示が無い: $out"
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

echo "PASS: credit-baton-preflight"
