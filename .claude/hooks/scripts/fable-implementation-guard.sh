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
#
# [2026-08-13][feat] 対象モデルと強さを agents.yaml から読む（詳細 CaD は本文中の該当ブロック）。
#   上記「対応」にあった `*fable*` の直書き判定は撤去済み。現行は
#   model_catalog.pm_models[*].implementation_guard（tier / runtime_match / after_edits）を引き、
#   台帳が読めない時だけ fable=strict / 1回目 へ縮退して従来挙動を保つ。

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

# [2026-08-13][feat] リマインドの強さを agents.yaml（model_catalog.pm_models）から読む。
# 背景:
#   - ユーザー依頼意図: Fable は強め・Opus は軽め、という強制力の差を付けたい。
#   - 守るべき業務ルール: hook にモデル名を直書きしない（reference-over-hardcode）。
#     配布先PJから正本を引くため参照は絶対パス（相対だと配布先 cwd で解決できない）。
#   - 他案不採用理由:
#     1) 台帳が読めない時に無音化する案は、Fable での実装検知が静かに死ぬため不採用。
#        読めない時は組み込み既定（fable=strict/1回目）へ縮退し、従来の挙動を保つ。
#     2) PyYAML を必須依存にする案は不採用（2026-08-13 codex レビュー 🟡）。hook は
#        これまで stdlib だけで動いており、PyYAML が無い配布先では Opus の soft ガードが
#        「エラーも出さず一生発火しない」形で静かに落ちる。PyYAML があれば使い、無ければ
#        implementation_guard ブロックだけを読む狭い stdlib フォールバックへ落とす。
#     3) agents.yaml から JSON 派生ファイルを生成して hook に読ませる案も不採用。
#        生成物が増えると「正本を変えたのに派生が古い」という、本プランで直している当の
#        問題を新設することになる（鮮度チェックの機構も別途必要になる）。
GUARD_LEDGER="${AGENT_HUB_AGENTS_YAML:-$HOME/business/AGENT-HUB/agents.yaml}"

FABLE_GUARD_RESOLVE_TIER_PY() {
  cat <<'PY'
from __future__ import annotations

import os

model = (os.environ.get("HOOK_MODEL_LOWER") or "").strip()
ledger = os.environ.get("HOOK_GUARD_LEDGER") or ""


def emit(tier: str, after_edits: str, label: str) -> None:
    print(tier)
    print(after_edits)
    print(label)


def pick(pm_models: dict) -> tuple[str, str, str] | None:
    """Return (tier, after_edits, label) for the first model matching `model`."""
    for name, entry in pm_models.items():
        if not isinstance(entry, dict):
            continue
        guard = entry.get("implementation_guard")
        if not isinstance(guard, dict):
            continue
        needle = str(guard.get("runtime_match") or "").strip().lower()
        if not needle or needle not in model:
            continue
        tier = str(guard.get("tier") or "strict").strip().lower()
        try:
            after_edits = max(1, int(guard.get("after_edits", 1)))
        except (TypeError, ValueError):
            after_edits = 1
        return tier, str(after_edits), str(entry.get("display_name") or name)
    return None


def load_with_yaml(text: str) -> dict:
    import yaml  # type: ignore

    data = yaml.safe_load(text) or {}
    pm_models = ((data.get("model_catalog") or {}).get("pm_models")) or {}
    if not isinstance(pm_models, dict):
        raise ValueError("pm_models is not a mapping")
    return pm_models


def load_without_yaml(text: str) -> dict:
    """Narrow stdlib fallback for hosts without PyYAML.

    Not a YAML parser: it only walks the fixed two-level shape
    `model_catalog: -> pm_models: -> <model>: -> implementation_guard: -> <scalar>`
    at the indentation agents.yaml actually uses.  Anything it fails to
    recognise simply yields no match, which degrades to the same built-in
    default as an unreadable ledger — never to a wrong tier.
    """
    pm_models: dict[str, dict] = {}
    in_catalog = in_pm = False
    current: dict | None = None
    in_guard = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 0:
            in_catalog = stripped == "model_catalog:"
            in_pm = False
            current = None
            in_guard = False
            continue
        if not in_catalog:
            continue
        if indent == 2:
            in_pm = stripped == "pm_models:"
            current = None
            in_guard = False
            continue
        if not in_pm:
            continue
        if indent == 4 and stripped.endswith(":"):
            current = {}
            pm_models[stripped[:-1].strip()] = current
            in_guard = False
            continue
        if current is None:
            continue
        if indent == 6:
            in_guard = stripped == "implementation_guard:"
            if not in_guard and ":" in stripped:
                key, _, value = stripped.partition(":")
                if key.strip() == "display_name":
                    current["display_name"] = value.strip().strip('"').strip("'")
            continue
        if indent == 8 and in_guard and ":" in stripped:
            key, _, value = stripped.partition(":")
            guard = current.setdefault("implementation_guard", {})
            guard[key.strip()] = value.strip().strip('"').strip("'")
    return pm_models


try:
    with open(ledger, encoding="utf-8") as handle:
        text = handle.read()
    try:
        pm_models = load_with_yaml(text)
    except ImportError:
        pm_models = load_without_yaml(text)
    hit = pick(pm_models)
    if hit is None:
        # 台帳は読めたが該当モデルなし＝このモデルは対象外。無音にする。
        emit("", "", "")
    else:
        emit(*hit)
except Exception:
    # 台帳が開けない・壊れている等。組み込み既定へ縮退する。
    emit("FALLBACK", "", "")
PY
}

