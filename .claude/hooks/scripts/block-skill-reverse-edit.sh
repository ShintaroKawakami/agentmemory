#!/bin/bash

# [2026-06-05][feat] Phase E: スキル参照一元化の逆流(SSOT汚染)ブロック
# 背景:
#   - ユーザー依頼意図: スキルは AGENT-HUB を唯一の正本(SSOT)とし、各PJは
#     .claude/skills/<name> の相対symlinkで参照する「参照一元化」へ移行済み
#     (skill-reference-unification / AGENT-HUB PR #281・#282)。この構成では、PJ で
#     作業中に symlink経由でスキルファイル(.claude/skills/<name>/SKILL.md 等)を
#     Write/Edit すると、symlink先の実体(AGENT-HUB/skills/<name>/...)がレビューなしで
#     直接書き換わり、参照中の全PJへ波及する(逆流)。ルール文だけでは AI が破る
#     (遵守は確率的)ため、機械的にブロックして HUB のPR運用へ誘導したい。
#   - 守るべき業務ルール: スキル実体の編集は AGENT-HUB でブランチを切り
#     PR→レビュー→マージ→各PJへ反映、の一方向に統一する。PJ側からの逆流編集は禁止。
#   - 他案不採用理由:
#     1) 警告のみ(非ブロック)案: AI は警告を無視して編集を続けるため SSOT 汚染を
#        防げず不採用。完全ブロックにする(ユーザー判断 2026-06-05「完全ブロック」)。
#     2) パス文字列(.claude/skills/)だけで判定する案: PJ_LOCAL_EXCEPTION の実体コピー
#        スキルや AGENT-HUB worktree 内の直接編集まで誤ブロックするため不採用。
#        realpath(symlink解決)で「実体が <hub>/skills/ か」「論理パスが hub の内か外か」
#        を見て、逆流(hub外の論理パス→hub内の実体)だけを deny する。
#     3) hub パスをハードコードする案: worktree や別クローンで破綻するため、realpath を
#        遡って DISTRIBUTION.yaml を持つ skills 親を動的に hub root とみなす。
#     4) CODEX_SCRIPT_MAP へ追加する案: PreToolUse(Write|Edit) は Codex のツール名体系と
#        異なり非対応(block-unauthorized-docs-file と同型)のため Claude 専用にする。
# 対応: PreToolUse(Write|Edit|MultiEdit) で編集先 file_path を realpath 解決。実体が
#   <hub>/skills/<name>/... (skills の親に DISTRIBUTION.yaml) かつ 論理パスが hub root の
#   外(=PJ の .claude/skills/ symlink経由)のときだけ deny。AGENT-HUB(worktree含む)内の
#   直接編集・PJの実体コピースキル・PJソースコードは素通り(fail-open: 逆流見逃しは
#   本番破壊ではないため、判定異常時は許可してAIの作業を止めない)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

# telemetry(harness-checkup): deny を記録。lib 無しでも壊れない no-op fallback。
# 注意: `set -euo pipefail` 下で `. 存在しないファイル` は `||` フォールバックを素通りして
# シェルごと終了する(bash の source 失敗は errexit 免除の対象外)。存在チェックを先に行い、
# 未配布(telemetry-lib.sh 未同期の配布先)でも deny 本体を絶対に壊さない。
if [ -f "$SCRIPT_DIR/telemetry-lib.sh" ]; then
  . "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || true
fi
if ! declare -f agent_hub_telemetry_log >/dev/null 2>&1; then
  agent_hub_telemetry_log() { :; }
fi

DENY_MSG='[hook:block-skill-reverse-edit] このスキルの正本(SSOT)は AGENT-HUB です。PJ の .claude/skills/(symlink)経由で実体を直接編集すると、レビューなしで参照中の全PJへ波及します(逆流)。\n\n対応手順:\n1. cd ~/business/AGENT-HUB\n2. git checkout -b feat/<skill>-update でブランチ作成\n3. skills/<name>/ を編集\n4. gh pr create -> レビュー -> マージ(各PJへ自動反映)\n\n理由: スキルは1実体をHUBに一元管理(参照一元化)。PJ側からの編集はSSOT汚染になるためHUBのPR運用に統一します。'

