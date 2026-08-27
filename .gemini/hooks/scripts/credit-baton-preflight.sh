#!/usr/bin/env bash
set -u

# [2026-08-27][feat] SessionStart クレジット残量 preflight hook (credit-baton-preflight.sh)
# 背景:
#   - ユーザー依頼意図: セッション開始時に Claude と各 worker のクレジット残量を把握し、
#     Claude の使いすぎを防いで GLM / Gemini / Kimi など各 worker への委譲原則を自律徹底する。
#   - 守るべき業務ルール:
#     1) codexbar は絶対に同期実行しない（キャッシュファイルを読むだけ、古い時はバックグラウンド更新）。
#     2) 数値閾値・設定は agents.yaml からライブ読みする（ハードコード禁止）。
#     3) キャッシュが無い・壊れている・取得不能時は何も表示せず exit 0（非ブロック契約）。
#   - 他案不採用理由:
#     1) hook から codexbar を同期実行する案は、セッション開始遅延（1〜3秒）を招くため不採用。
#     2) 閾値をスクリプトに直書きする案は、変更時に直す場所が分散するため不採用。

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AGENTS_YAML="${AGENTS_YAML_PATH:-$PROJECT_DIR/agents.yaml}"

if [ ! -f "$AGENTS_YAML" ]; then
  exit 0
fi

