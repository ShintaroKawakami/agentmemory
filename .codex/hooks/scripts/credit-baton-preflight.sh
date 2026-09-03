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

# [2026-09-01][fix] agents.yaml が配布先PJに存在しないため hook が SessionStart のたびに
# 無言 exit 0 していた件（真因調査・実測: jtt-cms/jtt-apps/jtt-system/jtt-cafe-pj/hermes/
# mcp-servers系のPJすべてに agents.yaml が無いことを ls で確認済み。ファイル配布・
# settings.json 配線は正しいのに、この直後の存在チェックだけで毎回止まっていた）。
# 背景:
#   - ユーザー依頼意図: 閾値の正本 agents.yaml（worker_delegation.credit_preflight セクション）
#     は AGENT-HUB 1本のままにしつつ、配布先PJでも残量パネル・節約モード宣言が動くようにしたい。
#   - 守るべき業務ルール: 解決順序は ①AGENTS_YAML_PATH（既存のテスト用オーバーライドを壊さない）
#     ②$PROJECT_DIR/agents.yaml（AGENT-HUB 自身で作業しているケース）③AGENT_HUB_AGENTS_YAML
#     （既定 $HOME/business/AGENT-HUB/agents.yaml、env で上書き可）の3段。最終的に
#     解決したパスも存在しなければ、これまで通り静かに exit 0（fail-open。エラーで
#     SessionStart を汚さない）。
#   - 他案不採用理由:
#     1) 各PJへ agents.yaml を配布複製する案 → 閾値の正本が分散し、変更のたびに全PJへ
#        再配布が必要になるため不採用（`.claude/rules/general/reference-over-hardcode.md`
#        の参照型設計に反する）。
#     2) 閾値をスクリプトへ直書きする案 → 本ファイル冒頭の 2026-08-27 CaD で
#        「変更時に直す場所が分散する」として既に不採用済み。今回も踏襲し直書きしない。
#     3) 新しい env `AGENT_HUB_ROOT`（ディレクトリを指す）を新設する案 →
#        同じ hook-library 内の `fable-implementation-guard.sh` が既に
#        `AGENT_HUB_AGENTS_YAML`（agents.yaml への絶対パスを直接指す env）を採用済みであり、
#        新変数を足すと同じ役割の env が2つに分散するため不採用。既存の命名・粒度に揃える。
# 対応: AGENTS_YAML の解決を3段フォールバックへ変更する。
if [ -n "${AGENTS_YAML_PATH:-}" ]; then
  AGENTS_YAML="$AGENTS_YAML_PATH"
elif [ -f "$PROJECT_DIR/agents.yaml" ]; then
  AGENTS_YAML="$PROJECT_DIR/agents.yaml"
else
  AGENTS_YAML="${AGENT_HUB_AGENTS_YAML:-$HOME/business/AGENT-HUB/agents.yaml}"
fi

if [ ! -f "$AGENTS_YAML" ]; then
  exit 0
fi

# [2026-09-01][feat] 日次基準点ファイルを delegation-routing-reminder.sh と共有する
# 背景:
#   - ユーザー依頼意図: 「今日12%超で節約モード」の基準点（その日最初に観測した週次値）は
#     SessionStart と UserPromptSubmit の両方から読み書きされるため、別々のディレクトリに
#     置くと二重に基準点が生まれてズレる。
#   - 守るべき業務ルール: 同じ「日次基準点ファイル」を両 hook が共有できるよう、
#     delegation-routing-reminder.sh と同じキャッシュディレクトリ解決関数を使う
#     （read-only 利用。lib ファイル自体は本 PR の allowed_files 外のため編集しない）。
#   - 他案不採用理由: 本ファイル専用の別ディレクトリを新設する案は、基準点ファイルが
#     2箇所に分散し「どちらが正か」の混乱を生むため不採用。
DELEGATION_CACHE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/delegation-reminder-cache.sh"
if [ -f "$DELEGATION_CACHE_LIB" ]; then
  # shellcheck source=../lib/delegation-reminder-cache.sh
  source "$DELEGATION_CACHE_LIB"
  DAILY_BASELINE_DIR="$(resolve_delegation_reminder_cache_dir "$PROJECT_DIR" 2>/dev/null || echo "")"
  if [ -n "$DAILY_BASELINE_DIR" ]; then
    mkdir -p "$DAILY_BASELINE_DIR" 2>/dev/null || true
  fi
else
  DAILY_BASELINE_DIR=""
