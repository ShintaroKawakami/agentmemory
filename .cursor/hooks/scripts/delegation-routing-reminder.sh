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
#
# [2026-08-27][feat] クレジット残量条件の相乗り（非ブロック維持・日付+閾値帯マーカー）
# 背景:
#   - ユーザー依頼意図: Claude の週次クレジットを使い切りそうなのに、Claude 自身が実装を続ける
#     状況を止められない。実測（2026-08-27）で Claude 週次 62% 使用・リセット前に尽きる見込み。
#     職人メインの GLM は 2% しか使われていなかった。キャッシュから残量を読み、閾値超過時に
#     委譲を促す文言を追加したい。
#   - 守るべき業務ルール: 非ブロック（全経路で exit 0）を絶対に維持する。
#     数値閾値は agents.yaml からライブ読みし、スクリプトに直書きしない。
#     キャッシュが無い・壊れている・routes.claude が無い・agents.yaml が読めない場合は、
#     残量部分を出さずに従来どおりの文言だけを出す。エラーメッセージは出さない。
#     キャッシュが cache_ttl_seconds より古くても値は使う（「N分前」の情報として扱う）。
#     ただし 24 時間以上古い場合は残量部分を出さない。
#     マーカーは「日付 + 閾値帯（none/warn/strong）」単位で、同じ日に同じ帯なら 1 回だけ、
#     帯が上がったら再度通知する。既存のセッション1回スロットルはそのまま維持する。
#   - 他案不採用理由:
#     1) hook から codexbar を直接実行する案は、1 回 1〜3 秒かかり毎プロンプトで待たされるため
#        不採用（キャッシュ読みのみ）。
#     2) 残量超過で実装をブロックする案は、正当な小修正まで止める誤爆コストが高いため不採用
#        （まず非ブロックで観測する）。
# 対応: agents.yaml から閾値を読み、credit-usage.json キャッシュから routes.claude.weekly を
#   取得して、warn/strong の帯に応じた文言を既存メッセージに追記する。
#   マーカーは $CACHE_DIR/$DATE_HASH-tier で日付+閾値帯単位スロットルする。

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

# [2026-08-27][feat] クレジット残量キャッシュ・閾値読み取り（fail-open）。
# agents.yaml から閾値を読み、credit-usage.json から routes.claude.weekly を取得する。
# どちらか欠けてもエラーを出さず、残量機能を黙って無効化する。
AGENTS_YAML_PATH="${AGENTS_YAML_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")/agents.yaml}"
CREDIT_CACHE_PATH="${CREDIT_CACHE_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-hub/credit-usage.json}"

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


# [2026-08-27][feat] クレジット残量関連の読み取り（fail-open）。
def _read_yaml_value(text: str, *keys: str) -> any:
    """単純な YAML パーサ: キー階層を辿って値を返す。見つからなければ None。"""
    if not text:
        return None
    lines = text.splitlines()
    indent_stack = [(-1, {})]
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        indent = len(line) - len(stripped)
        # コロンで分割
        if ":" not in stripped:
            i += 1
            continue
        key, rest = stripped.split(":", 1)
        key = key.strip()
        rest = rest.strip()
        # 階層を調整
        while indent_stack and indent_stack[-1][0] >= indent:
            indent_stack.pop()
        if not indent_stack:
            indent_stack = [(-1, {})]
        current_dict = indent_stack[-1][1]
        if rest == "":
            # 次の行がインデント深いなら新しい dict
            new_dict = {}
            current_dict[key] = new_dict
            indent_stack.append((indent, new_dict))
        else:
            # 値が同じ行にある
            # 文字列リテラルの引用符を外す
            if (rest.startswith('"') and rest.endswith('"')) or (rest.startswith("'") and rest.endswith("'")):
                rest = rest[1:-1]
            # 数値変換を試みる
            try:
                if "." in rest:
                    current_dict[key] = float(rest)
                else:
                    current_dict[key] = int(rest)
            except Exception:
                current_dict[key] = rest
        i += 1
    # キー階層を辿る
    current = indent_stack[0][1] if indent_stack else {}
    for k in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(k)
        if current is None:
            return None
    return current


