#!/bin/bash
# UserPromptSubmit hook for delegation-routing reminders (三役体制).
# Quiet by default: only prints when the prompt contains a known
# implementation-intent keyword AND this session hasn't already been
# reminded once. Non-blocking (always exit 0).
#
# [2026-08-10][feat] 三役体制の委譲判定リマインダー hook（承認済みプラン）
# 背景:
#   - ユーザー依頼意図: PM（Claude本体）が委譲判定なしに inline 実装・大量調査を始めてしまい、
#     $200プランのコンテキストを浪費するのを、非ブロックの機械リマインダーで抑止したい
#     （呼称固定=監督/参謀/職人だけでは徹底できず、機械的に気づける仕組みが要る）。
#   - 守るべき業務ルール: キーワードは `.claude/rules/general/ai-model-selection.md` §4 /
#     `skills/agent-dispatch` 境界の実装トリガー語をハードコード出典として明記し、境界正本
#     改訂時は同一PRで追従する（台帳F8）。pre-implementation-check.sh の 2026-04-26 CaD
#     （毎回大きいリマインダーで体験悪化→既定サイレント化した教訓）を踏まえ、短文＋セッション
#     1回スロットルに限定する（gbrain-recall-preflight.sh と同じ quiet-by-default 様式）。
#   - 他案不採用理由: hook 側で自動的に委譲を強制実行する案は、正当な小修正・検証編集まで
#     止める誤爆コストが高いため不採用（まず非ブロックで観測し、効果不足が実測されたら
#     ブロック型への昇格を別プランで検討する。台帳F7）。
# 対応: 新規 hook を追加。settings/delegation-routing-reminder.json（Claude）と
#   settings-codex/delegation-routing-reminder.json（Codex）を同一 PR で追加する。
#   マーカーディレクトリ .claude/hooks/.delegation-reminder-cache/ でセッション1回スロットル。
#
# [2026-08-11][fix] codexレビュー対応（PR #1558 🟡3件）
# 背景:
#   - ユーザー依頼意図: W1) 入力 JSON を HOOK_INPUT 環境変数へ載せて python へ渡していたため、
#     長文プロンプトで OS の環境変数サイズ上限（ARG_MAX 等）を超えると python 起動自体が失敗し、
#     `set -e` の下で hook がそのまま非ゼロ終了し「非ブロック」契約を破る恐れがあった。
#     W2) session_id を未検証のままマーカーファイル名へ直接連結しており、`../` や改行を含む
#     session_id が渡された場合に cache ディレクトリ外への書き込み・パス崩れの恐れがあった。
#   - 守るべき業務ルール: hook は入力の大きさ・形に関わらず非ブロック（exit 0）を維持する。
#     マーカーファイル名は固定長・既知文字集合（hex）に限定する。
#   - 他案不採用理由:
#     1) HOOK_INPUT 環境変数のサイズを事前に truncate する案は、キーワード検知の対象文字列を
#        欠落させ検知精度を落とすため不採用。
#     2) session_id をパス構成前に正規表現でサニタイズするだけの案は、サニタイズ漏れの regex が
#        将来再発しうるため不採用。ハッシュ化なら入力形状に関わらず固定長・安全な文字集合になる。
#     3) `python3 - <<'PY' ... PY` のままスクリプトも RAW_INPUT も両方 stdin に載せる案は、
#        ヒアドキュメント（python のプログラム本体）とパイプ（データ）が同じ stdin を奪い合い
#        ヒアドキュメントが勝つため、sys.stdin.read() が常に空文字列になり検知が壊れる
#        （実装直後に発覚・プロセス置換へ切替）。
# 対応: python スクリプト本体はヒアドキュメントのままプロセス置換 `<(...)` でファイル引数として
#   渡し、stdin は RAW_INPUT 専用に空ける。session_id は python 内で hashlib.sha256 により
#   固定長 hex へ変換してから marker ファイル名に使う（python3 は本 hook が既に前提としており、
#   shasum/openssl 等の外部コマンド追加より依存が増えない）。`set -e` は撤去し、失敗時も
#   明示的に exit 0 へ抜ける fail-open を徹底する。
#
# [2026-08-11][feat] Fable 大量読み継続リマインダー追補（ctx-save プラン承認・柱1）
# 背景:
#   - ユーザー依頼意図: 監督（Fable）が委譲判定を宣言した後でも、そのまま自分で大量の
#     Read/Grep を続けて $200 プランの週間利用ペースを浪費するケースを、既存の実装意図
#     キーワード検知（HIT）とは独立に非ブロックで気づけるようにしたい。週間利用上限を
#     1日10%ペースへ抑える ctx-save プランの一環。
#   - 守るべき業務ルール: 非ブロック維持は絶対条件（exit code でブロックしない）。
#     「直近50件のtool_useブロック」の単位は種別問わず（Read/Grep以外の tool_use も
#     カウント対象に含めて母数を数え、その中で Read/Grep 系が何回かを見る）。
#     transcript の message.model からモデルを特定できない場合は、モデル条件（①）を外し
#     大量読みの事実（②）だけで発火する（判定不能を「発火しない」側へ倒すと、Fable
#     セッションを取りこぼすリスクの方が高いため）。閾値はハードコード分散させず
#     スクリプト冒頭の環境変数（DELEGATION_REMINDER_TOOL_WINDOW /
#     DELEGATION_REMINDER_READ_GREP_THRESHOLD / DELEGATION_REMINDER_CHAR_THRESHOLD）に集約する。
#   - 他案不採用理由:
#     1) 別 hook ファイルに分離する案は、UserPromptSubmit の transcript_path 取得・
#        session throttle・fail-open 実装が HIT 検知と重複するため不採用（同一 hook に相乗り）。
#     2) 判定不能時に発火しない（安全側＝黙る）案は、model フィールドが取れない環境で
#        Fable セッションの大量読みを恒久的に見逃すため不採用。
# 対応: 既存 HIT（実装意図キーワード）判定と独立した HEAVYHIT（Fable 大量読み）判定を追加し、
#   別マーカー（$SESSION_HASH-heavy-read）でセッション1回スロットルする。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# telemetry-lib.sh が無い配布先でも壊れない no-op fallback（台帳F7: 発火時に相乗り記録）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }

