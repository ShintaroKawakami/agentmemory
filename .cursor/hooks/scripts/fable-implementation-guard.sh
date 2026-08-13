#!/bin/bash
# PostToolUse (Edit|Write|MultiEdit) reminder: Fable は頭脳であって実装者ではない。
#
# [2026-08-12][feat] Fable セッションでの実装編集に対する事後リマインダー hook
# 背景:
#   - ユーザー依頼意図: 「Fable は頭脳であって実装者ではない。Fable で実装はしない」という
#     三役体制の原則（ai-model-selection.md §4 Fable使用条件）を、Fable セッションで
#     実装系ツール（Edit/Write/MultiEdit）が実際に使われた直後に、モデル自身へ1回だけ
#     気づかせたい。100%の強制ブロックは意図せず、非ブロック・リマインドに留める。
#   - 守るべき業務ルール: delegation-routing-backstop.sh と同型の構造・fail-open 方針
#     （失敗時は必ず exit 0・非ブロック）を踏襲する。session_id は sha256 hex 化してから
#     marker ファイル名に使う（パス注入対策・backstop と同じ手法）。stdin JSON に model
#     情報が無い場合は transcript_path の JSONL 末尾（最大200行の tail）から拾い、
#     transcript 全体は読み込まない（大きい可能性があるため）。
#   - 他案不採用理由: PreToolUse で Edit 自体をブロックする案は、「緊急時のみ利用者の明示指示で
#     PM 直実装可」という例外運用と衝突し、正当な緊急対応まで止める誤爆コストが高いため不採用
#     （本リポは非ブロック優先の個人開発スケール）。stdin JSON にモデル名が無いことを理由に
#     常時無音化する案も、Fable セッションでの検知漏れが大きくなるため不採用し、
#     transcript フォールバックを持たせた。
# 対応: stdin JSON 直下の "model" フィールド → 無ければ "transcript_path" の JSONL 末尾
#   （tail -n 200）から最新の "model":"..." を正規表現で拾う、の2段で判定する。値に
#   "fable" を含む（大文字小文字無視）場合のみ、セッションごとに1回だけ PostToolUse の
#   JSON フィードバック（decision/reason）でモデルへ気づかせる。判定不能時・エラー時は
#   常に何もせず exit 0（fail-open）。FABLE_GUARD_DISABLED=1 で無効化できる escape hatch を持つ。

set -uo pipefail

# [2026-08-12][fix] stdin は disabled チェックより先に必ず読み切る。
# 背景: escape hatch を stdin 読み取りより前に置くと、呼び出し元（Claude Code /
#   テストの `printf ... | bash "$HOOK"`）が書き込み中のパイプを誰も読まないまま
#   exit してしまい、書き込み側が SIGPIPE を受けて非0終了しうる（実測: テストの
#   FABLE_GUARD_DISABLED=1 ケースで pipefail 経由の異常終了を確認）。
# 対応: RAW_INPUT の読み取りを最初に行い、その後で disabled 判定する（fail-open の
#   非ブロック方針は変わらない。exit 0 のタイミングだけをstdin読了後にずらす）。
RAW_INPUT="$(cat 2>/dev/null || true)"