fi
export DAILY_BASELINE_DIR

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
                    if k in (
                        "cache_ttl_seconds",
                        "claude_weekly_warn_percent",
                        "claude_weekly_strong_percent",
                        # [2026-09-01][feat] fallback parser（PyYAML 不在時）にも
                        # 日次・pace 閾値キーを認識させる（PyYAML 経由の主経路は
                        # doc.get() で自動的に全キーを拾うため変更不要。fallback だけ
                        # ハードコードされた allowlist のため個別追加が必要）。
                        "claude_daily_warn_percent",
                        "claude_daily_strong_percent",
                        "claude_pace_delta_warn_points",
                        "claude_pace_delta_strong_points",
                    ):
                        try:
                            config[k] = int(v)
                        except Exception:
                            pass
                    elif k == "claude_pace_exhaustion_is_strong":
                        config[k] = v.strip().lower() in ("true", "yes", "1")
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
display_routes = config.get("display_routes", ["claude", "glm", "antigravity", "kimi", "codex", "codex-spark", "cursor", "ocg"])

# [2026-09-01][feat] 日次節約モード閾値 + pace 閾値（agents.yaml からライブ読み・ハードコード禁止）
daily_warn_pct = config.get("claude_daily_warn_percent")
daily_strong_pct = config.get("claude_daily_strong_percent")
pace_delta_warn_pts = config.get("claude_pace_delta_warn_points")
pace_delta_strong_pts = config.get("claude_pace_delta_strong_points")
pace_exhaustion_is_strong = bool(config.get("claude_pace_exhaustion_is_strong", False))
daily_baseline_dir = os.environ.get("DAILY_BASELINE_DIR", "")

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
elapsed_sec = None
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
        elapsed_sec = None

# [2026-09-01][feat] 鮮度の明示強化（真因調査タスク item A）
# 背景: TTL(cache_ttl秒)を大きく超えて古い値が残っていた実測（〜20時間）があったため、
# 「N分前/N時間前」の表示だけでなく、TTLの2倍または1時間のどちらか大きい方を超えたら
# ⚠️ を前置きし、古い値であることを明示する（古い値を新しい値のように見せない）。
stale_warning = elapsed_sec is not None and elapsed_sec > max(cache_ttl * 2, 3600)
header_prefix = "⚠️ " if stale_warning else "⚡ "
header = f"{header_prefix}クレジット残量（{time_label}）" if time_label else f"{header_prefix}クレジット残量"
lines = [header]
if stale_warning:
    lines.append(f"（この値は{time_label}のものです。最新の値ではない可能性があります）")

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