# [2026-08-11][feat] Fable 大量読み継続検知の閾値。環境変数で上書き可（ハードコード分散防止）。
: "${DELEGATION_REMINDER_TOOL_WINDOW:=50}"
: "${DELEGATION_REMINDER_READ_GREP_THRESHOLD:=20}"
: "${DELEGATION_REMINDER_CHAR_THRESHOLD:=50000}"
# [2026-08-11][fix] codexレビュー対応（PR #1585 🟡）: transcript readlines() 全量読み込みの
# メモリ・レイテンシコスト対策。末尾何バイトだけ読むかの上限（既定5MB）。
: "${DELEGATION_REMINDER_MAX_BYTES:=5242880}"
export DELEGATION_REMINDER_TOOL_WINDOW DELEGATION_REMINDER_READ_GREP_THRESHOLD DELEGATION_REMINDER_CHAR_THRESHOLD DELEGATION_REMINDER_MAX_BYTES

RAW_INPUT="$(cat 2>/dev/null || true)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# [2026-08-13][fix] #1701: runtime marker をリポ外 XDG cache へ移し git dirty を防ぐ。
# shellcheck source=../lib/delegation-reminder-cache.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/delegation-reminder-cache.sh"
CACHE_DIR="$(resolve_delegation_reminder_cache_dir "$PROJECT_DIR")"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# 古いマーカーの軽量清掃（7日超を削除。context-size-cache 系と同様ローカル状態のみ）。
if [ -d "$CACHE_DIR" ]; then
  find "$CACHE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
fi