# escape hatch: 無効化フラグ
if [ "${FABLE_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# [2026-08-12] backstop と同じ cache ディレクトリを再利用する（設計で明示された配置）。
# marker ファイル名は "fable-guard-<hash>" prefix で backstop 側の marker
# （"<hash>" / "<hash>.backstop"）と衝突しない。
# [2026-08-13][fix] #1701: runtime marker をリポ外 XDG cache へ移し git dirty を防ぐ。
# shellcheck source=../lib/delegation-reminder-cache.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/delegation-reminder-cache.sh"
CACHE_DIR="$(resolve_delegation_reminder_cache_dir "$PROJECT_DIR")"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# python スクリプト1: session_id を sha256 hex 化し、stdin JSON 直下の "model" /
# "transcript_path" を拾う（プロセス置換でファイル引数として渡す。stdin は RAW_INPUT 専用）。
FABLE_GUARD_PARSE_INPUT_PY() {
  cat <<'PY'
import hashlib
import json
import sys


def _clean(value: str) -> str:
    # tab区切り出力を壊さないよう制御文字を空白へ正規化する。
    return value.replace("\t", " ").replace("\n", " ").replace("\r", " ")


def main() -> None:
    raw = sys.stdin.read()
    session_hash = ""
    model = ""
    transcript_path = ""
    if raw.strip():
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        if isinstance(payload, dict):
            for key in ("session_id", "sessionId"):
                value = payload.get(key)
                if isinstance(value, str) and value:
                    session_hash = hashlib.sha256(
                        value.encode("utf-8", errors="surrogatepass")
                    ).hexdigest()
                    break
            model_value = payload.get("model")
            if isinstance(model_value, str) and model_value:
                model = _clean(model_value)
            tp_value = payload.get("transcript_path")
            if isinstance(tp_value, str) and tp_value:
                transcript_path = _clean(tp_value)
    # 1行1フィールドで出力する（tab区切りは bash の read が tab を IFS-whitespace
    # として連続デリミタ扱いし、空フィールドを消し去るため不採用。改行区切りなら
    # グループ化した複数回の `read -r` で空行も正しく1フィールドとして拾える）。
    print(session_hash)
    print(model)
    print(transcript_path)


try:
    main()
except Exception:
    print("")
    print("")
    print("")
PY
}

PARSED="$(printf '%s' "$RAW_INPUT" | command python3 <(FABLE_GUARD_PARSE_INPUT_PY) 2>/dev/null)"
PARSED_STATUS=$?
if [ "$PARSED_STATUS" -ne 0 ]; then
  # python 実行自体が失敗しても非ブロックを維持する（fail-open）。
  exit 0
fi

SESSION_HASH=""
MODEL=""
TRANSCRIPT_PATH=""
{
  IFS= read -r SESSION_HASH || true
  IFS= read -r MODEL || true
  IFS= read -r TRANSCRIPT_PATH || true
} <<< "$PARSED"

# stdin 直下に model が無ければ transcript_path の JSONL 末尾（最大200行）から拾う。
# transcript 全体は読み込まない（tail コマンドでディスク末尾のみ走査する）。
if [ -z "$MODEL" ] && [ -n "$TRANSCRIPT_PATH" ]; then
  FABLE_GUARD_EXTRACT_MODEL_PY() {
    cat <<'PY'
import re
import sys


def main() -> None:
    text = sys.stdin.read()
    matches = re.findall(r'"model"\s*:\s*"([^"]+)"', text)
    print(matches[-1] if matches else "")


try:
    main()
except Exception:
    print("")
PY
  }
  MODEL="$(tail -n 200 -- "$TRANSCRIPT_PATH" 2>/dev/null | command python3 <(FABLE_GUARD_EXTRACT_MODEL_PY) 2>/dev/null)"
fi

# モデルが判定できなければ何もしない（fail-open）。
[ -n "$MODEL" ] || exit 0

MODEL_LOWER="$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')"
case "$MODEL_LOWER" in
  *fable*) : ;;
  *) exit 0 ;;
esac

# Fable セッションでなければここまでで抜けている。以降は Fable セッション確定。
# セッション ID が取れなければスロットルできないため、何もせず抜ける（fail-open）。
[ -n "$SESSION_HASH" ] || exit 0

MARKER="$CACHE_DIR/fable-guard-$SESSION_HASH"
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null || true

MSG='⚠️ Fable セッションで実装編集が行われました。Fable は頭脳（設計・診断・承認判断・検証）であって実装者ではありません。実装は AI worker（agent-dispatch）または Claude サブエージェントへ委譲してください（緊急時のみ利用者の明示指示で PM 直実装可）。'

# lib が無い配布先でも壊れない no-op fallback（delegation-routing-backstop と同型）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }
agent_hub_telemetry_log "fable_implementation_guard" "fable-implementation-guard" "fired" "" 2>/dev/null || true

# 標準の PostToolUse JSON フィードバック（delegation-routing-backstop.sh と同型の
# decision/reason スキーマ）。編集自体は取り消されず、reason がモデルへ渡る。MSG は
# ここでは固定短文（ユーザー入力に依存しない）のため env 経由でも安全。
HOOK_REASON="$MSG" python3 - <<'PY' 2>/dev/null || printf '%s\n' "$MSG" >&2
import json
import os

print(json.dumps({"decision": "block", "reason": os.environ.get("HOOK_REASON", "")}, ensure_ascii=False))
PY

exit 0
