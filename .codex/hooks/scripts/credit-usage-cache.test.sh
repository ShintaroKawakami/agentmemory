#!/usr/bin/env bash
set -euo pipefail

# [2026-08-27][test] credit-usage-cache.sh の単体テスト。
# 背景:
#   - ユーザー依頼意図: codexbar 不在/失敗時の既存キャッシュ保護、正常時JSON構造、
#     取得失敗providerのキー除外を機械的に固定する。
#   - 守るべき業務ルール: テスト用スタブ（PATH先頭のダミーcodexbar/jq）を使用し、
#     mktemp -d で一時環境を作り実環境 ~/.cache を汚さない。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/credit-usage-cache.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/credit-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

STUB_BIN_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_BIN_DIR"
export PATH="$STUB_BIN_DIR:$PATH"

TEST_CACHE_FILE="$TMP_DIR/cache/agent-hub/credit-usage.json"
export CREDIT_USAGE_CACHE_FILE="$TEST_CACHE_FILE"

# --- Test 1: codexbar が存在しないとき exit 0 で既存キャッシュを削除しないこと ---
mkdir -p "$(dirname "$TEST_CACHE_FILE")"
printf '{"original":true}' > "$TEST_CACHE_FILE"

# Ensure nonexistent binary path
set +e
CODEXBAR_BIN="$STUB_BIN_DIR/nonexistent-codexbar" bash "$TARGET_SCRIPT"
exit_code=$?
set -e
[ "$exit_code" -eq 0 ] || fail "Test 1: codexbar 不在時に exit 0 にならない（exit=$exit_code）"
[ -f "$TEST_CACHE_FILE" ] || fail "Test 1: 既存キャッシュが削除された"
grep -q '"original":true' "$TEST_CACHE_FILE" || fail "Test 1: 既存キャッシュの内容が破壊された"

# --- Test 2: codexbar がエラーを返すとき既存キャッシュがそのまま残ること ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
echo '[{"provider":"claude","error":"unauthorized"}]'
exit 1
EOF
chmod +x "$STUB_BIN_DIR/codexbar"

set +e
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"
exit_code=$?
set -e
[ "$exit_code" -eq 0 ] || fail "Test 2: codexbar エラー時に exit 0 にならない（exit=$exit_code）"
grep -q '"original":true' "$TEST_CACHE_FILE" || fail "Test 2: エラー時に既存キャッシュが上書き・破壊された"

# --- Test 3: 正常時に期待した JSON 構造（routes.claude.weekly 等）が書かれること ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$provider" in
  claude)
    cat <<'JSON'
[
  {
    "provider": "claude",
    "usage": {
      "primary": { "usedPercent": 16, "windowMinutes": 300 },
      "secondary": { "usedPercent": 62, "windowMinutes": 10080 }
    },
    "pace": {
      "secondary": {
        "willLastToReset": false
      }
    }
  }
]
JSON
    ;;
  zai)
    cat <<'JSON'
[{"provider":"zai","usage":{"primary":{"usedPercent":2}}}]
JSON
    ;;
  antigravity)
    cat <<'JSON'
[{"provider":"antigravity","usage":{"primary":{"usedPercent":0}}}]
JSON
    ;;
  kimi)
    cat <<'JSON'
[{"provider":"kimi","usage":{"primary":{"usedPercent":21}}}]
JSON
    ;;
  codex)
    cat <<'JSON'
[{"provider":"codex","usage":{"primary":{"usedPercent":70}}}]
JSON
    ;;
  cursor)
    cat <<'JSON'
[{"provider":"cursor","usage":{"primary":{"usedPercent":79}}}]
JSON
    ;;
  opencodego)
    cat <<'JSON'
[{"provider":"opencodego","usage":{"primary":{"usedPercent":0}}}]
JSON
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"

CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"
[ -f "$TEST_CACHE_FILE" ] || fail "Test 3: キャッシュファイルが生成されていない"