# python スクリプト本体（プロセス置換でファイル引数として渡す。stdin は RAW_INPUT 専用）。
DELEGATION_REMINDER_PY() {
  cat <<'PY'
import hashlib
import json
import os
import re
import sys


def prompt_from_payload(text: str) -> str:
    if not text.strip():
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return text
    if not isinstance(payload, dict):
        return ""
    for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
        value = payload.get(key)
        if isinstance(value, str):
            return value
    nested = payload.get("tool_input")
    if isinstance(nested, dict):
        for key in ("user_prompt", "userPrompt", "prompt", "message", "text"):
            value = nested.get(key)
            if isinstance(value, str):
                return value
    return ""


def session_hash_from_payload(text: str) -> str:
    if not text.strip():
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return ""
    if not isinstance(payload, dict):
        return ""
    for key in ("session_id", "sessionId"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            # [2026-08-11][fix] codexレビュー W2: 未検証の session_id を marker ファイル名へ
            # 直接連結すると `../` や改行等で cache 外書込みの恐れがある。sha256 で固定長 hex
            # 文字列へ変換してから使う（path traversal に使える文字を構造的に排除する）。
            return hashlib.sha256(value.encode("utf-8", errors="surrogatepass")).hexdigest()
    return ""


def transcript_path_from_payload(text: str) -> str:
    if not text.strip():
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return ""
    if not isinstance(payload, dict):
        return ""
    value = payload.get("transcript_path")
    return value if isinstance(value, str) else ""


# [2026-08-11][feat] Fable 大量読み継続検知（台帳F8 と同じ二重管理防止方針）。
# 「直近50件のtool_useブロック」の単位定義（本 hook と test 双方で同じ定義を使う）:
#   transcript(JSONL)を先頭行から走査し、各行の message.content
#   （message ラッパーが無いフラット形式なら content 直下。既存
#   hook-library/lib/quality-check-common.sh の transcript fixture 様式とも互換）から
#   type=="tool_use" のブロックを出現順に収集し、末尾から window 件（既定50・
#   Read/Grep に限らずツール種別を問わない）を対象窓とする。窓内で Read/Grep 系ツール
#   （READ_GREP_TOOL_NAMES）が何回出たか、窓内の tool_use に対応する tool_result の
#   出力文字数の合計がいくつかを見る。
READ_GREP_TOOL_NAMES = frozenset({"Read", "Grep", "Glob", "NotebookRead"})


def _content_length(raw_content) -> int:
    if isinstance(raw_content, str):
        return len(raw_content)
    if isinstance(raw_content, list):
        total = 0
        for item in raw_content:
            if isinstance(item, dict):
                text_value = item.get("text")
                if isinstance(text_value, str):
                    total += len(text_value)
            elif isinstance(item, str):
                total += len(item)
        return total
    return 0


def _load_transcript_events(path: str, max_bytes: int = None):
    """transcript(JSONL) から tool_use / tool_result ブロックを出現順に抽出する。
    戻り値: (events, models)。
      events: {"kind": "tool_use", "name": str, "id": str} または
              {"kind": "tool_result", "tool_use_id": str, "length": int} の列（出現順）。
      models: assistant message.model として観測された文字列の列（判定不能時は空リスト）。
    ファイル欠落・破損行は無視する（fail-open。空リストを返すだけで例外を投げない）。

    [2026-08-11][fix] codexレビュー対応（PR #1585 🟡）: readlines() によるファイル全量読み込みは、
    長時間セッションの巨大 transcript（数十〜数百MB）でメモリ・時間コストが線形に膨らみ、
    UserPromptSubmit hook のレイテンシ悪化・非ブロック契約の実質破綻（極端に遅い＝体験上ブロックと
    同じ）を招く恐れがあった。判定に必要なのは「末尾側の直近 window 件の tool_use」だけであり、
    ファイル先頭からの全量走査は不要。①通常ファイルか確認（os.path.isfile）②サイズ上限
    （既定 DELEGATION_REMINDER_MAX_BYTES=5MB）を超える場合は末尾 max_bytes 分だけ読む（先頭の
    不完全な1行は破棄）③以降は既存どおり出現順で tool_use/tool_result を抽出する。
    他案不採用理由: mmap 等でのランダムアクセス走査は、JSONL の行境界を安全に見つける実装が
    複雑になる割に、tail読み+破棄で十分な精度（既定5MBは50件のtool_useブロックを含むに十分）
    のため不採用。
    """
    events = []
    models = []
    if not path:
        return events, models
    if max_bytes is None:
        max_bytes = _positive_int_env("DELEGATION_REMINDER_MAX_BYTES", 5 * 1024 * 1024)
    try:
        if not os.path.isfile(path):
            return events, models
        file_size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if max_bytes > 0 and file_size > max_bytes:
                fh.seek(file_size - max_bytes)
                raw_bytes = fh.read()
                # seek位置は行途中の可能性があるため、先頭の不完全な1行は破棄する。
                first_newline = raw_bytes.find(b"\n")
                raw_bytes = raw_bytes[first_newline + 1 :] if first_newline != -1 else b""
            else:
                raw_bytes = fh.read()
        lines = raw_bytes.decode("utf-8", errors="ignore").splitlines()
    except Exception:
        return events, models

    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            entry = json.loads(raw_line)
        except Exception:
            continue
        if not isinstance(entry, dict):
            continue
        # 実 transcript は {"message": {"role":..., "model":..., "content":[...]}}} が標準形。
        # message ラッパーが無いフラット形式（quality-check-common.sh 系 fixture）も許容する。
        message = entry.get("message")
        if not isinstance(message, dict):
            message = entry
        model_value = message.get("model")
        if isinstance(model_value, str) and model_value:
            models.append(model_value)
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            block_type = block.get("type")
            if block_type == "tool_use":
                name = block.get("name")
                tool_id = block.get("id")
                events.append(
                    {
                        "kind": "tool_use",
                        "name": name if isinstance(name, str) else "",
                        "id": tool_id if isinstance(tool_id, str) else "",
                    }
                )
            elif block_type == "tool_result":
                tool_use_id = block.get("tool_use_id")
                events.append(
                    {
                        "kind": "tool_result",
                        "tool_use_id": tool_use_id if isinstance(tool_use_id, str) else "",
                        "length": _content_length(block.get("content")),
                    }
                )
    return events, models


def _positive_int_env(name: str, default: int) -> int:
    raw_value = os.environ.get(name, "")
    try:
        value = int(raw_value)
        return value if value > 0 else default
    except Exception:
        return default


def evaluate_heavy_read(transcript_path: str) -> bool:
    window_size = _positive_int_env("DELEGATION_REMINDER_TOOL_WINDOW", 50)
    read_grep_threshold = _positive_int_env("DELEGATION_REMINDER_READ_GREP_THRESHOLD", 20)
    char_threshold = _positive_int_env("DELEGATION_REMINDER_CHAR_THRESHOLD", 50000)

    events, models = _load_transcript_events(transcript_path)
    tool_uses = [e for e in events if e["kind"] == "tool_use"]
    window = tool_uses[-window_size:] if window_size > 0 else tool_uses
    window_ids = {e["id"] for e in window if e["id"]}

    read_grep_count = sum(1 for e in window if e["name"] in READ_GREP_TOOL_NAMES)
    total_chars = sum(
        e["length"]
        for e in events
        if e["kind"] == "tool_result" and e["tool_use_id"] in window_ids
    )

    heavy_read = read_grep_count >= read_grep_threshold or total_chars > char_threshold
    if not heavy_read:
        return False

    if models:
        # 判定①: message.model に "fable" を含むかどうか（大小文字を区別しない）。
        return any("fable" in m.lower() for m in models)
    # 判定不能時（message.model が一件も取れない）はモデル条件を外し、
    # 大量読みの事実だけで共通文言へフォールバックする。
    return True


def main() -> None:
    raw = sys.stdin.read()

    # 実装意図キーワード。出典: `.claude/rules/general/ai-model-selection.md` §4 /
    # `skills/agent-dispatch` 境界の実装トリガー語。境界正本改訂時はこの配列も同一PRで追従する
    # （台帳F8）。語の追加・変更はここ単独ではなく境界正本と揃えること（二重管理防止）。
    impl_keywords = [
        "実装", "実装して", "修正", "直して", "直す", "作って", "作る",
        "追加して", "追加", "進めて", "進める", "リファクタ", "改修", "組み込んで", "書いて",
    ]
    impl_re = re.compile("|".join(re.escape(w) for w in impl_keywords))

    prompt = prompt_from_payload(raw)
    session_hash = session_hash_from_payload(raw)
    transcript_path = transcript_path_from_payload(raw)

    hit = bool(impl_re.search(prompt))
    heavy_hit = evaluate_heavy_read(transcript_path)

    print("HIT=1" if hit else "HIT=0")
    print(f"SESSION={session_hash}")
    print("HEAVYHIT=1" if heavy_hit else "HEAVYHIT=0")


try:
    main()
except Exception:
    # fail-open: 解析に失敗しても必ず無害な出力で終える（呼び出し元は無音で exit 0）。
    print("HIT=0")
    print("SESSION=")
    print("HEAVYHIT=0")
PY
}

RESULT="$(printf '%s' "$RAW_INPUT" | command python3 <(DELEGATION_REMINDER_PY) 2>/dev/null)"
RESULT_STATUS=$?
if [ "$RESULT_STATUS" -ne 0 ]; then
  # python 実行自体が失敗しても非ブロックを維持する（fail-open）。
  exit 0
fi

HIT="$(printf '%s\n' "$RESULT" | sed -n 's/^HIT=//p')"
SESSION_HASH="$(printf '%s\n' "$RESULT" | sed -n 's/^SESSION=//p')"
HEAVY_HIT="$(printf '%s\n' "$RESULT" | sed -n 's/^HEAVYHIT=//p')"

# 実装意図キーワード検知（HIT）。セッション ID が取れない場合はスロットルできないため、
# その場で1回だけ出して抜ける（マーカーは書かない。次回プロンプトでも同じ判定になり得るが
# 非ブロックなので実害は小さい）。
if [ "$HIT" = "1" ]; then
  if [ -z "$SESSION_HASH" ]; then
    cat <<'MSG'
【三役体制】着手前に委譲判定を1行宣言してから進めること: ①10分未満の小修正/ガバナンス領域/対話型ブラウザ軽作業(claude-in-chrome)→Claudeサブエージェント内製（ブラウザは sonnet 第一候補・Fable直禁止） ②まとまった実装・並列・大量読み→AI worker（agent-dispatch） ③調査: 小=context-engine直・中大=参謀Kimi ④緊急時のみ利用者の明示指示でPM直実装（解消後は委譲へ自動復帰）。PM本体のinline実装は原則禁止。
MSG
  else
    MARKER="$CACHE_DIR/$SESSION_HASH"
    if [ ! -f "$MARKER" ]; then
      cat <<'MSG'
【三役体制】着手前に委譲判定を1行宣言してから進めること: ①10分未満の小修正/ガバナンス領域/対話型ブラウザ軽作業(claude-in-chrome)→Claudeサブエージェント内製（ブラウザは sonnet 第一候補・Fable直禁止） ②まとまった実装・並列・大量読み→AI worker（agent-dispatch） ③調査: 小=context-engine直・中大=参謀Kimi ④緊急時のみ利用者の明示指示でPM直実装（解消後は委譲へ自動復帰）。PM本体のinline実装は原則禁止。
MSG
      : > "$MARKER" 2>/dev/null || true
      agent_hub_telemetry_log "delegation_reminder" "delegation-routing-reminder" "fired" "" 2>/dev/null || true
    fi
  fi
fi

# [2026-08-11][feat] Fable 大量読み継続検知（HEAVYHIT）。HIT とは独立の判定・独立のマーカーで
# セッション1回スロットルする（同一プロンプトで両方出ることもあれば片方だけのこともある）。
if [ "$HEAVY_HIT" = "1" ]; then
  if [ -z "$SESSION_HASH" ]; then
    cat <<'MSG'
【三役体制】大量読みが続いています。参謀 Kimi / worker への委譲を検討してください。
MSG
  else
    HEAVY_MARKER="$CACHE_DIR/$SESSION_HASH-heavy-read"
    if [ ! -f "$HEAVY_MARKER" ]; then
      cat <<'MSG'
【三役体制】大量読みが続いています。参謀 Kimi / worker への委譲を検討してください。
MSG
      : > "$HEAVY_MARKER" 2>/dev/null || true
      agent_hub_telemetry_log "delegation_reminder" "delegation-routing-reminder-heavy-read" "fired" "" 2>/dev/null || true
    fi
  fi
fi

exit 0