# [2026-09-03][fix] Codex(GPT) と Spark を別表示にする
# 背景:
#   - ユーザー依頼意図（伸太郎殿 PR2407）: 「Codex 96% ✖ は Codex Spark の値。Codex GPT は
#     余裕がある。Codex は gpt と spark の 2 種類。混ぜているのはバグ」。credit-usage-cache.sh
#     側で routes.codex（GPT）と routes["codex-spark"]（Spark）を分離した（同PR同時修正）ため、
#     表示側も "Codex" 1本の値ではなく "Codex(GPT)" / "Spark" の2本を出す。
#   - 守るべき業務ルール: 判定ロジック（節約モード閾値・warn/strong）は変更しない。表示名だけ変える。
#   - 他案不採用理由: "Codex" のまま max(GPT, Spark) を表示し続ける案は、今回の混同バグの
#     再発そのものであり不採用。
ROUTE_DISPLAY_MAP = {
    "claude": "Claude",
    "glm": "GLM",
    "antigravity": "Gemini",
    "kimi": "Kimi",
    "codex": "Codex(GPT)",
    "codex-spark": "Spark",
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

# [2026-09-01][feat] 日次節約モードの自動宣言（真因調査タスク item C）
# 背景:
#   - ユーザー依頼意図: 「今日1日の利用が12%を超えたら自動的に節約モードに入る」を
#     セッション開始時点で判定・宣言したい（記憶や注意力に頼らず構造的に気づく）。
#   - 判定ロジック（daily-pct と pace の OR。どちらか一方でも閾値に達したら発火）:
#     1) daily-pct: 「本日 UTC で最初に観測した週次値」を基準点とし、現在の週次値との差分を
#        本日の使用量とする。secondary window は resetsAt 固定の7日ウィンドウ（ローリングではない）
#        ため、この差分は近似ではなく正確な値である（2026-08-31 実装時の「ローリングにつき
#        近似・過小評価」という記述は誤りだったため本コミットで訂正する）。
#     2) pace: codexbar が計算済みの pace.secondary（expectedUsedPercent / deltaPercent / stage /
#        willLastToReset）をそのまま使う（自前でペース再計算しない）。deltaPercent が
#        claude_pace_delta_warn_points/strong_points を超えるか、willLastToReset が false かつ
#        claude_pace_exhaustion_is_strong が true なら strong 扱いにする。
#   - 対象範囲の未確認事項（捏造しないための明記）: codexbar `--provider claude` の既定 source は
#     claude.ai API（`codexbar --help` 実測）であり、この usage.secondary が Claude Code 経由の
#     利用だけを指すのか、claude.ai 等の他サーフェス利用も合算されているのかは、この調査からは
#     断定できなかった（未確認）。extraRateWindows に `claude-weekly-scoped-fable`
#     という別枠があることは実測したが、これが Claude Code 専用なのか特定モデルティア専用
#     なのかも未確認。利用者の対象は Claude Code のみだが、指標側がそれを保証しているかは
#     「未確認」として扱う。
daily_tier = "none"
daily_used_display = None
daily_generation_switched = False
pace_delta_display = None
# [2026-09-01][fix] Codexレビュー指摘（credit-baton-preflight.sh:300・🟡・妥当と判断し承認）:
# 基準点と同じ UTC 日の途中で weekly の集計対象ウィンドウ（resetsAt）を跨ぐと、weekly が
# 大きく下がり max(0, weekly-baseline) が 0 に潰れて実際の使用分を見逃す（例: 基準点80% →
# リセット後15%使用 → max(0,15-80)=0 と誤判定。resetsAt が UTC 日の途中で来る日には週1回
# 必ず発生する）。resetsAt をキャッシュへ追加したのに日次計算では使っていなかった。
# 対応: 基準点ファイルへ resetsAt（世代識別子）も保存し、現在の resetsAt と異なれば
# 世代が変わったとみなして基準点を取り直す。新世代は0%から始まったことが確定しているため、
# 世代切替を検知したその回に限り、観測された weekly の値そのものを『本日の使用量』として
# 扱う（daily_used_display = 観測値そのもの。ただしリセット前=旧世代に今日既に使っていた分は
# 含まれない＝復元できないため推測で埋めず、過少評価であることをメッセージ側で明記する）。
# 初回観測（baseline未存在・世代不明・ウィンドウの継続期間が分からない）は従来どおり
# 保守的に「今から数える」（0起点）を維持する。resetsAt が None（他providerや古いキャッシュ）
# の場合は世代判定できないため既存baselineをそのまま使う（fail-open）。
# delegation-routing-reminder.sh の load_or_init_daily_baseline() と同じ判定規則。
current_resets_at = claude_data.get("resetsAt") if isinstance(claude_data, dict) else None
if claude_weekly_num is not None and daily_baseline_dir:
    try:
        today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        baseline_path = os.path.join(daily_baseline_dir, f"daily-baseline-{today_str}.txt")
        stored_baseline = None
        stored_resets_at = None
        try:
            with open(baseline_path, "r", encoding="utf-8") as fh:
                raw = fh.read().strip()
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = None
            if isinstance(parsed, dict):
                stored_baseline = parsed.get("baseline")
                stored_resets_at = parsed.get("resetsAt")
            elif isinstance(parsed, (int, float)):
                # legacy format（本修正前は生の数値だけを書いていた）。resetsAt情報が
                # 無いため世代不明として扱う。
                stored_baseline = parsed
                stored_resets_at = None
        except Exception:
            stored_baseline = None

        daily_generation_switched = (
            stored_baseline is not None
            and current_resets_at is not None
            and current_resets_at != stored_resets_at
        )
        current_weekly_int = int(round(claude_weekly_num))
        if stored_baseline is None:
            # 初回観測（世代不明・ウィンドウの継続期間が分からない）。保守的に「今から数える」
            # （delegation-routing-reminder.sh の load_or_init_daily_baseline() と同じ判定規則）。
            stored_baseline = current_weekly_int
            try:
                os.makedirs(daily_baseline_dir, exist_ok=True)
                with open(baseline_path, "w", encoding="utf-8") as fh:
                    fh.write(json.dumps({"baseline": stored_baseline, "resetsAt": current_resets_at}))
            except Exception:
                pass
            daily_used_display = max(0, current_weekly_int - int(round(float(stored_baseline))))
        elif daily_generation_switched:
            # 新世代は0%から始まったことが確定しているため、観測値そのものが『本日の使用量』
            # （新世代分だけ・旧世代の消費分は含まない＝過少評価。復元不可のため推測で埋めない）。
            stored_baseline = current_weekly_int
            try:
                os.makedirs(daily_baseline_dir, exist_ok=True)
                with open(baseline_path, "w", encoding="utf-8") as fh:
                    fh.write(json.dumps({"baseline": stored_baseline, "resetsAt": current_resets_at}))
            except Exception:
                pass
            daily_used_display = current_weekly_int
        else:
            daily_used_display = max(0, current_weekly_int - int(round(float(stored_baseline))))
    except Exception:
        daily_used_display = None

if daily_used_display is not None and daily_warn_pct is not None and daily_strong_pct is not None:
    if daily_used_display >= daily_strong_pct:
        daily_tier = "strong"
    elif daily_used_display >= daily_warn_pct:
        daily_tier = "warn"

pace_tier = "none"
if isinstance(claude_data, dict):
    delta_pts = claude_data.get("deltaPercent")
    will_last = claude_data.get("willLastToReset")
    if isinstance(delta_pts, (int, float)):
        pace_delta_display = delta_pts
        if pace_delta_strong_pts is not None and delta_pts >= pace_delta_strong_pts:
            pace_tier = "strong"
        elif pace_delta_warn_pts is not None and delta_pts >= pace_delta_warn_pts:
            pace_tier = "warn"
    if will_last is False and pace_exhaustion_is_strong:
        pace_tier = "strong"

TIER_RANK = {"none": 0, "warn": 1, "strong": 2}
overall_tier = daily_tier if TIER_RANK[daily_tier] >= TIER_RANK[pace_tier] else pace_tier

if overall_tier != "none":
    expected_pct = claude_data.get("expectedUsedPercent") if isinstance(claude_data, dict) else None
    stage = claude_data.get("stage") if isinstance(claude_data, dict) else None
    eta_seconds = claude_data.get("etaSeconds") if isinstance(claude_data, dict) else None
    detail_parts = []
    if daily_used_display is not None:
        detail_parts.append(f"本日約{daily_used_display}%")
    if expected_pct is not None and pace_delta_display is not None:
        sign = "+" if pace_delta_display >= 0 else ""
        detail_parts.append(f"期待{int(round(expected_pct))}%・{sign}{int(round(pace_delta_display))}%超過")
    if isinstance(claude_data, dict) and claude_data.get("willLastToReset") is False and isinstance(eta_seconds, (int, float)) and eta_seconds > 0:
        days = int(eta_seconds // 86400)
        hours_left = int((eta_seconds % 86400) // 3600)
        if days > 0:
            detail_parts.append(f"あと{days}日{hours_left}時間で枯渇見込み")
        else:
            detail_parts.append(f"あと{hours_left}時間で枯渇見込み")
    # [2026-09-01][fix] 世代切替（resetsAt変更）直後は、リセット前の消費分を復元できないため
    # 「本日分は一部のみ」と明記する（推測で埋めない代わりに過少である可能性を伝える。
    # 過度に冗長にしないため短い注記に留める）。
    if daily_generation_switched:
        detail_parts.append("週次カウンタ変更直後のため本日分は一部のみ")
    detail = "（" + "・".join(detail_parts) + "）" if detail_parts else ""
    weekly_disp = int(round(claude_weekly_num)) if claude_weekly_num is not None else "?"
    icon = "⛔" if overall_tier == "strong" else ""
    prefix = f"{icon}【節約モード】" if icon else "【節約モード】"
    lines.append(
        f"{prefix}週次 {weekly_disp}%{detail}。実装は ai-worker、探索はサブエージェントへ委譲し、"
        "Claude は指示と検証に徹します。"
    )

# Output rendered panel markers
print("PANEL_START")
print("\n".join(lines))
print("PANEL_END")
PY
}

PY_OUTPUT="$(python3 -c "$(PREFLIGHT_PY)" "$AGENTS_YAML" "${CREDIT_USAGE_CACHE_FILE:-}" 2>/dev/null || true)"

SHOULD_REFRESH="$(printf '%s\n' "$PY_OUTPUT" | sed -n 's/^REFRESH=\([0-9]*\)|.*/\1/p')"
RESOLVED_CACHE_FILE="$(printf '%s\n' "$PY_OUTPUT" | sed -n 's/^REFRESH=[0-9]*|CACHE_FILE=//p')"

# [2026-09-01][fix] 真因調査（credit-usage.json が TTL 900秒を超えて〜20時間更新されなかった件）
# 背景:
#   - ユーザー依頼意図: なぜ TTL 900秒なのに何時間も古いままだったのかを特定して直す。
#   - 確認できた事実（実測・2026-09-01）:
#     1) 実キャッシュに `credit-usage.lock` は残っておらず、stale lock が更新を止めていた形跡は無い。
#     2) `credit-usage-cache.sh` を直接（フォアグラウンドで）実行すると約22秒で正常に完了し、
#        7 provider 全てを取得できた（理論上の最悪値 175 秒よりずっと短い）。
#     3) 本ファイル（credit-baton-preflight.sh）が持つ既存の
#        `( CMD & ) 2>/dev/null || true` という素の background 起動方式も、本 repo のサンドボックス
#        環境で検証した限りでは正常に動作した（stale なキャッシュを検知→background起動→
#        約20秒後にファイル更新、という一連の流れを実際に再現できた）。
#   - 未解明のまま残った点（正直に明記）: 実運用（本物の Claude Code SessionStart hook 実行）で
#     何が背景ジョブを止めていたのかは、この検証環境からは直接観測できなかった
#     （SessionStart は実セッション開始時にしか発火せず、この作業セッション内で任意に
#     発火させて実プロセスツリーを観測する手段が無かったため）。stale だった実キャッシュの
#     `updatedAt` が 2026-08-31 07:14Z のまま約20時間更新されなかった実測はあるが、
#     「その間 SessionStart が一度も発火しなかったのか」「発火はしたがバックグラウンドジョブが
#     何らかの理由で完走前に終了させられたのか」を切り分ける証拠は得られていない。
#   - 適用した対策（原因を断定できなくても安全側に倒す・本 repo の既存前例に倣う）:
#     `skills/visual-companion/scripts/start-server.sh` が同種の「バックグラウンド起動を
#     呼び出し元スクリプトの終了から生き残らせる」目的で既に `nohup ... & disown` を
#     採用している（コメント: 「survive shell exit」）。同じ idiom をここにも適用する。
#     macOS 標準に `setsid` が無いため、setsid によるプロセスグループ分離までは行わない
#     （brew 経由の util-linux 依存を増やす案は不採用。個人運用スケールでは
#     nohup+disown で十分な安全側対策）。
#   - 他案不採用理由:
#     1) 「stale lock が原因」と決めつけて lock 判定だけを直す案は、実キャッシュに lock が
#        残っていなかった実測と矛盾するため不採用。
#     2) 原因が完全には特定できないまま「直した」と報告する案は、捏造禁止の指示に反するため
#        不採用。確認できた事実／できなかった事実を分けて記録する。
# 対応（このコミットで実施）:
#   ①nohup+disown 化（本ブロック） ②delegation-routing-reminder.sh 側にも同種の
#   staleness チェック＋再試行を追加し、SessionStart 1回だけに依存しない自己修復性を持たせる
#   （UserPromptSubmit は長時間セッション中に何度も発火するため、再試行機会が大幅に増える）
#   ③表示側で鮮度（経過時間）を必ず出し、古い値を新しい値のように見せない。
if [ "$SHOULD_REFRESH" = "1" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CACHE_SCRIPT="${CREDIT_USAGE_CACHE_SCRIPT:-$SCRIPT_DIR/credit-usage-cache.sh}"
  if [ -f "$CACHE_SCRIPT" ]; then
    (
      CREDIT_USAGE_CACHE_FILE="${RESOLVED_CACHE_FILE:-${CREDIT_USAGE_CACHE_FILE:-}}" \
      CODEXBAR_BIN="${CODEXBAR_BIN:-/opt/homebrew/bin/codexbar}" \
      nohup bash "$CACHE_SCRIPT" >/dev/null 2>&1 &
      disown 2>/dev/null || true
    ) 2>/dev/null || true
  fi
fi

PANEL_CONTENT="$(printf '%s\n' "$PY_OUTPUT" | sed -n '/^PANEL_START$/,/^PANEL_END$/p' | sed '1d;$d')"

if [ -n "$PANEL_CONTENT" ]; then
  printf '%s\n' "$PANEL_CONTENT"
fi

exit 0