# emit_deny は hook-io.sh にもあるが reason を heredoc へ直接展開し JSON エスケープしない。
# 将来 DENY_MSG に二重引用符等を含めても壊れないよう json.dumps でエスケープして deny を出す
# (block-unauthorized-docs-file.sh の emit_deny_safe と同型)。argv でなく env 経由で渡し安全化。
emit_deny_safe() {
  # telemetry(harness-checkup): deny を記録(記録失敗は無視・fail-open)。
  agent_hub_telemetry_log hook_deny block-skill-reverse-edit deny 2>/dev/null || true
  HOOK_REASON="$1" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": os.environ.get("HOOK_REASON", "")}}))
' || true
  exit 0
}

read_stdin
FILE_PATH=$(extract_file_path)

# file_path を持たないツール入力は対象外
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# bash 前段フィルタ: スキル実体は必ず <hub>/skills/ 配下にある。パスに skills/ を含まない
# 大多数の編集は確実に対象外なので、python3 を起動せず即許可して発火コストを避ける。
case "$FILE_PATH" in
  */skills/*) : ;;  # skills/ を含む → 詳細判定へ進む
  *) exit 0 ;;      # 含まない → 対象外(allow)
esac

# 逆流判定は realpath 解決を伴うため python3 で行う(bash の realpath は未存在末端で
# 揺れるため)。verdict は "deny"(逆流) / "allow"(対象外 or HUB内直接編集)。
verdict=$(HOOK_FILE_PATH="$FILE_PATH" python3 - <<'PY' 2>/dev/null || true
import os

fp = os.environ.get("HOOK_FILE_PATH", "")
if not fp:
    print("allow")
    raise SystemExit(0)

# 実体パス(symlink解決後)。os.path.realpath は末端が未存在でも経路上の symlink を
# 解決する(Write 新規作成に対応)。macOS の /var -> /private/var 等の上位 symlink も
# 正規化されるため、比較する hub もすべて realpath で揃える(prefix ずれ回避)。
real = os.path.realpath(fp)


def find_hub_skill_root(real_path):
    """real_path が <hub>/skills/<name>/... の形なら、DISTRIBUTION.yaml を持つ
    skills 親(hub root, realpath)を返す。スキル実体でなければ None。"""
    parts = real_path.split(os.sep)
    for i, seg in enumerate(parts):
        if seg == "skills" and i > 0:
            hub_root = os.sep.join(parts[:i])
            if hub_root and os.path.isfile(os.path.join(hub_root, "DISTRIBUTION.yaml")):
                return os.path.realpath(hub_root)
    return None


def find_enclosing_hub(path):
    """path(論理)を文字列的に上へ辿り、DISTRIBUTION.yaml を持つ最も近い祖先(realpath)を
    返す。symlink は辿らない(file_path が物理的にどの hub の中に在るかを見る)。
    前提: bootstrap-skills.py は per-skill symlink(.claude/skills/<name>)のみ生成し
    .claude/skills/ ディレクトリ自体は実ディレクトリ。仮に .claude/skills/ 全体を hub への
    symlink にする非標準構成では os.path.isfile が辿って誤許可しうるが、実環境では
    bootstrap が生成しないため発生しない(fail-open 受容)。"""
    cur = os.path.abspath(path)
    while True:
        if os.path.isfile(os.path.join(cur, "DISTRIBUTION.yaml")):
            return os.path.realpath(cur)
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


real_hub = find_hub_skill_root(real)
if real_hub is None:
    # スキル実体への書き込みではない(PJソース/実体コピースキル/通常ファイル) -> 対象外
    print("allow")
    raise SystemExit(0)

enclosing_hub = find_enclosing_hub(fp)
if enclosing_hub is not None and enclosing_hub == real_hub:
    # file_path が物理的に属する hub と実体の hub が同一 -> HUB(worktree含む)内の直接編集
    print("allow")
else:
    # file_path は hub の外(PJ)に在り、実体だけ hub 内 -> .claude/skills/ symlink 逆流
    print("deny")
PY
)

if [ "$verdict" = "deny" ]; then
  emit_deny_safe "$DENY_MSG"
fi

exit 0