# Validate JSON structure with jq
jq -e '.source == "codexbar CLI"' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: source が codexbar CLI ではない"
jq -e '.updatedAt | length > 0' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: updatedAt が設定されていない"
jq -e '.routes.claude.usedPercent == 62' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: claude.usedPercent != 62"
jq -e '.routes.claude.session == 16' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: claude.session != 16"
jq -e '.routes.claude.weekly == 62' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: claude.weekly != 62"
jq -e '.routes.claude.willLastToReset == false' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: claude.willLastToReset != false"
jq -e '.routes.glm.usedPercent == 2' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: glm.usedPercent != 2 (zai マッピング)"
jq -e '.routes.antigravity.usedPercent == 0' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: antigravity.usedPercent != 0"
jq -e '.routes.kimi.usedPercent == 21' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: kimi.usedPercent != 21"
jq -e '.routes.codex.usedPercent == 70' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: codex.usedPercent != 70"
jq -e '.routes.cursor.usedPercent == 79' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: cursor.usedPercent != 79"
jq -e '.routes.ocg.usedPercent == 0' "$TEST_CACHE_FILE" >/dev/null || fail "Test 3: ocg.usedPercent != 0 (opencodego マッピング)"

# --- Test 4: 取得できなかった provider のキーが routes に入らないこと ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$provider" in
  claude)
    cat <<'JSON'
[{"provider":"claude","usage":{"primary":{"usedPercent":10,"windowMinutes":300},"secondary":{"usedPercent":30,"windowMinutes":10080}}}]
JSON
    ;;
  zai)
    cat <<'JSON'
[{"provider":"zai","usage":{"primary":{"usedPercent":5}}}]
JSON
    ;;
  kimi)
    # Failure response
    echo '[{"provider":"kimi","error":"network timeout"}]'
    ;;
  *)
    # Exit 1 for all others
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"

rm -f "$TEST_CACHE_FILE"
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"

[ -f "$TEST_CACHE_FILE" ] || fail "Test 4: 部分成功時にキャッシュファイルが生成されていない"
jq -e '.routes.claude.weekly == 30' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: claude.weekly missing"
jq -e '.routes.glm.usedPercent == 5' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: glm.usedPercent missing"
jq -e 'has("routes") and (.routes | has("kimi") | not)' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: kimi のキーが routes に残っている"
jq -e 'has("routes") and (.routes | has("codex") | not)' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: codex のキーが routes に残っている"
jq -e 'has("routes") and (.routes | has("cursor") | not)' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: cursor のキーが routes に残っている"
jq -e 'has("routes") and (.routes | has("ocg") | not)' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: ocg のキーが routes に残っている"
jq -e 'has("routes") and (.routes | has("antigravity") | not)' "$TEST_CACHE_FILE" >/dev/null || fail "Test 4: antigravity のキーが routes に残っている"

# [2026-09-01][test] Test 5: pace フィールド（真因調査タスク item B）が routes.claude へ
# 転記されること。credit-baton-preflight.sh / delegation-routing-reminder.sh の節約モード判定が
# 読む expectedUsedPercent / deltaPercent / stage / resetsAt / weeklyWindowMinutes / etaSeconds /
# paceSummary を、codexbar の生出力そのままで検証する。
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$provider" in
  claude)
    cat <<'JSON'
[
  {
    "provider": "claude",
    "usage": {
      "primary": { "usedPercent": 43, "windowMinutes": 300 },
      "secondary": { "usedPercent": 37, "windowMinutes": 10080, "resetsAt": "2026-09-06T09:00:00Z" }
    },
    "pace": {
      "secondary": {
        "willLastToReset": false,
        "expectedUsedPercent": 25,
        "deltaPercent": 12,
        "stage": "ahead",
        "etaSeconds": 255600,
        "summary": "12% in deficit | Expected 25% used | Runs out in 2d 23h"
      }
    }
  }
]
JSON
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"

rm -f "$TEST_CACHE_FILE"
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"