PREFLIGHT_PY() {
  cat <<'PY'
import os
import sys
import json
from datetime import datetime, timezone

agents_yaml_path = sys.argv[1]
cache_file_override = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""

config = {}
try:
    import yaml
    with open(agents_yaml_path, "r", encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    config = doc.get("worker_delegation", {}).get("credit_preflight", {})
except Exception:
    pass

if not config:
    # fallback parser in case yaml is unavailable
    try:
        with open(agents_yaml_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        in_sec = False
        for line in lines:
            if "credit_preflight:" in line:
                in_sec = True
                continue
            if in_sec:
                if line.strip().startswith("#"):
                    continue
                if not line.startswith("    ") and not line.startswith("\t"):
                    break
                kv = line.strip().split(":", 1)
                if len(kv) == 2:
                    k = kv[0].strip()
                    v = kv[1].strip().strip('"').strip("'")
                    if k in ("cache_ttl_seconds", "claude_weekly_warn_percent", "claude_weekly_strong_percent"):
                        try:
                            config[k] = int(v)
                        except Exception:
                            pass
                    elif k == "cache_path":
                        config[k] = v
                    elif k == "display_routes":
                        try:
                            config[k] = json.loads(v)
                        except Exception:
                            pass
    except Exception:
        pass

if not config:
    sys.exit(0)

raw_cache_path = config.get("cache_path", "~/.cache/agent-hub/credit-usage.json")
cache_file = cache_file_override if cache_file_override else os.path.expanduser(raw_cache_path)
cache_ttl = int(config.get("cache_ttl_seconds", 900))
warn_pct = float(config.get("claude_weekly_warn_percent", 55))
strong_pct = float(config.get("claude_weekly_strong_percent", 75))
display_routes = config.get("display_routes", ["claude", "glm", "antigravity", "kimi", "codex", "cursor", "ocg"])

should_refresh = False
cache_data = None
updated_at_str = ""

if not os.path.exists(cache_file):
    should_refresh = True
else:
    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            cache_data = json.load(f)
        if not isinstance(cache_data, dict) or "routes" not in cache_data or not isinstance(cache_data.get("routes"), dict):
            should_refresh = True
            cache_data = None
        else:
            updated_at_str = cache_data.get("updatedAt", "")
            if not updated_at_str:
                should_refresh = True
            else:
                ts = updated_at_str.replace("Z", "+00:00")
                dt = datetime.fromisoformat(ts)
                now = datetime.now(timezone.utc)
                age = (now - dt).total_seconds()
                if age > cache_ttl:
                    should_refresh = True
    except Exception:
        should_refresh = True
        cache_data = None

# Signal refresh to bash runner
if should_refresh:
    print(f"REFRESH=1|CACHE_FILE={cache_file}")
else:
    print(f"REFRESH=0|CACHE_FILE={cache_file}")

if cache_data is None:
    sys.exit(0)

routes = cache_data.get("routes", {})
if not routes:
    sys.exit(0)

time_label = ""
if updated_at_str:
    try:
        ts = updated_at_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts)
        now = datetime.now(timezone.utc)
        elapsed_sec = max(0, (now - dt).total_seconds())
        elapsed_min = int(elapsed_sec // 60)
        if elapsed_min < 60:
            time_label = f"{elapsed_min}分前"
        else:
            hours = int(elapsed_sec // 3600)
            time_label = f"{hours}時間前"
    except Exception:
        time_label = ""

header = f"⚡ クレジット残量（{time_label}）" if time_label else "⚡ クレジット残量"
lines = [header]

claude_data = routes.get("claude")
claude_weekly_num = None
if isinstance(claude_data, dict):
    claude_weekly = claude_data.get("weekly")
    if claude_weekly is None:
        claude_weekly = claude_data.get("usedPercent")
    claude_will_last = claude_data.get("willLastToReset", True)

    if claude_weekly is not None:
        try:
            claude_weekly_num = float(claude_weekly)
            filled = int(round(claude_weekly_num * 12.0 / 100.0))
            filled = max(0, min(12, filled))
            empty = 12 - filled
            bar = "█" * filled + "░" * empty
            claude_line = f"Claude 週次 {bar} {int(round(claude_weekly_num))}% 使用"
            if claude_will_last is False or claude_weekly_num >= warn_pct:
                if claude_will_last is False:
                    claude_line += " ⚠ 尽きる見込み"
                else:
                    claude_line += " ⚠"
            lines.append(claude_line)
        except Exception:
            pass

ROUTE_DISPLAY_MAP = {
    "claude": "Claude",
    "glm": "GLM",
    "antigravity": "Gemini",
    "kimi": "Kimi",
    "codex": "Codex",
    "cursor": "Cursor",
    "ocg": "OCG",
}

worker_items = []
for r in display_routes:
    if r == "claude":
        continue
    if r in routes:
        r_info = routes[r]
        if isinstance(r_info, dict) and "usedPercent" in r_info and r_info["usedPercent"] is not None:
            try:
                pct_val = int(round(float(r_info["usedPercent"])))
                dname = ROUTE_DISPLAY_MAP.get(r, r.upper() if len(r) <= 3 else r.capitalize())
                worker_items.append(f"{dname} {pct_val}%")
            except Exception:
                pass

if worker_items:
    lines.append(" / ".join(worker_items))

if claude_weekly_num is not None:
    if claude_weekly_num >= strong_pct:
        lines.append("⛔ Claude 直実装をやめ、AI worker へ委譲してください")
    elif claude_weekly_num >= warn_pct:
        lines.append("→ 実装は AI worker へ委譲してください")

# Output rendered panel markers
print("PANEL_START")
print("\n".join(lines))
print("PANEL_END")
PY
}

PY_OUTPUT="$(python3 -c "$(PREFLIGHT_PY)" "$AGENTS_YAML" "${CREDIT_USAGE_CACHE_FILE:-}" 2>/dev/null || true)"

SHOULD_REFRESH="$(printf '%s\n' "$PY_OUTPUT" | sed -n 's/^REFRESH=\([0-9]*\)|.*/\1/p')"
RESOLVED_CACHE_FILE="$(printf '%s\n' "$PY_OUTPUT" | sed -n 's/^REFRESH=[0-9]*|CACHE_FILE=//p')"

if [ "$SHOULD_REFRESH" = "1" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CACHE_SCRIPT="${CREDIT_USAGE_CACHE_SCRIPT:-$SCRIPT_DIR/credit-usage-cache.sh}"
  if [ -f "$CACHE_SCRIPT" ]; then
    (
      CREDIT_USAGE_CACHE_FILE="${RESOLVED_CACHE_FILE:-${CREDIT_USAGE_CACHE_FILE:-}}" \
      CODEXBAR_BIN="${CODEXBAR_BIN:-/opt/homebrew/bin/codexbar}" \
      bash "$CACHE_SCRIPT" >/dev/null 2>&1 &
    ) 2>/dev/null || true
  fi
fi

PANEL_CONTENT="$(printf '%s\n' "$PY_OUTPUT" | sed -n '/^PANEL_START$/,/^PANEL_END$/p' | sed '1d;$d')"

if [ -n "$PANEL_CONTENT" ]; then
  printf '%s\n' "$PANEL_CONTENT"
fi

exit 0
