#!/usr/bin/env bash
set -u

# [2026-08-27][feat] クレジット残量キャッシュ更新スクリプト (credit-usage-cache.sh)
# 背景:
#   - ユーザー依頼意図: codexbar CLI の実行には1回あたり1〜3秒かかるため、
#     SessionStart hook が同期実行すると体験をブロックしてしまう。
#     非同期バックグラウンドで codexbar を叩いて JSON キャッシュを更新するスクリプトを新設する。
#   - 守るべき業務ルール:
#     1) 多重起動防止（credit-usage.lock）。
#     2) 原子的書き込み（tmpファイル→mv）。
#     3) 失敗時に既存キャッシュを壊さない（全滅時は既存維持、部分成功時は取れたrouteのみ）。
#     4) 取得不能 provider は routes にキーごと入れない。
#     5) codexbar / jq 不在時は何もせず exit 0。
#   - 他案不採用理由:
#     1) hook から codexbar を同期実行する案は、セッション開始遅延（1〜3秒）を招くため不採用。
#     2) 取得不能時に null や 0% で埋める案は、「不明」と「真の0%」を取り違えるため不採用。

# Check jq
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Locate codexbar binary
CODEXBAR="${CODEXBAR_BIN:-/opt/homebrew/bin/codexbar}"
if ! command -v "$CODEXBAR" >/dev/null 2>&1 && [ ! -x "$CODEXBAR" ]; then
  exit 0
fi

# Cache path and locking
CACHE_FILE="${CREDIT_USAGE_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-hub/credit-usage.json}"
CACHE_DIR="$(dirname "$CACHE_FILE")"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

LOCK_FILE="$CACHE_DIR/credit-usage.lock"

# [2026-08-27][fix] codex レビュー 🟡 対応: 生存中の lock を横取りしない
# 背景:
#   - 指摘: stale 判定が 60 秒固定だったが、7 provider を各 25 秒まで直列実行するため
#     正常系でも最大 175 秒かかる。60 秒後に別の SessionStart が生きている更新処理の lock を
#     消し、古いプロセスが新しい lock まで削除して多重実行になりうる。
#   - 守るべき業務ルール: lock は「二重起動を防ぐ」ためのものであり、生きているプロセスの
#     lock を奪ってはいけない。取得できない場合は黙って諦める（非ブロック・fail-open）。
#   - 他案不採用理由: 単に猶予秒数を伸ばす案は、プロセスが強制終了された場合に
#     その秒数だけ更新が止まるため不採用。PID 生存確認なら即座に回収できる。
# 対応: lock ファイルに書いた PID の生存を第一条件にし、時間経過はPIDが読めない場合の
#   フォールバックに降格する。猶予は実行時間の実態（provider 数 × timeout）から算出する。
LOCK_STALE_SEC="${CREDIT_USAGE_LOCK_STALE_SEC:-300}"

acquire_lock() {
  if (set -o noclobber; echo "$$" > "$LOCK_FILE") 2>/dev/null; then
    trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT INT TERM
    return 0
  fi
  # 既存 lock の PID が生きているなら、経過時間に関わらず奪わない
  local lock_pid now lock_mtime
  lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
  case "$lock_pid" in
    ''|*[!0-9]*) : ;;  # PID が読めない場合は時間フォールバックへ
    *)
      if kill -0 "$lock_pid" 2>/dev/null; then
        return 1
      fi
      ;;
  esac
  now=$(date +%s 2>/dev/null || echo 0)
  lock_mtime=$(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
  if [ "$now" -gt 0 ] && [ "$lock_mtime" -gt 0 ] && [ $((now - lock_mtime)) -gt "$LOCK_STALE_SEC" ]; then
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if (set -o noclobber; echo "$$" > "$LOCK_FILE") 2>/dev/null; then
      trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT INT TERM
      return 0
    fi
  fi
  return 1
}

if ! acquire_lock; then
  exit 0
fi