[ -f "$TEST_CACHE_FILE" ] || fail "Test 5: キャッシュファイルが生成されていない"
jq -e '.routes.claude.weekly == 37' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.weekly != 37"
jq -e '.routes.claude.resetsAt == "2026-09-06T09:00:00Z"' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.resetsAt が転記されていない"
jq -e '.routes.claude.weeklyWindowMinutes == 10080' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.weeklyWindowMinutes != 10080"
jq -e '.routes.claude.expectedUsedPercent == 25' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.expectedUsedPercent != 25"
jq -e '.routes.claude.deltaPercent == 12' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.deltaPercent != 12"
jq -e '.routes.claude.stage == "ahead"' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.stage != ahead"
jq -e '.routes.claude.etaSeconds == 255600' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.etaSeconds != 255600"
jq -e '.routes.claude.paceSummary | length > 0' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.paceSummary が転記されていない"
jq -e '.routes.claude.willLastToReset == false' "$TEST_CACHE_FILE" >/dev/null || fail "Test 5: claude.willLastToReset != false"

# --- Test 6: pace オブジェクト自体が無い場合、pace フィールドを捏造しない（キーごと省略） ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$provider" in
  claude)
    echo '[{"provider":"claude","usage":{"primary":{"usedPercent":10,"windowMinutes":300},"secondary":{"usedPercent":30,"windowMinutes":10080}}}]'
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"
rm -f "$TEST_CACHE_FILE"
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"
jq -e '(.routes.claude | has("expectedUsedPercent")) | not' "$TEST_CACHE_FILE" >/dev/null || fail "Test 6: pace未提供時に expectedUsedPercent を捏造してしまっている"
jq -e '(.routes.claude | has("deltaPercent")) | not' "$TEST_CACHE_FILE" >/dev/null || fail "Test 6: pace未提供時に deltaPercent を捏造してしまっている"
jq -e '(.routes.claude | has("resetsAt")) | not' "$TEST_CACHE_FILE" >/dev/null || fail "Test 6: resetsAt未提供時に捏造してしまっている"

# [2026-09-03][test] Test 7: Codex GPT と Codex Spark が別 route に分離されること
# 背景: 伸太郎殿の実測（PR2407）通り、usage.secondary.usedPercent=74（GPT週次）と
# extraRateWindows[] の id:"codex-spark"（0%）/ "codex-spark-weekly"（96%）を与えた時、
# routes.codex は Spark を含めず74、routes["codex-spark"]は96になること（混同バグの再発防止）。
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$provider" in
  codex)
    cat <<'JSON'
[
  {
    "provider": "codex",
    "usage": {
      "primary": { "usedPercent": 40, "windowMinutes": 300 },
      "secondary": { "usedPercent": 74, "windowMinutes": 10080 },
      "extraRateWindows": [
        { "id": "codex-spark", "usedPercent": 0, "windowMinutes": 300 },
        { "id": "codex-spark-weekly", "usedPercent": 96, "windowMinutes": 10080 }
      ]
    }
  }
]
JSON
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"
rm -f "$TEST_CACHE_FILE"
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"
[ -f "$TEST_CACHE_FILE" ] || fail "Test 7: キャッシュファイルが生成されていない"
jq -e '.routes.codex.usedPercent == 74' "$TEST_CACHE_FILE" >/dev/null || fail "Test 7: routes.codex.usedPercent != 74（Spark混入）"
jq -e '.routes["codex-spark"].usedPercent == 96' "$TEST_CACHE_FILE" >/dev/null || fail "Test 7: routes.codex-spark.usedPercent != 96"

# --- Test 8: Spark window が無い時、codex-spark キー自体を作らない（0%捏造禁止） ---
cat > "$STUB_BIN_DIR/codexbar" <<'EOF'
#!/bin/sh
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$provider" in
  codex)
    echo '[{"provider":"codex","usage":{"primary":{"usedPercent":30,"windowMinutes":300},"secondary":{"usedPercent":50,"windowMinutes":10080}}}]'
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/codexbar"
rm -f "$TEST_CACHE_FILE"
CODEXBAR_BIN="$STUB_BIN_DIR/codexbar" bash "$TARGET_SCRIPT"
jq -e '.routes.codex.usedPercent == 50' "$TEST_CACHE_FILE" >/dev/null || fail "Test 8: routes.codex.usedPercent != 50"
jq -e '(.routes | has("codex-spark")) | not' "$TEST_CACHE_FILE" >/dev/null || fail "Test 8: Spark window が無いのに codex-spark キーが作られている"

echo "PASS: credit-usage-cache"
