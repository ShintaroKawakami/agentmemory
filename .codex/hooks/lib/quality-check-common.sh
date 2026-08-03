#!/bin/bash

# [2026-03-03][refactor]
# 背景: jtt-cms Gen 3 (403行) をAGENT-HUBのhook-libraryにポート。
#   3PJで独立進化したhookを統一するため、最先端のGen 3をSSOTとして抽出。
#   各PJ個別実装だと変更が伝播せず重複が増え続けるため、コンポーネント化して
#   deploy-hooks.pyで全PJに配布する設計。
# 対応: jtt-cms quality-check-common.sh をhook-library/lib/にポート。
#   パス解決をscripts/サブディレクトリ構成に対応させ、
#   チェックリストパスをproject_dir起点に変更。
#
# [2026-03-04][fix]
# 背景: ユーザー意図は「transcript解析がPython 3.8環境でも失敗せず動くこと」。
#   業務ルールとして、品質ゲート共通ライブラリはPJ間で同一挙動を保つ必要がある。
#   代替案として `set[str]` 型注釈を維持すると、3.8で構文エラーになり判定が抜けるため不採用。
# 対応: 埋め込みPythonの型注釈を `typing.Set` ベースへ変更。

set -euo pipefail

# telemetry(harness-checkup): quality-gate 系(stop/subagent)の deny を記録。
# 本 lib は hook-library/lib/ に在り、telemetry-lib.sh は hook-library/scripts/ にある。
# 配布先でも同じ相対構成(.claude/hooks/lib/ と .claude/hooks/scripts/)のため ../scripts/ で解決できる。
# 注意: `set -euo pipefail` 下で `. 存在しないファイル` は `||` フォールバックを素通りして
# シェルごと終了する(bash の source 失敗は errexit 免除の対象外)。存在チェックを先に行い、
# 未配布(telemetry-lib.sh 未同期の配布先)でも quality-gate 本体を絶対に壊さない。
_quality_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_quality_common_dir/../scripts/telemetry-lib.sh" ]; then
  . "$_quality_common_dir/../scripts/telemetry-lib.sh" 2>/dev/null || true
fi
if ! declare -f agent_hub_telemetry_log >/dev/null 2>&1; then
  agent_hub_telemetry_log() { :; }
fi