# [2026-08-27][fix] claude 取得 timeout の修正 (10s -> 25s)
# 背景:
#   - ユーザー依頼意図: codexbar usage --provider claude が実測 17.4 秒かかるため、10 秒 timeout だと
#     毎回タイムアウトして routes.claude が欠落する致命的欠陥を解消する。
#   - 守るべき業務ルール: 全 provider 一律 25 秒とし、timeout の数値を 1 箇所の変数にまとめる。
#   - 他案不採用理由: claude を監視対象から外す案は、バトンタッチ判断の主役データを失うため不採用。
TIMEOUT_SEC="${CREDIT_USAGE_TIMEOUT_SEC:-25}"

run_with_timeout() {
  local timeout_sec="$TIMEOUT_SEC"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" "$@"
  else
    "$@"
  fi
}

PROVIDERS=("claude" "zai" "antigravity" "kimi" "codex" "cursor" "opencodego")
ROUTES_JSON="{}"
HAS_ANY_ROUTE=0

for p in "${PROVIDERS[@]}"; do
  route="$p"
  if [ "$p" = "zai" ]; then
    route="glm"
  elif [ "$p" = "opencodego" ]; then
    route="ocg"
  fi

  out="$(run_with_timeout "$CODEXBAR" usage --provider "$p" --format json --no-color 2>/dev/null || true)"
  if [ -z "$out" ]; then
    continue
  fi

  if [ "$p" = "claude" ]; then
    route_obj="$(printf '%s' "$out" | jq -c '
def select_provider(p):
  (if type == "array" then .[] else . end) | select(.provider == p or (.provider | type == "string" and ascii_downcase == p));

def extract_windows:
  [
    .usage.primary,
    .usage.secondary,
    .usage.tertiary,
    (if .usage.extraRateWindows then .usage.extraRateWindows[] | (if type == "object" and .window then .window else . end) else empty end)
  ] | map(select(type == "object" and . != null));

def max_used_percent:
  extract_windows | map(.usedPercent | numbers) | if length > 0 then max else null end;

select_provider("claude") |
  (max_used_percent) as $max |
  if $max == null then empty else
    extract_windows as $wins |
    (first($wins[] | select(.windowMinutes == 300) | .usedPercent) // .usage.primary.usedPercent // $max) as $sess |
    (first($wins[] | select(.windowMinutes == 10080) | .usedPercent) // .usage.secondary.usedPercent // $max) as $week |
    {
      usedPercent: $max,
      session: $sess,
      weekly: $week
    } + (if (.pace.secondary.willLastToReset | type == "boolean") then {willLastToReset: .pace.secondary.willLastToReset} else {} end)
  end
' 2>/dev/null || true)"
  else
    route_obj="$(printf '%s' "$out" | jq -c --arg p "$p" '
def select_provider(p):
  (if type == "array" then .[] else . end) | select(.provider == p or (.provider | type == "string" and ascii_downcase == p));

def extract_windows:
  [
    .usage.primary,
    .usage.secondary,
    .usage.tertiary,
    (if .usage.extraRateWindows then .usage.extraRateWindows[] | (if type == "object" and .window then .window else . end) else empty end)
  ] | map(select(type == "object" and . != null));

def max_used_percent:
  extract_windows | map(.usedPercent | numbers) | if length > 0 then max else null end;

select_provider($p) |
  (max_used_percent) as $max |
  if $max == null then empty else
    {
      usedPercent: $max
    }
  end
' 2>/dev/null || true)"
  fi

  if [ -n "$route_obj" ] && [ "$route_obj" != "null" ]; then
    ROUTES_JSON="$(printf '%s' "$ROUTES_JSON" | jq -c --arg route "$route" --argjson obj "$route_obj" '.[$route] = $obj' 2>/dev/null || echo "$ROUTES_JSON")"
    HAS_ANY_ROUTE=1
  fi
done

if [ "$HAS_ANY_ROUTE" -ne 1 ]; then
  exit 0
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
FINAL_JSON="$(jq -n --arg updatedAt "$NOW_ISO" --argjson routes "$ROUTES_JSON" '{
  updatedAt: $updatedAt,
  source: "codexbar CLI",
  routes: $routes
}')"

TMP_FILE="$CACHE_DIR/credit-usage.json.tmp.$$"
printf '%s\n' "$FINAL_JSON" > "$TMP_FILE"
mv -f "$TMP_FILE" "$CACHE_FILE"

exit 0