def load_credit_thresholds(agents_yaml_path: str) -> tuple[int, int] | None:
    """agents.yaml から claude_weekly_warn_percent / claude_weekly_strong_percent を読む。
    読めなければ None（残量機能を無効化）。"""
    try:
        with open(agents_yaml_path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return None
    warn = _read_yaml_value(text, "worker_delegation", "credit_preflight", "claude_weekly_warn_percent")
    strong = _read_yaml_value(text, "worker_delegation", "credit_preflight", "claude_weekly_strong_percent")
    if warn is None or strong is None:
        return None
    try:
        warn_int = int(warn)
        strong_int = int(strong)
    except Exception:
        return None
    return warn_int, strong_int


def load_credit_usage(cache_path: str) -> tuple[int, list[str]] | None:
    """credit-usage.json から routes.claude.weekly と空き worker 名リストを読む。
    24時間以上古い場合は None。読めなければ None。"""
    try:
        with open(cache_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    updated_at_str = data.get("updatedAt")
    if updated_at_str:
        try:
            from datetime import datetime, timezone
            updated_at = datetime.fromisoformat(updated_at_str.replace("Z", "+00:00"))
            now = datetime.now(timezone.utc)
            if (now - updated_at).total_seconds() >= 86400:
                return None
        except Exception:
            return None
    routes = data.get("routes")
    if not isinstance(routes, dict):
        return None
    claude_info = routes.get("claude")
    if not isinstance(claude_info, dict):
        return None
    weekly = claude_info.get("weekly")
    if weekly is None:
        return None
    try:
        weekly_int = int(weekly)
    except Exception:
        return None
    # 空いている worker 名を usedPercent が小さい順に 2〜3 個（claude 自身を除く）
    candidates = []
    for name, info in routes.items():
        if name == "claude":
            continue
        if isinstance(info, dict):
            used = info.get("usedPercent")
            if used is not None:
                try:
                    candidates.append((int(used), name))
                except Exception:
                    pass
    candidates.sort(key=lambda x: x[0])
    free_workers = [name for _, name in candidates[:3]]
    return weekly_int, free_workers


def credit_tier(weekly: int, warn: int, strong: int) -> str:
    if weekly >= strong:
        return "strong"
    if weekly >= warn:
        return "warn"
    return "none"


def date_hash() -> str:
    from datetime import datetime, timezone
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return hashlib.sha256(today.encode("utf-8")).hexdigest()


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

    # [2026-08-27][feat] クレジット残量読み取り
    agents_yaml_path = os.environ.get("AGENTS_YAML_PATH", "")
    credit_cache_path = os.environ.get("CREDIT_CACHE_PATH", "")
    credit_line = ""
    tier = "none"
    if agents_yaml_path and credit_cache_path:
        thresholds = load_credit_thresholds(agents_yaml_path)
        usage = load_credit_usage(credit_cache_path)
        if thresholds is not None and usage is not None:
            warn_p, strong_p = thresholds
            weekly, free_workers = usage
            tier = credit_tier(weekly, warn_p, strong_p)
            if tier == "strong":
                workers_str = ", ".join(free_workers) if free_workers else "AI worker"
                credit_line = f"⛔ Claude 週次 {weekly}% 使用。Claude 直実装をやめ、{workers_str} へ委譲してください。"
            elif tier == "warn":
                workers_str = ", ".join(free_workers) if free_workers else "AI worker"
                credit_line = f"Claude 週次 {weekly}% 使用。実装は {workers_str} へ委譲してください。"

    print("HIT=1" if hit else "HIT=0")
    print(f"SESSION={session_hash}")
    print("HEAVYHIT=1" if heavy_hit else "HEAVYHIT=0")
    print(f"CREDIT_TIER={tier}")
    if credit_line:
        print(f"CREDIT_LINE={credit_line}")


try:
    main()
except Exception:
    # fail-open: 解析に失敗しても必ず無害な出力で終える（呼び出し元は無音で exit 0）。
    print("HIT=0")
    print("SESSION=")
    print("HEAVYHIT=0")
    print("CREDIT_TIER=none")
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
CREDIT_TIER="$(printf '%s\n' "$RESULT" | sed -n 's/^CREDIT_TIER=//p')"
CREDIT_LINE="$(printf '%s\n' "$RESULT" | sed -n 's/^CREDIT_LINE=//p')"

# [2026-08-27][feat] クレジット残量マーカー（日付+閾値帯単位）。
# 既存のセッション1回マーカーとは別ファイル名で混ざらないようにする。
CREDIT_MARKER=""
if [ -n "$CREDIT_TIER" ] && [ "$CREDIT_TIER" != "none" ]; then
  # 日付ハッシュを計算（python と同じ SHA256("YYYY-MM-DD")）
  DATE_HASH="$(printf '%s' "$(date -u +%Y-%m-%d)" | command python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode("utf-8")).hexdigest())' 2>/dev/null)"
  if [ -n "$DATE_HASH" ]; then
    # [2026-08-27][fix] マーカー名へ閾値帯を含める
    # 背景:
    #   - 事象: 名前が日付だけ（${DATE_HASH}-tier）だったため、warn で 1 度出すと同じ日は
    #     strong へ上がっても通知されなかった（「帯が上がったら再通知」の要件を満たしていない）。
    #   - 守るべき業務ルール: スロットルの単位は「日付 + 閾値帯」。帯が上がったら再通知する。
    #   - 他案不採用理由: マーカーへ帯を書き込んで内容比較する案は、読み書きの失敗時に
    #     判定不能となり fail-open/close の分岐が増えるため不採用（ファイル名で表現すれば
    #     存在確認だけで済む）。
    CREDIT_MARKER="$CACHE_DIR/${DATE_HASH}-tier-${CREDIT_TIER}"
  fi
fi

# [2026-08-27][fix] 残量文言のスロットルを 3 経路で共通化する
# 背景:
#   - 事象: HIT / HEAVYHIT の経路が CREDIT_LINE を「セッションマーカーの内側」で出していたため、
#     セッションが変われば同じ日・同じ閾値帯でも残量文言が再び出ていた（PM 実測で
#     「同じ帯の2回目で残量文言が出てしまう」テストが失敗）。日付+閾値帯スロットルが
#     独立通知の経路にしか効いていなかった。
#   - 守るべき業務ルール: 残量文言のスロットルは「日付 + 閾値帯」単位であり、
#     セッション単位ではない（長時間セッション・複数セッションのどちらでも効く必要がある）。
#     閾値帯が上がったら（warn → strong）マーカー名が変わるので再通知される。
#     既存の三役体制メッセージ／大量読みメッセージのセッション1回スロットルは変更しない。
#   - 他案不採用理由: 各経路へ同じ if 文を複製する案は、経路が増えるたびに同じ漏れが再発するため不採用。
#     マーカーをセッション単位に寄せる案は、セッションを開き直すだけで警告が復活し
#     「うるさくしない」要件に反するため不採用。
# 対応: CREDIT_LINE の出力を必ずこの関数へ通し、マーカー確認と書き込みを 1 箇所へ集約する。
#   DATE_HASH が取れずマーカーを決められない場合はスロットルできないため、従来どおり出力する
#   （非ブロック・fail-open の思想に合わせ、黙って情報を落とさない）。
emit_credit_line_once() {
  [ -n "$CREDIT_LINE" ] || return 0
  if [ -n "$CREDIT_MARKER" ]; then
    [ -f "$CREDIT_MARKER" ] && return 0
    printf '%s\n' "$CREDIT_LINE"
    : > "$CREDIT_MARKER" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$CREDIT_LINE"
}

# 実装意図キーワード検知（HIT）。セッション ID が取れない場合はスロットルできないため、
# その場で1回だけ出して抜ける（マーカーは書かない。次回プロンプトでも同じ判定になり得るが
# 非ブロックなので実害は小さい）。
if [ "$HIT" = "1" ]; then
  if [ -z "$SESSION_HASH" ]; then
    cat <<'MSG'
【三役体制】着手前に委譲判定を1行宣言してから進めること: ①10分未満の小修正/ガバナンス領域/対話型ブラウザ軽作業(claude-in-chrome)→Claudeサブエージェント内製（ブラウザは sonnet 第一候補・Fable直禁止） ②まとまった実装・並列・大量読み→AI worker（agent-dispatch） ③調査: 小=context-engine直・中大=参謀Kimi ④緊急時のみ利用者の明示指示でPM直実装（解消後は委譲へ自動復帰）。PM本体のinline実装は原則禁止。
MSG
    emit_credit_line_once
  else
    MARKER="$CACHE_DIR/$SESSION_HASH"
    if [ ! -f "$MARKER" ]; then
      cat <<'MSG'
【三役体制】着手前に委譲判定を1行宣言してから進めること: ①10分未満の小修正/ガバナンス領域/対話型ブラウザ軽作業(claude-in-chrome)→Claudeサブエージェント内製（ブラウザは sonnet 第一候補・Fable直禁止） ②まとまった実装・並列・大量読み→AI worker（agent-dispatch） ③調査: 小=context-engine直・中大=参謀Kimi ④緊急時のみ利用者の明示指示でPM直実装（解消後は委譲へ自動復帰）。PM本体のinline実装は原則禁止。
MSG
      emit_credit_line_once
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
    emit_credit_line_once
  else
    HEAVY_MARKER="$CACHE_DIR/$SESSION_HASH-heavy-read"
    if [ ! -f "$HEAVY_MARKER" ]; then
      cat <<'MSG'
【三役体制】大量読みが続いています。参謀 Kimi / worker への委譲を検討してください。
MSG
      emit_credit_line_once
      : > "$HEAVY_MARKER" 2>/dev/null || true
      agent_hub_telemetry_log "delegation_reminder" "delegation-routing-reminder-heavy-read" "fired" "" 2>/dev/null || true
    fi
  fi
fi

# [2026-08-27][fix] クレジット残量由来の「独立通知」を廃止する
# 背景:
#   - 事象: 実装意図キーワードが無い会話（例:「今日は天気だけ確認」）でも残量文言が鳴る経路を
#     入れていたが、SessionStart の残量パネル（credit-baton-preflight.sh）が毎セッション
#     冒頭で同じ情報を出すため重複する。実装と無関係な会話で鳴るのはノイズにしかならない。
#   - 守るべき業務ルール: 残量は「実装へ着手しようとした瞬間」に判断材料として添える。
#     セッション全体の状況把握は SessionStart パネルが担う（役割を分ける）。
#     pre-implementation-check.sh の 2026-04-26 CaD（毎回大きいリマインダーで体験悪化）を踏襲する。
#   - 他案不採用理由: 独立通知を残したまま日付+帯で 1 日 1 回に絞る案も検討したが、
#     SessionStart パネルと情報が完全に重複するため、経路自体を持たない方が保守が単純。
# 対応: 残量文言は HIT / HEAVYHIT の経路でのみ emit_credit_line_once 経由で出す。

exit 0