# [2026-04-26][fix]
# 背景:
# - ユーザー依頼意図: jtt-apps の /brainstorm 質問のみセッションで Stop hook が誤発火する事故 (B1) を、git diff fallback がバックグラウンド同期で書き換わった untracked 派生物 (.opencode/sync-state.json 等) を「変更ファイル」と誤認することで起きる問題として根治したい。
# - 守るべき業務ルール: 配布先 PJ 側で sync スクリプトが書き換える派生物 (.opencode/, .cursor/, .gemini/, .augment/, .codex/hooks/, .agent/, sync-state.json) は AI のツール呼び出し由来ではないため品質ゲートの対象外にする。
# - 他案不採用理由:
#   1) .gitignore に追加して回避する案 → 検出ロジックの欠陥は残ったまま、新しい派生物ディレクトリが増えるたびに各 PJ で .gitignore を直す必要があり SSOT 原則違反。
#   2) git diff fallback を完全廃止する案 → Bash 経由 (sed -i / cat > / tee 等) の書き換えを救う最後の砦が消える。
# 対応: DOC_SKIP_PATTERNS に sync 派生物パターンを追加し多重防御。主防御は run_quality_check_hook の transcript 判定変更で行う。
# [2026-05-26][fix]
# 背景:
# - ユーザー依頼意図: business profile の PJ (jtt-cafe-pj / non-pj) は議事録・PRD・戦略などの .md/docs が
#   成果物そのもの。従来は全 PJ 共通で .md/docs を skip していたため、business PJ がローカルで DOC_SKIP を
#   書き換える drift が発生していた (hook-library v3.4.11 配布で露見・Codex 指摘)。SSOT で一元解決したい。
# - 守るべき業務ルール: 同期派生物 (.opencode/ 等・ツール生成物) は全 profile で skip。文書 (.md/docs 等) は
#   code profile では skip、business profile では品質チェック対象にする。配布時に deploy-hooks.py が
#   business profile のみ DOC_TYPE_SKIP を外す。配布物のローカル編集 (drift) は禁止のため SSOT 側で分岐させる。
# - 他案不採用理由: (1) 各 business PJ で DOC_SKIP をローカル編集 → 配布物改変禁止に反し再 drift。
#   (2) runtime で checklist md の文言から profile 推定 → 文言変更で静かに壊れる。
# 対応: パターンを DOC_TYPE_SKIP (文書) と SYNC_DERIVATIVE_SKIP (同期派生物) に分割。deploy-hooks.py は
#   business profile 配布時に下の結合行を `readonly DOC_SKIP_PATTERNS="${SYNC_DERIVATIVE_SKIP}"` へ置換する。
# [2026-07-09][fix]
# 背景:
# - ユーザー依頼意図: `.brv/` と Kimi 系生成物が同期派生物なのに品質チェック対象へ入り、実作業の本質と
#   無関係な検出ノイズになるのを防ぎたい。
# - 守るべき業務ルール: AI ツール CLI 派生物は SSOT から再生成・同期されるため、quality check の本文対象ではなく
#   SYNC_DERIVATIVE_SKIP に集約する。文書本文の品質チェック分岐は既存の DOC_TYPE_SKIP と分けたまま維持する。
# - 他案不採用理由: 各 PJ の `.gitignore` へ個別追加する案は配布先ごとの drift を増やすため不採用。
#   DOC_TYPE_SKIP 側へ混ぜる案は business profile の文書チェック分岐を壊すため不採用。
# 対応: SYNC_DERIVATIVE_SKIP に `.brv/`、`.kimi-code/`、`.kimi/` を追加する。
# [2026-07-30][fix]
# 背景:
# - ユーザー依頼意図: jtt-apps の実装セッション（シフト確定 v2.5.2）で、Stop hook が
#   `.claude/hooks/.hook-library-version` を「変更されたコードファイル」として毎回検知し、
#   品質チェック済みでも完了報告のたびに block を繰り返した。セッション由来でない配布物で止めたくない。
# - 守るべき業務ルール: `.claude/hooks/**` は deploy-hooks.py が hook-library 正本から生成する配布物であり、
#   配布先での直接編集は禁止（settings-protection-coexistence）。よって配布先 PJ で品質チェックの
#   対象にする意味がなく、正本側（AGENT-HUB `hook-library/`）でチェックすべき対象である。
#   既に `^\.codex/hooks/` は除外済みで、Claude 側だけが抜けていた非対称性が原因。
# - 他案不採用理由:
#   1) git diff fallback で追跡変更を拾うのを止める案 → Bash 経由（sed -i / cat >）の実コード変更を
#      見逃し品質ゲートが弱くなるため不採用（2026-05-26 の判断を維持）。
#   2) `.hook-library-version` だけをファイル名で除外する案 → 同じ配布物である `lib/*.sh` や
#      `scripts/*.sh` のドリフトで再発するため対症療法。ディレクトリ単位で `.codex/hooks/` と揃える。
#   3) 配布先 PJ の drift をその都度コミットして消す案 → 配布のたびに日付スタンプで再発するため恒久解にならない。
# 対応: SYNC_DERIVATIVE_SKIP に `^\.claude/hooks/|/\.claude/hooks/` を追加し、`.codex/hooks/` と対称にする。
readonly DOC_TYPE_SKIP='\.md$|\.prd$|\.txt$|^docs/|/docs/|\.template$|CLAUDE\.md|README|CHANGELOG'
readonly SYNC_DERIVATIVE_SKIP='^\.opencode/|/\.opencode/|^\.cursor/|/\.cursor/|^\.gemini/|/\.gemini/|^\.augment/|/\.augment/|^\.claude/hooks/|/\.claude/hooks/|^\.codex/hooks/|/\.codex/hooks/|^\.agent/|/\.agent/|^\.brv/|/\.brv/|^\.kimi-code/|/\.kimi-code/|^\.kimi/|/\.kimi/|sync-state\.json$'
# DEPLOY-MARKER(business): deploy-hooks.py は business profile でこの行を SYNC_DERIVATIVE_SKIP のみへ置換する。
readonly DOC_SKIP_PATTERNS="${DOC_TYPE_SKIP}|${SYNC_DERIVATIVE_SKIP}"
# [2026-03-17][refactor]
# 背景:
# - ユーザー依頼意図: hookのblock reasonにチェックリスト全文（395行）が毎回チャットに出力され、
#   視認性が悪くコンテキストウィンドウを圧迫するため、最小限の出力に変更したい。
# - 守るべき業務ルール: dev-guardrails SKILL.md Section 9「発火フロー」に記載の
#   「ファイルパス参照指示を block reason に記載 → AIが Read ツールで code-quality-check.md を
#   読み込み品質チェック実施」方式をランタイムで実現すること。
# - 他案不採用理由: (1) チェックリスト全文のインライン注入は視認性を壊す（現状の問題そのもの）。
#   (2) 要約版を別ファイルで管理する案はDRY違反で同期漏れを再発させるため不採用。
#   (3) block reasonを完全に空にする案はAIが何をすべきか分からなくなるため不採用。
# 対応: block reasonにはファイルパス＋変更ファイル一覧のみ出力し、
#   AIにReadツールでチェックリストを読ませる方式に変更。
readonly BLOCK_PREFIX='作業完了前に品質チェックを実施してください。指定されたチェックリストファイルを Read ツールで読み込み、各項目を確認してください。問題があれば修正してから再度完了を報告してください。'
readonly CODE_FILE_PATTERNS='\.(ts|tsx|js|jsx|mjs|cjs|json|css|scss|sql|php|py|sh|yaml|yml|toml|ini|mdx?)$'

emit_json() {
  local decision="$1"
  local reason="$2"

  PY_DECISION="$decision" PY_REASON="$reason" python3 - <<'PY'
import json
import os

print(
    json.dumps(
        {"decision": os.environ["PY_DECISION"], "reason": os.environ["PY_REASON"]},
        ensure_ascii=False,
    )
)
PY
}

