#!/bin/bash
# PreToolUse(Write) hook for JTT UI 部品さがし案内。
# Quiet by default: prints only when a NEW UI component file is being created
# (component-ish dir + component extension, file not yet on disk), and only once
# per session (marker under XDG cache). Non-blocking (always exit 0), no AI calls.
#
# [2026-10-11][feat] JTT共通UIレジストリ（決めごと 6A・8A）。
# 背景:
#   - ユーザー依頼意図: UIを頼んだ時に各PJのAIが「PJ内の既存部品 → JTT共通部品 → 公式素材」を
#     確かめずにゼロから作ることを、書き込み直前の軽い案内で予防したい。止めるのは書き写しと
#     記録なしの書き換え（ci-check）の2つだけで、ここは案内のみ。
#   - 守るべき業務ルール: 常に exit 0（fail-open）。AI・重いモデルは呼ばない。文言や対象の
#     見分け方は hook-library/lib/ui-registry-policy.json を正本とし、スクリプトへ埋め込まない。
#     マーカーはリポ外の XDG cache（delegation-reminder-cache と同型）で git dirty にしない。
#   - 他案不採用理由:
#     1) deny で止める案は、新規PJや既存PJ（ぐちゃぐちゃ）でも毎回手間が出るため不採用（6A）。
#     2) UserPromptSubmit で出す案は、部品を作るかどうかが書き込み直前まで分からず誤発火が
#        多いため不採用（Write の file_path なら新規画面部品だけに絞れる）。
# 対応: PreToolUse Write|Edit|MultiEdit で file_path を見て、存在しない画面部品ファイルへの
#   Write の時だけ案内を出す（Edit/MultiEdit は既存ファイル前提のため実質 Write にしか出ない）。
#   session_id が取れない時はスロットルせずそのまま出す（非ブロックなので実害は小さい）。
#   python 本体はヒアドキュメントを関数経由でプロセス置換に載せ、stdin を payload 専用にする
#   （delegation-routing-reminder.sh の W3 教訓と同型）。

set -uo pipefail

RAW_INPUT="$(cat 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HOOK_LIB_DIR="${HOOK_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd || true)}"

# XDG cache 配下に PJ ハッシュ→セッションハッシュのマーカーを置く（repo を汚さない）。
MARKER_DIR=""
project_key=""
if command -v shasum >/dev/null 2>&1; then
  project_key="$(printf '%s' "$PROJECT_DIR" | shasum -a 256 2>/dev/null | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  project_key="$(printf '%s' "$PROJECT_DIR" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
fi
if [ -n "$project_key" ]; then
  MARKER_DIR="${UI_REGISTRY_PREFLIGHT_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/agent-hub/hooks/ui-registry-preflight}/${project_key}"
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  find "$MARKER_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
fi

UI_REGISTRY_PREFLIGHT_PY() {
  cat <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

raw = sys.stdin.read()
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    payload = {}
if not isinstance(payload, dict):
    sys.exit(0)

tool_input = {}
for key in ("tool_input", "toolInput", "arguments"):
    candidate = payload.get(key)
    if isinstance(candidate, dict):
        tool_input = candidate
        break
file_path = tool_input.get("file_path") or tool_input.get("path") or tool_input.get("filePath") or ""
if not isinstance(file_path, str) or not file_path:
    sys.exit(0)

# 判定データの正本は lib/ui-registry-policy.json だけ（二重化して文言がずれるのを防ぐ）。
# 読めない・必須キーが無い時は案内せず黙って抜ける（fail-open は維持）。
policy_path = Path(os.environ.get("HOOK_LIB_DIR", "")) / "ui-registry-policy.json"
try:
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
if not isinstance(policy, dict) or not all(
        k in policy for k in ("component_dirs", "component_extensions", "exclude_substrings", "message")):
    sys.exit(0)

name = file_path.replace("\\", "/").rsplit("/", 1)[-1]
if not any(name.endswith(ext) for ext in policy["component_extensions"]):
    sys.exit(0)
if any(part in name for part in policy["exclude_substrings"]):
    sys.exit(0)
if not any(part in policy["component_dirs"] for part in file_path.replace("\\", "/").split("/")):
    sys.exit(0)
if os.path.exists(file_path):
    sys.exit(0)  # 既存ファイルの編集は「新しい部品」ではない

# 作業（セッション）ごとに1回。session_id が無い時はスロットルせず出す。
session_id = payload.get("session_id") or payload.get("sessionId") or ""
marker_dir = os.environ.get("MARKER_DIR", "")
if session_id and marker_dir:
    session_key = hashlib.sha256(str(session_id).encode("utf-8")).hexdigest()
    marker = Path(marker_dir) / session_key
    if marker.exists():
        sys.exit(0)
    print(policy["message"])
    try:
        marker.touch()
    except Exception:
        pass
else:
    print(policy["message"])
sys.exit(0)
PY
}

printf '%s' "$RAW_INPUT" | HOOK_LIB_DIR="$HOOK_LIB_DIR" MARKER_DIR="$MARKER_DIR" command python3 <(UI_REGISTRY_PREFLIGHT_PY) 2>/dev/null || true

exit 0
