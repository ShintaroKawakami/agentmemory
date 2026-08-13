#!/usr/bin/env bash
# telemetry-lib.sh — shared harness telemetry function.
#
# Provides: agent_hub_telemetry_log <event_type> <name> <outcome> [meta_json]
#
# 絶対方針: fail-open。
#   - いかなるエラーでも exit 0・ブロックしない・stdout に出力しない。
#   - git / date / python3 / mkdir のいずれかが欠損・失敗しても黙って return 0。
#   - AGENT_HUB_TELEMETRY_DISABLE=1 で完全無効化(何もしない)。
#   - 外部ネットワーク不使用。ローカル JSONL 追記のみ。
#
# 他 hook からの読み込み(配布先で lib が無くても壊さない no-op fallback):
#   . "$(dirname "$0")/telemetry-lib.sh" 2>/dev/null || agent_hub_telemetry_log(){ :; }
#
# 出力先: ${AGENT_HUB_TELEMETRY_DIR:-$HOME/.agent-hub/telemetry}/YYYY-MM-DD.jsonl
# レコード: {"ts","tool","pj","event_type","name","outcome","meta"}

# 注意: 本ファイルは他 hook から `source` されるため set -e を使わない。
# 呼び出し元(block-main-commit.sh 等)が set -euo pipefail を設定済みの場合、
# ここでの未定義変数や失敗コマンドは親の set -e で source 全体を中断しうる。
# そのため全ての変数参照は ${VAR:-} 形式とし、外部コマンドは || true で包む。

agent_hub_telemetry_log() {
  # fail-open: 無効化フック
  [ "${AGENT_HUB_TELEMETRY_DISABLE:-0}" = "1" ] && return 0

  local event_type="${1:-}"
  local name="${2:-}"
  local outcome="${3:-}"
  local meta_json="${4:-}"

  # 引数不足でも黙って返す(ブロックしない)
  [ -z "$event_type" ] && return 0

  # 出力ディレクトリ解決(環境変数で上書き可。テスト用)
  local base_dir="${AGENT_HUB_TELEMETRY_DIR:-${HOME:-}/.agent-hub/telemetry}"
  local date_str
  date_str="$(date +%Y-%m-%d 2>/dev/null || echo unknown)"
  [ -z "$date_str" ] && date_str="unknown"
  local out_file="$base_dir/$date_str.jsonl"

  # ディレクトリ作成(失敗は無視 → 後段の追記も失敗して return 0 に至る)
  [ -d "$base_dir" ] || mkdir -p "$base_dir" 2>/dev/null || true

  # pj 解決(優先順: 環境変数 > CLAUDE_PROJECT_DIR > git root basename > PWD basename)
  local pj="${AGENT_HUB_TELEMETRY_PJ:-}"
  if [ -z "$pj" ]; then
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
      pj="${CLAUDE_PROJECT_DIR##*/}"
    else
      local git_root=""
      git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      if [ -n "$git_root" ]; then
        pj="${git_root##*/}"
      else
        pj="${PWD##*/}"
      fi
    fi
  fi
  [ -z "$pj" ] && pj="unknown"

  # ISO8601 UTC タイムスタンプ
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

  # [2026-07-07][feat] harness phaseB: telemetry tool名を T_TOOL 由来で上書き可にする
  local tool="${T_TOOL:-claude-code}"

  # JSON 1 行を組み立てて追記(python3 で値を escape-safe に)。
  # python3 が無い環境では純 bash で最小エスケープして追記する(fail-open)。
  if command -v python3 >/dev/null 2>&1; then
    T_EVENT="$event_type" \
    T_NAME="$name" \
    T_OUTCOME="$outcome" \
    T_PJ="$pj" \
    T_TOOL="$tool" \
    T_TS="$ts" \
    T_META="$meta_json" \
    T_OUT="$out_file" \
    python3 - <<'PY' 2>/dev/null || true
import json
import os


def as_str(value: str) -> str:
    return value if isinstance(value, str) else ""


meta_raw = os.environ.get("T_META", "")
meta_value = {}
if meta_raw:
    try:
        decoded = json.loads(meta_raw)
        if isinstance(decoded, dict):
            meta_value = decoded
        else:
            meta_value = {"value": decoded}
    except Exception:
        # JSON でなければ文字列として保持(破損させない)
        meta_value = {"raw": meta_raw}

record = {
    "ts": as_str(os.environ.get("T_TS", "")),
    "tool": as_str(os.environ.get("T_TOOL", "claude-code")),
    "pj": as_str(os.environ.get("T_PJ", "")),
    "event_type": as_str(os.environ.get("T_EVENT", "")),
    "name": as_str(os.environ.get("T_NAME", "")),
    "outcome": as_str(os.environ.get("T_OUTCOME", "")),
    "meta": meta_value,
}

out_path = os.environ.get("T_OUT", "")
if not out_path:
    raise SystemExit(0)

try:
    with open(out_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
except Exception:
    pass
PY
  else
    # python3 無し: JSON パーサ/シリアライザが無いため meta_json を構造化オブジェクトとして
    # 安全に組み込めない。
    # [2026-07-04][fix] Codexレビュー対応(PR #670 🟡1):
    #   背景: 旧実装は meta_json(呼び出し元が渡す生JSON片、例 {"label":"foo"})に対して
    #     文字列用の _telemetry_escape をそのまま適用したうえで "meta":%s (無クォート)へ
    #     埋め込んでいた。meta_json 内にダブルクォート/バックスラッシュが含まれると
    #     エスケープと JSON 構造が二重に競合し、不正な JSONL 行になり得た。
    #   守るべき業務ルール: telemetry は fail-open かつ JSONL を絶対に壊さない。
    #   他案不採用理由: meta_json を素朴な文字列置換で「JSON オブジェクトとして」再構築する案は、
    #     ネスト・エスケープの全パターンを網羅できずシェルだけでの安全な JSON 生成は非現実的なため不採用。
    # 対応: python3 無し環境では meta は常に空オブジェクト{}に固定し、元データは
    #   meta_raw に「文字列値」として安全にエスケープして退避する(構造は壊さず、情報も欠落させない)。
    _telemetry_escape() {
      local s="$1"
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      s="${s//$'\n'/ }"
      s="${s//$'\r'/ }"
      s="${s//$'\t'/ }"
      printf '%s' "$s"
  }
    if [ -n "$meta_json" ]; then
      printf '{"ts":"%s","tool":"%s","pj":"%s","event_type":"%s","name":"%s","outcome":"%s","meta":{},"meta_raw":"%s"}\n' \
        "$(_telemetry_escape "$ts")" \
        "$(_telemetry_escape "$tool")" \
        "$(_telemetry_escape "$pj")" \
        "$(_telemetry_escape "$event_type")" \
        "$(_telemetry_escape "$name")" \
        "$(_telemetry_escape "$outcome")" \
        "$(_telemetry_escape "$meta_json")" \
        >> "$out_file" 2>/dev/null || true
    else
      printf '{"ts":"%s","tool":"%s","pj":"%s","event_type":"%s","name":"%s","outcome":"%s","meta":{}}\n' \
        "$(_telemetry_escape "$ts")" \
        "$(_telemetry_escape "$tool")" \
        "$(_telemetry_escape "$pj")" \
        "$(_telemetry_escape "$event_type")" \
        "$(_telemetry_escape "$name")" \
        "$(_telemetry_escape "$outcome")" \
        >> "$out_file" 2>/dev/null || true
    fi
  fi

  return 0
}