is_codex_hook_root() {
  local hook_root="$1"
  local normalized_hook_root

  normalized_hook_root="$(cd "$hook_root" 2>/dev/null && pwd || printf '%s\n' "$hook_root")"

  case "$normalized_hook_root" in
    */.codex/hooks|*/.codex/hooks/) return 0 ;;
    *) return 1 ;;
  esac
}

# [2026-04-26][fix]
# 背景:
# - ユーザー依頼意図: Codex Stop hook が2回目停止時に
#   "hook returned invalid stop hook JSON output" で失敗する問題を、配布元の正本で直したい。
# - 守るべき業務ルール: hook-library は Claude Code / Codex CLI の共通正本なので、
#   Codex だけに必要な出力差分は配布先 hook_root で分岐し、Claude 側の既存応答を維持する。
# - 他案不採用理由: 共通ライブラリ全体を `decision: approve` のままにする案は Codex Stop で再発する。
#   逆に全環境を `continue: true` に変える案は Claude Code 側の既存運用に不要な互換リスクを持ち込むため不採用。
# 対応: `.codex/hooks` 配下で動く approve 相当分岐だけ `{"continue": true}` を返す。
emit_approval_json() {
  local hook_root="$1"
  local reason="$2"

  if is_codex_hook_root "$hook_root"; then
    python3 - <<'PY'
import json

print(json.dumps({"continue": True}))
PY
    return 0
  fi

  emit_json "approve" "$reason"
}

resolve_project_dir() {
  local hook_root="$1"
  local inferred_dir git_root

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return
  fi

  # hook_root is .claude/hooks/ → go up 2 levels to project root
  inferred_dir="$(cd "$hook_root/../.." && pwd)"
  if git -C "$inferred_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$inferred_dir"
    return
  fi

  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_root" ]; then
    printf '%s\n' "$git_root"
    return
  fi

  printf '%s\n' "$inferred_dir"
}

extract_stop_hook_active() {
  local input="$1"

  python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    print(str(data.get('stop_hook_active', False)).lower())
except Exception:
    print('error')
" <<<"$input" 2>/dev/null || echo "error"
}

extract_transcript_path() {
  local input="$1"

  python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    value = data.get('transcript_path', '')
    print(value if isinstance(value, str) else '')
except Exception:
    print('')
" <<<"$input" 2>/dev/null || true
}

extract_agent_type() {
  local input="$1"

  python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    print(data.get('agent_type', ''))
except Exception:
    print('')
" <<<"$input" 2>/dev/null || echo ""
}

extract_agent_transcript_path() {
  local input="$1"

  python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    value = data.get('agent_transcript_path', '')
    print(value if isinstance(value, str) else '')
except Exception:
    print('')
" <<<"$input" 2>/dev/null || true
}

# [2026-03-17][fix]
# 背景:
# - ユーザー依頼意図: PR429レビューで、hook が変更ファイル一覧を誤判定せず、
#   品質チェックの block/approve 判定を安定して行える状態にしたい。
# - 守るべき業務ルール: Git 管理下の合法パス（前後空白や改行を含む名前を含む）でも
#   品質ゲートが誤検知・見逃しを起こさないこと。品質ゲートの誤作動は
#   「本来 block すべき変更を素通しする」「関係ない変更で block する」の両面で運用事故になる。
# - 他案不採用理由: (1) 改行区切りのまま扱う案は改行入りパスで分裂する。
#   (2) strip で前後空白を落とす案は合法パスを別名に変えてしまう。
#   (3) 特殊ケースを無視する案は次回AIが同じバグを再発させるため不採用。
# 対応: 変更ファイル一覧は JSON 配列で受け渡しし、表示時だけ安全に整形する。
extract_changed_files_from_input() {
  local input="$1"

  python3 -c "
import json
import sys

PATH_KEYS = {'file_path', 'path', 'new_path', 'old_path', 'target_path'}

def walk(node, out):
    if isinstance(node, dict):
        for key, value in node.items():
            if key.lower() in PATH_KEYS and isinstance(value, str) and value != '':
                out.add(value)
            walk(value, out)
        return
    if isinstance(node, list):
        for item in node:
            walk(item, out)

paths = set()
try:
    payload = json.load(sys.stdin)
    walk(payload, paths)
except Exception:
    pass

print(json.dumps(sorted(paths), ensure_ascii=False))
" <<<"$input" 2>/dev/null || echo "[]"
}