GUARD_TIER=""
GUARD_AFTER_EDITS=""
GUARD_LABEL=""
GUARD_RESOLVED="$(HOOK_MODEL_LOWER="$MODEL_LOWER" HOOK_GUARD_LEDGER="$GUARD_LEDGER" \
  command python3 <(FABLE_GUARD_RESOLVE_TIER_PY) 2>/dev/null)"
{
  IFS= read -r GUARD_TIER || true
  IFS= read -r GUARD_AFTER_EDITS || true
  IFS= read -r GUARD_LABEL || true
} <<< "$GUARD_RESOLVED"

if [ -z "$GUARD_TIER" ] || [ "$GUARD_TIER" = "FALLBACK" ]; then
  # 縮退: 従来どおり Fable だけを strict / 1回目で見る。
  case "$MODEL_LOWER" in
    *fable*)
      GUARD_TIER="strict"
      GUARD_AFTER_EDITS="1"
      GUARD_LABEL="Fable"
      ;;
    *) exit 0 ;;
  esac
fi

case "$GUARD_AFTER_EDITS" in
  ''|*[!0-9]*) GUARD_AFTER_EDITS="1" ;;
esac
[ "$GUARD_AFTER_EDITS" -ge 1 ] || GUARD_AFTER_EDITS=1
[ -n "$GUARD_LABEL" ] || GUARD_LABEL="このモデル"

# 対象モデルのセッション確定。
# セッション ID が取れなければスロットルできないため、何もせず抜ける（fail-open）。
[ -n "$SESSION_HASH" ] || exit 0

MARKER="$CACHE_DIR/fable-guard-$SESSION_HASH"
[ -f "$MARKER" ] && exit 0

# after_edits 回目の実装編集で初めて出す（soft tier 用）。1 なら従来どおり初回で出る。
if [ "$GUARD_AFTER_EDITS" -gt 1 ]; then
  COUNTER="$CACHE_DIR/fable-guard-$SESSION_HASH.count"
  printf 'x' >> "$COUNTER" 2>/dev/null || true
  EDITS="$(wc -c < "$COUNTER" 2>/dev/null | tr -d ' ')"
  case "$EDITS" in
    ''|*[!0-9]*) EDITS=0 ;;
  esac
  [ "$EDITS" -ge "$GUARD_AFTER_EDITS" ] || exit 0
fi

: > "$MARKER" 2>/dev/null || true

if [ "$GUARD_TIER" = "soft" ]; then
  MSG="💡 ${GUARD_LABEL} セッションで実装編集が続いています。${GUARD_LABEL} はなるべく頭脳（設計・診断・承認判断・検証）に使いたいモデルです。まとまった実装は AI worker（agent-dispatch）または Claude サブエージェントへ委譲できないか一度検討してください（そのまま続けても構いません）。"
else
  MSG="⚠️ ${GUARD_LABEL} セッションで実装編集が行われました。${GUARD_LABEL} は頭脳（設計・診断・承認判断・検証）であって実装者ではありません。実装は AI worker（agent-dispatch）または Claude サブエージェントへ委譲してください（緊急時のみ利用者の明示指示で PM 直実装可）。"
fi

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
