#!/bin/bash
# PostToolUse (Edit|Write|MultiEdit) backstop for delegation-routing-reminder.sh.
#
# [2026-08-10][feat] 三役体制の委譲判定リマインダー hook（承認済みプラン）
# 背景:
#   - ユーザー依頼意図: delegation-routing-reminder.sh（UserPromptSubmit）はキーワード検知に
#     依存するため検知漏れがあり得る。実装意図の宣言なしに Edit/Write/MultiEdit が走った
#     セッションを、事後に一度だけ気づかせたい（PM自身のコンテキスト浪費を止める最後の砦）。
#   - 守るべき業務ルール: PostToolUse からモデルへフィードバックを返す経路は本リポに先例が無い
#     新規技術検証（既存 PostToolUse hook は全て exit 0 + stderr のみ）。context 注入不可なら
#     `DELEGATION_BACKSTOP_STDERR_ONLY=1` で stderr 警告のみへ縮退できる fallback を持つ。
#     fresh session runtime proof（台帳F4）で成立を確認する。
#   - 他案不採用理由: PreToolUse で Edit 自体をブロックする案は、正当な小修正・検証編集まで
#     止める誤爆コストが高いため不採用（本リポは非ブロック優先の個人開発スケール）。
# 対応: reminder（UserPromptSubmit）が書くセッションマーカーの有無を見て、
#   マーカーが無いセッションで最初の Edit/Write/MultiEdit の直後に1回だけフィードバックする。
#   backstop 用の別マーカーを同ディレクトリに置き、2回目以降は無音にする。
#
# [2026-08-11][fix] codexレビュー対応（PR #1558 🟡3件）
# 背景:
#   - ユーザー依頼意図: W1) 入力 JSON（PostToolUse は Edit/Write/MultiEdit の tool_input を含み
#     長文になりうる）を HOOK_INPUT 環境変数へ載せて python へ渡していたため、OS の環境変数
#     サイズ上限を超えると python 起動が失敗し、backstop が無音失効する恐れがあった。
#     W2) session_id を未検証のままマーカーファイル名へ直接連結しており、`../` や改行を含む
#     session_id が渡された場合に cache ディレクトリ外への書き込み・パス崩れの恐れがあった。
#   - 守るべき業務ルール: hook は入力の大きさ・形に関わらず非ブロック（exit 0）を維持する。
#     マーカーファイル名は固定長・既知文字集合（hex）に限定する。
#   - 他案不採用理由: delegation-routing-reminder.sh と同型（同ファイルの CaD 参照。
#     `python3 - <<'PY'` に RAW_INPUT を同時にパイプする案は、ヒアドキュメントがスクリプト
#     本体として stdin を奪い sys.stdin.read() が常に空になるため不採用。プロセス置換へ切替）。
# 対応: python スクリプト本体はプロセス置換 `<(...)` でファイル引数として渡し、stdin は
#   RAW_INPUT 専用に空ける。session_id は python 内で hashlib.sha256 により固定長 hex へ
#   変換してから marker ファイル名に使う。`set -e` は撤去し、失敗時も明示的に exit 0 へ
#   抜ける fail-open を徹底する。

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.claude/hooks/.delegation-reminder-cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

RAW_INPUT="$(cat 2>/dev/null || true)"

# python スクリプト本体（プロセス置換でファイル引数として渡す。stdin は RAW_INPUT 専用）。
DELEGATION_BACKSTOP_SESSION_PY() {
  cat <<'PY'
import hashlib
import json
import sys


def main() -> None:
    raw = sys.stdin.read()
    session_hash = ""
    if raw.strip():
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        if isinstance(payload, dict):
            for key in ("session_id", "sessionId"):
                value = payload.get(key)
                if isinstance(value, str) and value:
                    # [2026-08-11][fix] codexレビュー W2: session_id をそのまま marker
                    # ファイル名へ使わず sha256 固定長 hex へ変換する（path traversal 対策）。
                    session_hash = hashlib.sha256(
                        value.encode("utf-8", errors="surrogatepass")
                    ).hexdigest()
                    break
    print(session_hash)


try:
    main()
except Exception:
    print("")
PY
}

SESSION_HASH="$(printf '%s' "$RAW_INPUT" | command python3 <(DELEGATION_BACKSTOP_SESSION_PY) 2>/dev/null)"
SESSION_HASH_STATUS=$?
if [ "$SESSION_HASH_STATUS" -ne 0 ]; then
  # python 実行自体が失敗しても非ブロックを維持する（fail-open）。
  exit 0
fi

# セッション ID が取れなければスロットルできないため、何もせず抜ける（fail-open）。
[ -n "$SESSION_HASH" ] || exit 0

REMINDER_MARKER="$CACHE_DIR/$SESSION_HASH"
BACKSTOP_MARKER="$CACHE_DIR/${SESSION_HASH}.backstop"

# reminder（UserPromptSubmit）がこのセッションで既に発火済みなら backstop は不要。
[ -f "$REMINDER_MARKER" ] && exit 0

# backstop 自体が既にこのセッションで発火済みなら2回目以降は無音。
[ -f "$BACKSTOP_MARKER" ] && exit 0

: > "$BACKSTOP_MARKER" 2>/dev/null || true

MSG='【三役体制】着手前に委譲判定を1行宣言してから進めること: ①10分未満の小修正/ガバナンス領域→Claudeサブエージェント内製 ②まとまった実装・並列・大量読み→AI worker（agent-dispatch） ③調査: 小=context-engine直・中大=参謀Kimi ④緊急時のみ利用者の明示指示でPM直実装（解消後は委譲へ自動復帰）。PM本体のinline実装は原則禁止。（委譲判定の宣言なしに編集が行われたため事後通知）'

# lib が無い配布先でも壊れない no-op fallback（台帳F7: 発火時に相乗り記録）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }
agent_hub_telemetry_log "delegation_reminder" "delegation-routing-backstop" "fired" "" 2>/dev/null || true

if [ "${DELEGATION_BACKSTOP_STDERR_ONLY:-0}" = "1" ]; then
  # 本リポ初の PostToolUse フィードバック経路が不成立/不安定と判明した場合の縮退経路。
  printf '%s\n' "$MSG" >&2
  exit 0
fi

# 標準の PostToolUse JSON フィードバック（本リポの quality-check-common.sh と同型の
# decision/reason スキーマ）。編集自体は取り消されず、reason がモデルへ渡る。MSG はここでは
# 固定短文（ユーザー入力に依存しない）のため env 経由でも安全。
HOOK_REASON="$MSG" python3 - <<'PY' 2>/dev/null || printf '%s\n' "$MSG" >&2
import json
import os

print(json.dumps({"decision": "block", "reason": os.environ.get("HOOK_REASON", "")}, ensure_ascii=False))
PY

exit 0