# [2026-04-26][fix]
# 背景:
# - ユーザー依頼意図: /brainstorm のような質問のみセッション (AI が Write/Edit を一切呼ばない) で Stop hook が誤発火する問題 (B1) の主防御。
# - 守るべき業務ルール: transcript が読み取れた状態で Write 系ツールが 0 件なら、コード変更は本会話由来ではないと判定し git diff fallback を呼ばずに approve する。
# - 他案不採用理由:
#   1) extract_changed_files_from_transcript の戻り値だけで判定する案 → "[]" が「読めて 0件」と「読めなかった」を区別できず、Bash 経由書き換え時に fallback が呼ばれなくなる。
#   2) 戻り値に sentinel 文字列を混ぜる案 → 呼び出し側のパース処理が複雑化し、JSON との混在で誤判定リスク。
# 対応: transcript_path の読み取り可否を別関数で boolean 返却し、呼び出し側で 3 状態 (paths あり / 読めて 0件 / 読めなかった) に分岐する。
transcript_was_readable() {
  local transcript_path="$1"
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# [2026-04-26][fix]
# 背景:
# - ユーザー依頼意図: PR87レビューで、transcript が読める状態の Bash 書き込み
#   (`cat > file`, `tee`, `sed -i` 等) が Write/Edit 0件扱いで品質ゲートを素通りする問題を直したい。
# - 守るべき業務ルール: /brainstorm の質問のみセッションでは誤発火させない一方で、git diff fallback は
#   Bash 経由書き換えを救う最後の砦として残す必要がある。
# - 他案不採用理由:
#   1) git diff fallback を完全廃止する案 → Bash 経由書き換え検出が失われるため不採用。
#   2) transcript 内に Bash があるだけで fallback する案 → `git status` だけの質問セッションで再発火しやすいため不採用。
# 対応: transcript の Bash command から書き込み系パターンだけを検出し、その時だけ fallback に進める。
#
# [2026-04-28][fix]
# 背景:
# - ユーザー依頼意図: 読取専用セッション（gh / git 系コマンドのみ）で Stop hook が連続誤発火し、
#   タイポディレクトリ `.claire/` 配下の untracked ファイルを「変更コード」と誤検出する事故が再発した。
# - 守るべき業務ルール: シェルリダイレクト `2>&1` / `1>&2` はファイル書き込みではない。
#   `&>/dev/null` / `&>>/dev/null` も破棄目的の診断出力であり、WRITE 判定に含めると
#   診断目的の `gh ... 2>&1` 連発で git diff fallback が誤起動し、
#   別 worktree や typo ディレクトリの差分まで拾ってしまう。
# - 他案不採用理由:
#   1) WRITE_COMMAND_RE から `>` を完全削除する案 → 真の `cmd > file` 書き込みを見逃すため不採用。
#   2) DOC_SKIP_PATTERNS に `.claire` を足す案 → 対症療法。次の typo に対応できないため不採用。
#   3) 実行時に shlex で AST パースする案 → bash heredoc / 複合コマンドで誤動作しやすく過剰実装。
# 対応: FD複製 (`2>&1`) と `/dev/null` 破棄だけを除外し、`1>file` / `2>file` / `&>file` は
#   真のファイル書き込みとして検出する。
transcript_has_bash_write_command() {
  local transcript_path="$1"

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo "false"
    return 0
  fi

  python3 - "$transcript_path" <<'PY' 2>/dev/null || echo "false"
import json
import re
import sys
from typing import Any

# `>` / `>>` はFD複製 (`2>&1`) と `/dev/null` 破棄だけを除外する。
# これにより `1>file`, `2>file`, `&>file` は検出し、`2>&1`, `1>&2`, `&>/dev/null` は除外する。
WRITE_COMMAND_RE = re.compile(
    r"((?:^|[\s;|])(?:\d*)?>>?(?!&)(?!\s*/dev/null\b)\s*|(?:^|[\s;|])&>{1,2}(?!>)(?!\s*/dev/null\b)\s*|\btee\b|\bsed\s+-i\b|\bperl\s+-pi\b|\bcp\b|\bmv\b|\brm\b|\btouch\b|\bmkdir\b|\bcat\s+<<)"
)


def tool_name(node: Any) -> str:
    if isinstance(node, dict):
        for key in ("name", "tool_name", "toolName"):
            value = node.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def command_text(node: Any) -> str:
    if not isinstance(node, dict):
        return ""
    if isinstance(node.get("command"), str):
        return node["command"]
    nested = node.get("input")
    if isinstance(nested, dict) and isinstance(nested.get("command"), str):
        return nested["command"]
    tool_input = node.get("tool_input")
    if isinstance(tool_input, dict) and isinstance(tool_input.get("command"), str):
        return tool_input["command"]
    return ""


def has_bash_write(node: Any) -> bool:
    if isinstance(node, dict):
        name = tool_name(node)
        if name == "Bash" and WRITE_COMMAND_RE.search(command_text(node)):
            return True
        return any(has_bash_write(value) for value in node.values())
    if isinstance(node, list):
        return any(has_bash_write(item) for item in node)
    return False


try:
    content = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except Exception:
    print("false")
    raise SystemExit(0)

for line in content.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        if has_bash_write(json.loads(line)):
            print("true")
            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass

try:
    result = has_bash_write(json.loads(content))
except Exception:
    result = False

print("true" if result else "false")
PY
}

extract_changed_files_from_transcript() {
  local transcript_path="$1"

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo "[]"
    return 0
  fi

  # Layer 3: 書き込みツール（Write/Edit/NotebookEdit/MultiEdit）のfile_pathのみ収集。
  # Read/Grep/Globなどの読み取り専用ツールのfile_pathを「変更」と誤認しない。
  python3 - "$transcript_path" <<'PY' 2>/dev/null || echo "[]"
import json
import sys
from typing import Any, Set

WRITE_TOOLS = frozenset({"Write", "Edit", "NotebookEdit", "MultiEdit"})
PATH_KEYS = frozenset({"file_path", "path", "new_path", "old_path", "target_path"})

transcript_path = sys.argv[1]
paths: Set[str] = set()


def collect_paths(node: Any) -> None:
    """Collect file paths from a node known to belong to a write tool."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key.lower() in PATH_KEYS and isinstance(value, str) and value != "":
                paths.add(value)
            collect_paths(value)
        return
    if isinstance(node, list):
        for item in node:
            collect_paths(item)


def find_tool_name(node: Any) -> str:
    """Extract tool name from a dict node."""
    if isinstance(node, dict):
        for key in ("name", "tool_name", "toolName"):
            val = node.get(key, "")
            if isinstance(val, str) and val:
                return val
    return ""


def process_entry(entry: Any) -> None:
    """Walk an entry and only collect paths from write tool invocations."""
    if not isinstance(entry, dict):
        return
    tool_name = find_tool_name(entry)
    if tool_name in WRITE_TOOLS:
        collect_paths(entry)
    # Recurse into nested structures (content, messages, etc.)
    for key in ("content", "messages", "tool_use", "input"):
        child = entry.get(key)
        if isinstance(child, list):
            for item in child:
                process_entry(item)
        elif isinstance(child, dict):
            process_entry(child)


try:
    with open(transcript_path, encoding="utf-8", errors="ignore") as f:
        content = f.read()
except Exception:
    print("[]")
    sys.exit(0)

# JSON Lines format
for line in content.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        process_entry(json.loads(line))
    except Exception:
        pass

# Single JSON object format
try:
    process_entry(json.loads(content))
except Exception:
    pass

print(json.dumps(sorted(paths), ensure_ascii=False))
PY
}

# [2026-05-26][fix]
# 背景:
# - ユーザー依頼意図: Bash の作成系コマンド (`cat > f` / `tee f` / `touch f` / `> f`) の
#   ターゲットパスを transcript から抽出し、git diff フォールバックで「セッションが作成した
#   未追跡ファイルだけ」を拾えるようにする。
# - 守るべき業務ルール: 移動・削除系 (mv / cp / rm) は新規コード作成の判定に使わない。
#   `mv tmp dest` のような plumbing を作成扱いすると、他セッション WIP の誤検知 (R1) を再発させる。
# - 他案不採用理由:
#   1) WRITE_COMMAND_RE の boolean 判定を流用する案は、ターゲットパスが取れず未追跡の絞り込みができない。
#   2) 正規表現だけでパスを分割する案は、`cat > "src/space file.ts"` のような引用符付きパスを見逃す。
# 対応: shlex で Bash コマンドの引用符を解釈し、作成系リダイレクト/コマンドのターゲットだけを抽出する。
extract_bash_created_paths_from_transcript() {
  local transcript_path="$1"

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo "[]"
    return 0
  fi

  python3 - "$transcript_path" <<'PY' 2>/dev/null || echo "[]"
import json
import os
import re
import shlex
import sys
from typing import Any

REDIRECT_TOKEN_RE = re.compile(r"^(?:(?:\d*)>{1,2}|&>{1,2})$")
METACHARS = {";", "|", "&", "<", ">", ">>", "&>", "&>>", "&&", "||"}

# [2026-05-27][fix] issue #201
# 背景:
#   ユーザー依頼意図: `cd scripts && cat > foo.py` のように Bash の cwd が変わった後の
#     ファイル作成を transcript から抽出するとき、cwd を無視して相対パスのまま返すため
#     `git ls-files --others` の `scripts/foo.py` と一致せず未追跡ファイルを見逃す問題を修正したい。
#   守るべき業務ルール: 移動・削除系 (mv / cp / rm) は作成扱いしない（R1 誤検知防止）。
#     変数展開を含む `cd "$VAR"` は追跡不能で、従来どおり相対のまま許容する。
#     cwd 正規化は `detect_changed_files()` 内の created_rel 変換と対称に行う。
#   他案不採用理由:
#     1) cwd を環境変数で渡す案 → Bash ノード間で状態が引き継がれず `cd && cmd` のケースを処理できない。
#     2) shlex の AST パース案 → bash heredoc / 複合コマンドで誤動作しやすく過剰実装。
#   対応: `cwd_from_node()` を追加してノードの cwd フィールドを取得。
#     `harvest()` に cwd 引数を追加し `cd <dir>` を検出したら current_cwd を更新。
#     `add_target()` に cwd 引数を追加して絶対パス正規化を行う。

targets = set()


def cwd_from_node(node):
    """Bash ノードの cwd フィールドを取得する。複数のキー名に対応。"""
    if not isinstance(node, dict):
        return ""
    # 直接フィールド
    v = node.get("cwd")
    if isinstance(v, str) and v:
        return v
    # tool_input.cwd
    ti = node.get("tool_input")
    if isinstance(ti, dict):
        v = ti.get("cwd")
        if isinstance(v, str) and v:
            return v
    # input.cwd
    inp = node.get("input")
    if isinstance(inp, dict):
        v = inp.get("cwd")
        if isinstance(v, str) and v:
            return v
    return ""


def add_target(tok, cwd=""):
    tok = tok.strip()
    # フラグ (-a 等)・FD複製 (&1)・破棄先 (/dev/null) は作成ターゲットではない。
    if not tok or tok.startswith(("-", "&")) or tok == "/dev/null" or tok.endswith("/dev/null"):
        return
    if os.path.isabs(tok):
        targets.add(tok)
    elif cwd:
        targets.add(os.path.normpath(os.path.join(cwd, tok)))
    else:
        targets.add(tok)


def shell_tokens(cmd):
    try:
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except Exception:
        return []


def harvest(cmd, cwd=""):
    tokens = shell_tokens(cmd)
    current_cwd = cwd
    for i, tok in enumerate(tokens):
        # `cd <dir>` を検出して current_cwd を更新
        if tok == "cd" and i + 1 < len(tokens):
            new_dir = tokens[i + 1]
            # 変数展開 ($VAR 等) は追跡不能なのでスキップ
            if not new_dir.startswith("$") and new_dir not in METACHARS:
                if os.path.isabs(new_dir):
                    current_cwd = new_dir
                elif current_cwd:
                    current_cwd = os.path.normpath(os.path.join(current_cwd, new_dir))
                else:
                    current_cwd = new_dir
            continue
        # 作成系リダイレクト `> f` / `1> f`。`2>&1` や `/dev/null` は add_target 側で除外。
        if (tok in {">", ">>", "&>", "&>>"} or REDIRECT_TOKEN_RE.match(tok)) and i + 1 < len(tokens):
            add_target(tokens[i + 1], current_cwd)
            continue
        if tok in {"tee", "touch"}:
            for candidate in tokens[i + 1 :]:
                if candidate in METACHARS:
                    break
                add_target(candidate, current_cwd)


def tool_name(node):
    if isinstance(node, dict):
        for key in ("name", "tool_name", "toolName"):
            v = node.get(key)
            if isinstance(v, str) and v:
                return v
    return ""


def command_text(node):
    if not isinstance(node, dict):
        return ""
    if isinstance(node.get("command"), str):
        return node["command"]
    for key in ("input", "tool_input"):
        nested = node.get(key)
        if isinstance(nested, dict) and isinstance(nested.get("command"), str):
            return nested["command"]
    return ""


def walk(node: Any) -> None:
    if isinstance(node, dict):
        if tool_name(node) in {"Bash", "Shell"}:
            node_cwd = cwd_from_node(node)
            harvest(command_text(node), node_cwd)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for item in node:
            walk(item)


try:
    content = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except Exception:
    print("[]")
    raise SystemExit(0)

for line in content.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        walk(json.loads(line))
    except Exception:
        pass

try:
    walk(json.loads(content))
except Exception:
    pass

print(json.dumps(sorted(targets), ensure_ascii=False))
PY
}

# [2026-05-26][fix]
# 背景:
# - ユーザー依頼意図: jtt-cafe-pj の /insights リフレッシュ作業終了時、Stop hook が
#   別セッションの未追跡 WIP (.claude/skills/dev-guardrails/** 等) を「変更コードファイル」
#   として誤検知し block する事象が実発火した (R1)。クリーンに直したい。
# - 守るべき業務ルール: git diff フォールバックは transcript 検出 (Write/Edit の file_path) が
#   失敗した時の最終手段。未追跡ファイルは git 履歴がなくセッション帰属を判定できないため、
#   無条件に拾うと他セッションの WIP・スクラッチ・他ツール生成物を誤検知する。
# - 他案不採用理由:
#   1) 未追跡検出を完全除去する案 → Bash で新規作成したコードファイル (`cat > scripts/foo.py`) を
#      フォールバックで見逃し品質ゲートが弱くなる (Codex レビュー指摘) ため不採用。
#   2) DOC_SKIP_PATTERNS にディレクトリを足し続ける案 → 「次の untracked に対応できない対症療法」のため不採用。
# 対応: 追跡変更 (git diff / --cached) は常に対象。未追跡ファイルは
#   「このセッションが Bash 作成系で書いたターゲット」(created_paths) に一致するものだけ対象にする。
#   created_paths が空 (transcript 読めない等) の場合は未追跡を一切拾わない (帰属不能なため安全側)。
detect_changed_files() {
  local project_dir="$1"
  local created_paths_json="${2:-[]}"

  python3 - "$project_dir" "$CODE_FILE_PATTERNS" "$created_paths_json" <<'PY' 2>/dev/null || echo "[]"
import json
import os
import re
import subprocess
import sys

project_dir = sys.argv[1]
code_file_pattern = re.compile(sys.argv[2], re.IGNORECASE)
try:
    created = json.loads(sys.argv[3])
    if not isinstance(created, list):
        created = []
except Exception:
    created = []

# セッションが Bash 作成系で書いたターゲットを project_dir 相対パスに正規化。
# basename 一致は使わない（別ディレクトリの同名未追跡ファイルを誤検知するため。Codex レビュー指摘）。
created_rel = set()
for t in created:
    if not isinstance(t, str) or not t:
        continue
    norm = t
    if os.path.isabs(t):
        try:
            norm = os.path.relpath(t, project_dir)
        except Exception:
            norm = t
    if norm.startswith("./"):
        norm = norm[2:]
    created_rel.add(norm)

paths = set()

# 追跡ファイルの変更は常に対象。
for command in (
    ["git", "-C", project_dir, "diff", "--name-only", "-z", "--diff-filter=ACMR"],
    ["git", "-C", project_dir, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"],
):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    for raw_path in result.stdout.split(b"\0"):
        if raw_path:
            paths.add(raw_path.decode("utf-8", errors="surrogateescape"))

# 未追跡は「このセッションが作成したターゲット」に相対パス完全一致するコードファイルだけ対象にする。
if created_rel:
    result = subprocess.run(
        ["git", "-C", project_dir, "ls-files", "--others", "--exclude-standard", "-z"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", errors="surrogateescape")
        if not code_file_pattern.search(path):
            continue
        if path in created_rel:
            paths.add(path)

print(json.dumps(sorted(paths), ensure_ascii=False))
PY
}

json_file_list_is_empty() {
  local files_json="$1"

  python3 -c "
import json
import sys

try:
    print('true' if not json.load(sys.stdin) else 'false')
except Exception:
    print('true')
" <<<"$files_json" 2>/dev/null || echo "true"
}

filter_non_doc_files() {
  local files_json="$1"

  python3 -c "
import json
import re
import sys

pattern = re.compile(sys.argv[1], re.IGNORECASE)

try:
    files = json.loads(sys.argv[2])
except Exception:
    print('[]')
    sys.exit(0)

print(json.dumps([path for path in files if not pattern.search(path)], ensure_ascii=False))
" "$DOC_SKIP_PATTERNS" "$files_json" 2>/dev/null || echo "[]"
}

json_file_list_contains_sql() {
  local files_json="$1"

  python3 -c "
import json
import re
import sys

try:
    files = json.loads(sys.argv[1])
except Exception:
    print('false')
    sys.exit(0)

print('true' if any(re.search(r'\\.sql$', path, re.IGNORECASE) for path in files) else 'false')
" "$files_json" 2>/dev/null || echo "false"
}

format_file_list_for_display() {
  local files_json="$1"

  python3 -c "
import json
import sys

try:
    files = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

for path in files:
    print(json.dumps(path, ensure_ascii=False))
" "$files_json" 2>/dev/null || true
}

# --- メインエントリーポイント ---
# 引数:
#   $1: hook_name     - ログ用の識別子 (例: "subagent-quality-check")
#   $2: hook_root     - hookルートディレクトリ (.claude/hooks/)
#   $3: no_file_change_reason - ファイル変更なし時の理由メッセージ
#   $4: use_git_diff_fallback - git diffフォールバック使用 (default: true)
run_quality_check_hook() {
  local hook_name="$1"
  local hook_root="$2"
  local no_file_change_reason="$3"
  local use_git_diff_fallback="${4:-true}"
  local input project_dir checklist_path stop_hook_active input_changed_files transcript_path transcript_changed_files transcript_readable transcript_bash_write bash_created_paths changed_files non_doc_files formatted_non_doc_files block_reason sql_files security_checklist_path is_codex_hook

  is_codex_hook="false"
  if is_codex_hook_root "$hook_root"; then
    is_codex_hook="true"
  fi

  # [2026-04-26][fix]
  # 背景:
  # - ユーザー依頼意図: Codex Stop hook の stdout/stderr 混在で JSON パース失敗を疑う状態をなくしたい。
  # - 守るべき業務ルール: Codex hook の通常出力は JSON だけに固定し、診断ログは明示的なデバッグ時だけ出す。
  # - 他案不採用理由: 常時 stderr にログを出す案は、Codex 側の厳密な Stop hook JSON 判定で
  #   invalid JSON 扱いの再発要因になり得るため不採用。
  # 対応: Codex 配布先では CODEX_HOOK_DEBUG=1 の時だけ stderr ログを出す。Claude 側は既存どおりログを出す。
  log() {
    if [ "$is_codex_hook" != "true" ] || [ "${CODEX_HOOK_DEBUG:-}" = "1" ]; then
      echo "[hook:${hook_name}] $*" >&2
    fi
  }

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 command is missing, approving as safe fallback"
    if is_codex_hook_root "$hook_root"; then
      echo '{"continue":true}'
    else
      echo '{"decision":"approve","reason":"python3 is required for quality hook. Approved as safe fallback."}'
    fi
    return 0
  fi

  input="$(cat)"
  project_dir="$(resolve_project_dir "$hook_root")"
  checklist_path="$hook_root/lib/code-quality-check.md"

  log "hook invoked for project: $project_dir"

  if [ ! -f "$checklist_path" ]; then
    log "checklist not found at $checklist_path, approving"
    emit_approval_json "$hook_root" "No quality checklist found, skipping."
    return 0
  fi

  stop_hook_active="$(extract_stop_hook_active "$input")"
  if [ "$stop_hook_active" = "true" ]; then
    log "stop_hook_active=true, approving to prevent infinite loop"
    emit_approval_json "$hook_root" "Already in quality check loop, approving to prevent infinite loop."
    return 0
  fi
  if [ "$stop_hook_active" = "error" ]; then
    log "WARNING: failed to parse stop_hook_active from input JSON, approving as fallback"
    emit_approval_json "$hook_root" "Could not parse hook input JSON, approving as safety fallback."
    return 0
  fi

  # Layer 1: agent_type による読み取り専用エージェント即時判定
  # Explore/Plan等はWrite/Editツールを持たない（公式仕様で除外）ため、
  # コード変更は構造的に不可能。ファイル検出を一切行わずapproveする。
  local agent_type
  agent_type="$(extract_agent_type "$input")"
  case "$agent_type" in
    Explore|Plan|feature-dev:code-reviewer|feature-dev:code-architect|feature-dev:code-explorer|claude-code-guide)
      log "read-only agent type '$agent_type', approving without quality check"
      emit_approval_json "$hook_root" "Read-only agent type ($agent_type), quality check not applicable."
      return 0
      ;;
  esac

  input_changed_files="$(extract_changed_files_from_input "$input")"
  if [ "$(json_file_list_is_empty "$input_changed_files")" = "false" ]; then
    changed_files="$input_changed_files"
    log "detected changed files from hook input"
  else
    # Layer 2: agent_transcript_path を優先使用
    # SubagentStopでは agent_transcript_path（サブエージェント固有の履歴）を使い、
    # transcript_path（メインセッション全履歴）へのフォールバックで親の書き込みを誤検知しない。
    transcript_path="$(extract_agent_transcript_path "$input")"
    if [ -z "$transcript_path" ]; then
      transcript_path="$(extract_transcript_path "$input")"
    fi
    transcript_changed_files="$(extract_changed_files_from_transcript "$transcript_path")"
    transcript_readable="$(transcript_was_readable "$transcript_path")"
    transcript_bash_write="$(transcript_has_bash_write_command "$transcript_path")"
    if [ "$(json_file_list_is_empty "$transcript_changed_files")" = "false" ]; then
      changed_files="$transcript_changed_files"
      log "detected changed files from transcript_path"
    elif [ "$transcript_readable" = "true" ] && [ "$transcript_bash_write" = "true" ] && [ "$use_git_diff_fallback" = "true" ]; then
      # 未追跡はセッションが Bash 作成系で書いたターゲットだけに絞る（他セッション WIP の誤検知 R1 防止）
      bash_created_paths="$(extract_bash_created_paths_from_transcript "$transcript_path")"
      changed_files="$(detect_changed_files "$project_dir" "$bash_created_paths")"
      log "transcript has bash write command, falling back to git diff (untracked limited to session-created targets)"
    elif [ "$transcript_readable" = "true" ]; then
      # [2026-04-26][fix]
      # transcript が読めて Write/Edit/MultiEdit/NotebookEdit が 0 件 → /brainstorm 等の質問のみセッション。
      # git diff fallback を呼ぶとバックグラウンド同期で書き換わった派生物 (.opencode/sync-state.json 等) を
      # 「変更ファイル」と誤認するため、ここで approve に進む。
      changed_files="$transcript_changed_files"  # = "[]"
      log "transcript readable but no write tool invocations, approving (B1 fix)"
    elif [ "$use_git_diff_fallback" = "true" ]; then
      changed_files="$(detect_changed_files "$project_dir")"
      log "transcript unreadable, falling back to git diff"
    else
      changed_files=""
      log "git diff fallback disabled, no input/transcript file changes found"
    fi
  fi

  if [ "$(json_file_list_is_empty "$changed_files")" = "true" ]; then
    log "no file changes detected, approving"
    emit_approval_json "$hook_root" "$no_file_change_reason"
    return 0
  fi

  non_doc_files="$(filter_non_doc_files "$changed_files")"
  if [ "$(json_file_list_is_empty "$non_doc_files")" = "true" ]; then
    log "only document files changed, approving"
    emit_approval_json "$hook_root" "Document file change - skipping code quality check."
    return 0
  fi

  formatted_non_doc_files="$(format_file_list_for_display "$non_doc_files")"
  log "code files changed, blocking for quality check: $(echo "$formatted_non_doc_files" | tr '\n' ', ')"

  block_reason="${BLOCK_PREFIX}"$'\n\n'"チェックリスト: ${checklist_path}"

  # SQLファイル変更時はセキュリティレビューチェックリストのパスも追加
  sql_files="$(json_file_list_contains_sql "$non_doc_files")"
  if [ "$sql_files" = "true" ]; then
    security_checklist_path="$hook_root/lib/security-review-check.md"
    if [ -f "$security_checklist_path" ]; then
      block_reason="${block_reason}"$'\n'"セキュリティチェックリスト: ${security_checklist_path}"
      log "SQL files detected, adding security review checklist path"
    fi
  fi

  block_reason="${block_reason}"$'\n\n'"変更されたコードファイル:"$'\n'"${formatted_non_doc_files}"
  # telemetry(harness-checkup): quality-gate deny を記録(fail-open)。
  agent_hub_telemetry_log hook_deny "$hook_name" deny 2>/dev/null || true
  emit_json "block" "$block_reason"
  return 0
}
