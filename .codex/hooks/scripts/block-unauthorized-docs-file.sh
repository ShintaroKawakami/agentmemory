#!/bin/bash
# @description Blocks AI edits to docs/.ssot-allowlist while allowing ordinary docs work.
# @module hook-library/block-unauthorized-docs-file
# @status stable

# [2026-05-26][feat]
# 背景:
#   - ユーザー依頼意図: dev-guardrails 適用 PJ で、AI が docs/prd/ 等の SSOT ディレクトリに
#     推測でファイル名を決めて勝手に新規ファイル（next-action.md 等）を作る事故を止めたい。
#     AI は一度作ったファイルを自分から消さないため、無断生成物が溜まり続ける。ルール文だけでは
#     AI が破る（指示の遵守は確率的）ため、機械的にブロックする hook を併設する。
#   - 守るべき業務ルール: docs-structure-rules.md（dev-guardrails）。prd/ は固定3ファイル+archives、
#     その他 SSOT ディレクトリ（architecture/business/api/database/operation/benchmark/testing）と
#     docs/ 直下は baseline 許可ファイルのみ。新規 SSOT は伸太郎殿の承認（図解で必要性を説明）後に
#     docs/.ssot-allowlist へ登録してから作る。
#   - 他案不採用理由:
#     1) docs/ 配下を全面ブロックする案: design/ release-notes/ 等の作業用ディレクトリへの
#        正当な新規作成（「デザイン案を作って」等）まで止めるため不採用。構造化 SSOT
#        ディレクトリと docs/直下に限定する。
#     2) prompt 型 hook で LLM 判定する案: 非決定的でチャットにプロンプトが漏れる。確定的な
#        command hook に統一する（hooks-structure-rule.md）。
#     3) 既存ファイルもブロックする案: 更新（Edit/上書き）は自由であるべき。ディスク上に存在する
#        ファイルは grandfather して素通りさせ、純粋な新規作成のみをブロックする。
# 対応: PreToolUse(Write|Edit|MultiEdit|Bash) で docs/ 配下の新規ファイルを検査。構造化 SSOT ディレクトリ +
#   docs/直下 + 未承認の新規 docs/ サブディレクトリを deny し、図解で承認を取るよう AI に指示する。
#   docs/.ssot-allowlist 自体は AI の抜け道になるため手動更新扱いにし、既存ファイルは素通り。
#
# [2026-05-27][fix]
# 背景:
#   - ユーザー依頼意図: docs/plan/ は「廃止」する。プランの本流は ~/.claude/plans/（Claude）や
#     ~/.cursor/plans/ などグローバルへ移っており、各PJの docs/plan/ は古いファイルの堆積（jtt-cms 100件が
#     5/7 から放置等）になっていた。今後 docs/plan/ には新規ファイルを作らせたくない。
#   - 守るべき業務ルール: docs/plan/ は WORK_DIRS（素通り）から外し、完全禁止にする。思考用プランは
#     docs/ の外（~/.claude/plans/）に出るため本 hook は発火しない。docs/plan/ への新規作成だけをブロックする。
#   - 他案不採用理由: docs/plan/ を allowlist で個別解禁する案は、廃止方針と矛盾し再堆積を招くため不採用。
#     design/ release-notes/ は現状の用途が明確でないため WORK_DIRS に残し、plan/ のみ完全禁止にする。
# 対応: WORK_DIRS から plan を除外（design release-notes のみ）。docs/plan/ 新規には「~/.claude/plans/ へ」
#   という専用メッセージで deny する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

# [2026-09-02][policy]
# 個人開発の通常作業を止めない。docs の作成・更新・削除・移動は許可し、
# AI が自分で承認台帳を書き換える唯一の抜け道 docs/.ssot-allowlist だけを deny する。

# baseline 許可（docs-structure-rules.md と一致。構造定義で既に承認済みの正本ファイル）。
is_baseline_allowed() {
  local rel="$1" # docs/ より後ろの相対パス。例: prd/prd-active.md
  case "$rel" in
    # docs/ 直下 SSOT
    FEATURE_FLAGS.md | PERMISSIONS.md) return 0 ;;
    # prd/（固定3ファイル + archives スナップショット）
    prd/prd-active.md | prd/prd-upcoming.md | prd/prd-future.md) return 0 ;;
    prd/archives/*) return 0 ;;
    # architecture/（設計意図 + 条件付き SSOT）
    architecture/database-design.md | architecture/api-design.md) return 0 ;;
    architecture/infrastructure-design.md) return 0 ;;
    architecture/WEBSOCKET_CHANNELS.md) return 0 ;;
    # business/
    business/BUSINESS_RULES.md | business/business-design.md | business/ROLE_DEFINITIONS.md) return 0 ;;
    # api/
    api/API_SSOT.md) return 0 ;;
    # database/
    database/DB_SCHEMA.md | database/DB_SCHEMA_UPDATE_GUIDE.md | database/SCHEMA_RELATIONS.md) return 0 ;;
    # operation/
    operation/PROD_OPERATION.md | operation/STAGING_OPERATION.md | operation/LOCAL_OPERATION.md) return 0 ;;
    operation/NOTIFICATION.md | operation/DEPLOY_LOG.md) return 0 ;;
    operation/DEPLOY_CHECKLIST.md | operation/ENV_VARIABLES.md) return 0 ;;
  esac
  return 1
}

# [2026-06-26][feat]
# 背景:
#   - ユーザー依頼意図: dev-guardrails の per-app SSOT 命名統一（<app>-<kind>.md・4カテゴリ化）
#     に追随し、docs SSOT 承認制 hook の許可パターンを更新する。直前の統一で per-app docs
#     は <app>-business-rules.md / <app>-operations.md / <app>-<topic>-design.md へ
#     命名変更されたが、hook は旧名固定のため新命名ファイルが誤ってブロックされていた。
#   - 守るべき業務ルール: per-app docs は apps/<app>/docs/ 配下に限定し、ファイル名プレフィックス
#     が app 名と一致することを backreference(\1) で機械的に保証する。旧命名ファイルは移行期中の
#     安全のため grandfather として残す。root の docs/architecture/ は per-app から分離し、
#     root 専用扱いを維持する。
#   - 他案不採用理由:
#     1) root docs 判定ロジックに per-app 判定を混ぜる案: root 専用 architecture/ 等との
#        優先順位・エラーメッセージが複雑化し、root ロジックを変更したくない本件の制約に反するため不採用。
#     2) 旧命名 BUSINESS_RULES.md / OPERATIONS_SSOT.md を即座に削除する案: 移行期中に旧ファイル
#        が存在し得るため、誤って既存ファイルの更新をブロックする恐れがあり不採用。
#     3) ワイルドカードで apps/<app>/docs/* を広く許可する案: app 名不一致の推測ファイルや
#        任意名 SSOT を通してしまい、承認制の意味が薄れるため不採用。
# 対応: apps/<app>/docs/ 配下を新たに検査対象に加え、is_per_app_baseline_allowed() で
#   regex backreference 付きの許可パターンを判定する。新命名 + 旧命名 + prd パターンを許可し、
#   それ以外は未承認 SSOT としてブロックする。
is_per_app_baseline_allowed() {
  local rel="$1"
  python3 - "$rel" <<'PY'
import re
import sys
rel = sys.argv[1]
patterns = [
    # 新 naming（dev-guardrails per-app SSOT 命名統一: <app>-<kind>.md）
    r'^apps/([-_a-zA-Z0-9]+)/docs/business/\1-business-rules\.md$',
    r'^apps/([-_a-zA-Z0-9]+)/docs/operation/\1-operations\.md$',
    r'^apps/([-_a-zA-Z0-9]+)/docs/architecture/\1-[-_a-zA-Z0-9]+-design\.md$',
    # 既存 prd pattern
    r'^apps/([-_a-zA-Z0-9]+)/docs/prd/\1-prd-(active|upcoming|future)\.md$',
    # 旧 business/operation（移行期 grandfather）
    r'^apps/([-_a-zA-Z0-9]+)/docs/business/BUSINESS_RULES\.md$',
    r'^apps/([-_a-zA-Z0-9]+)/docs/operation/OPERATIONS_SSOT\.md$',
]
for pat in patterns:
    if re.match(pat, rel):
        sys.exit(0)
sys.exit(1)
PY
}

# [2026-06-19][fix]
# 背景:
#   - jtt-apps レビューで、`auth-design.md` / `PASSWORD_GATES.md` /
#     `PERFORMANCE_BASELINE.md` が存在しない PJ でも baseline 扱いとなり、
#     AI が無承認で新規 SSOT を作れる抜け道になると判明した。
#   - 守るべき業務ルール: 既存ファイルの更新は grandfather で許可するが、
#     PJ に存在しない条件付き SSOT の新規作成は docs/.ssot-allowlist 承認後に限る。
#   - 他案不採用理由: 全PJ共通 baseline に残す案は、存在しない SSOT を正本として
#     既成事実化できるため不採用。

# docs/.ssot-allowlist の glob パターンに一致するか（伸太郎殿が承認して追記したエントリ）。
matches_allowlist_file() {
  local rel="$1"
  local allowlist="$2"
  [ -f "$allowlist" ] || return 1
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line%%#*}"                                  # 行コメント除去
    trimmed="$(printf '%s' "$trimmed" | tr -d '[:space:]')" # 空白除去
    [ -z "$trimmed" ] && continue
    # case パターンとして glob 展開させるため $trimmed は unquoted
    case "$rel" in
      $trimmed) return 0 ;;
    esac
  done <"$allowlist"
  return 1
}

# 安全な deny 出力（理由に改行・引用符を含められるよう python で JSON エスケープ）。
emit_deny_safe() {
  python3 - "$1" <<'PY'
import json
import sys
reason = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}))
PY
  exit 0
}

read_stdin

# A Codex bridge can pass a raw unified patch body instead of JSON. Recognize only
# an input whose first byte begins the exact apply_patch marker; arbitrary raw text
# remains outside the apply_patch path. JSON routes remain handled by hook-io.
RAW_PATCH_TEXT=""
if ! printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 && case "$HOOK_INPUT" in '*** Begin Patch'*) true ;; *) false ;; esac; then
  RAW_PATCH_TEXT="$HOOK_INPUT"
fi

# [2026-07-16][fix]
# 背景:
#   - 依頼意図: Codex の apply_patch でも docs SSOT 承認制と docs/.ssot-allowlist 自己承認禁止を効かせる。
#   - 守るべき業務ルール: Codex の公式 hook 契約では Edit|Write matcher が apply_patch にも一致する。
#     matcher だけ配線して script 側で apply_patch を素通りさせてはならない。
#   - 他案不採用理由: changed_files を完了後だけ検査する案は、自己承認済み成果を worker に作らせた後で
#     止めるため不採用。PreToolUse で patch 対象を決定的に検査する。
# 対応: apply_patch の patch/input から Add/Update/Delete/Move 対象を抽出し、既存の path gate へ渡す。
# tool_name はトップレベルと bridge 環境変数から取得。matcher 設定がずれても fail-open を避けるため空は通す。
TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | python3 -c "import json,os,sys; d=json.load(sys.stdin); print(d.get('tool_name') or d.get('toolName') or d.get('name') or os.environ.get('CLAUDE_TOOL_NAME',''))" 2>/dev/null || true)
[ -n "$RAW_PATCH_TEXT" ] && TOOL_NAME="apply_patch"
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "apply_patch" ] && [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "MultiEdit" ] && [ "$TOOL_NAME" != "WriteFile" ] && [ "$TOOL_NAME" != "StrReplaceFile" ] && [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "Shell" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# docs/ 配下なら絶対パス + docs/ からの相対パスを返す。配下でなければ空。
normalize_docs_path() {
  FP="$1" ROOT="$PROJECT_DIR" HOOK_TOOL_NAME="$TOOL_NAME" python3 - <<'PY' 2>/dev/null || true
import os
import subprocess
# [2026-06-01][fix] codex PR#65 指摘②: abspath は symlink を解決しないため、
# docs/ 自体や中間ディレクトリが symlink の場合に承認制を回避できた。realpath で
# symlink と相対(..)を実体パスに正規化してから docs/ 配下判定を行う。比較対象の
# docs も realpath で揃え、新規ファイル(末端未存在)は既存接頭辞だけ解決される。
fp = os.environ.get("FP", "")
root_input = os.path.abspath(os.environ.get("ROOT", "."))
root = os.path.realpath(root_input)

# [2026-09-02][fix]
# 背景:
#   - ユーザー依頼意図: Codex が専用 worktree を使う通常運用でも、承認台帳の自己変更を実行時に止める。
#   - 守るべき業務ルール: 同じ repository の登録済み worktree は同じ保護を受ける一方、無関係な隣接
#     directory まで project docs と誤認して通常作業を止めない。
#   - 他案不採用理由: PROJECT_DIR 外を一律 deny する案は別 repository や一時ファイルまで止めるため不採用。
# 対応: patch 対象が PROJECT_DIR 外なら `git worktree list` から同じ repository の worktree root だけを
#   解決し、その root の docs/ を既存判定へ通す。
def contains(base, candidate):
    return candidate == base or candidate.startswith(base + os.sep)

def effective_root(lexical_candidate, resolved_candidate):
    if contains(root_input, lexical_candidate) or contains(root, resolved_candidate):
        return root
    # Sibling-worktree patching is a Codex apply_patch execution shape. Keep
    # Claude Write/Edit and shell behavior unchanged.
    if os.environ.get("HOOK_TOOL_NAME") != "apply_patch":
        return ""
    try:
        output = subprocess.check_output(
            ["git", "-C", root, "worktree", "list", "--porcelain"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    worktrees = []
    for line in output.splitlines():
        if line.startswith("worktree "):
            path = os.path.realpath(line[len("worktree "):])
            if contains(path, lexical_candidate) or contains(path, resolved_candidate):
                worktrees.append(path)
    return max(worktrees, key=len, default="")

if not fp:
    print("")
else:
    target = fp if os.path.isabs(fp) else os.path.join(root_input, fp)
    lexical_target = os.path.abspath(target)
    ap = os.path.realpath(target)
    target_root = effective_root(lexical_target, ap)
    docs = os.path.realpath(os.path.join(target_root, "docs")) if target_root else ""
    if docs and (ap == docs or ap.startswith(docs + os.sep)):
        print(ap + "\t" + os.path.relpath(ap, docs))
    else:
        print("")
PY
}

is_gated_rel() {
  local rel="$1"
  local top="$2"
  if [ "$rel" = ".ssot-allowlist" ]; then
    return 0
  fi
  if [ -z "$top" ]; then
    return 0
  fi
  local d
  for d in $GATED_DIRS; do
    [ "$top" = "$d" ] && return 0
  done
  for d in $WORK_DIRS; do
    [ "$top" = "$d" ] && return 1
  done
  # 未登録 docs/<dir>/ は docs-structure-rules の「追加ディレクトリ禁止」に合わせて承認制。
  return 0
}

check_docs_path() {
  local file_path="$1"
  local normalized rel deny_msg
  normalized="$(normalize_docs_path "$file_path")"
  [ -z "$normalized" ] && return 0
  rel="${normalized#*	}"

  # B policy: normal docs work stays available; only AI self-approval is blocked.
  if [ "$rel" = ".ssot-allowlist" ]; then
    deny_msg="[hook:block-unauthorized-docs] docs/.ssot-allowlist の AI 編集をブロックしました。

通常の docs 作成・更新・削除・移動は止めません。docs/.ssot-allowlist だけは、AI が自分で許可を作る抜け道になるため、人の確認が必要です。"
    emit_deny_safe "$deny_msg"
  fi
}

# apps/<app>/docs/ 配下の正規化。root docs/ とは別の階層なので独立した検査を行う。
# apps/<app>/docs/ 配下でなければ空を返す。
normalize_per_app_docs_path() {
  FP="$1" ROOT="$PROJECT_DIR" python3 - <<'PY' 2>/dev/null || true
import os
fp = os.environ.get("FP", "")
root = os.path.realpath(os.environ.get("ROOT", "."))
if not fp:
    print("")
else:
    target = fp if os.path.isabs(fp) else os.path.join(root, fp)
    ap = os.path.realpath(target)
    apps_dir = os.path.realpath(os.path.join(root, "apps"))
    if ap == apps_dir or not ap.startswith(apps_dir + os.sep):
        print("")
    else:
        rel = os.path.relpath(ap, root)
        parts = rel.split(os.sep)
        # apps/<app>/docs/... のみ対象
        if len(parts) >= 4 and parts[2] == "docs":
            print(ap + "\t" + rel)
        else:
            print("")
PY
}

# apps/<app>/docs/ 配下の新規 SSOT 検査。root docs/ ロジックとは独立して動作する。
check_per_app_docs_path() {
  # B policy: apps/<app>/docs/ is ordinary project documentation.
  # Keep this function as the common call site, but never gate normal docs work.
  return 0
}

if [ "$TOOL_NAME" = "apply_patch" ]; then
  PATCH_TEXT="$RAW_PATCH_TEXT"
  if [ -z "$PATCH_TEXT" ]; then
    PATCH_TEXT=$(extract_field patch)
    [ -n "$PATCH_TEXT" ] || PATCH_TEXT=$(extract_field input)
    # [2026-09-02][fix]
    # 背景:
    #   - ユーザー依頼意図: Codex でも正しい apply_patch が安全確認を通り、禁止対象は止まるようにする。
    #   - 守るべき業務ルール: 対象のパスを確認できない変更は通さず、安全確認を省略しない。
    #   - 他案不採用理由: command 全体を patch とみなすと、任意の入力を patch と誤認するため不採用。
    # 対応: tool_input.command は先頭が `*** Begin Patch` の場合だけ patch として読み取り、既存の安全側の扱いを保つ。
    if [ -z "$PATCH_TEXT" ]; then
      COMMAND_PATCH_TEXT=$(extract_field command)
      case "$COMMAND_PATCH_TEXT" in
        '*** Begin Patch'*) PATCH_TEXT="$COMMAND_PATCH_TEXT" ;;
      esac
    fi
    [ -n "$PATCH_TEXT" ] || emit_deny_safe "[hook:block-unauthorized-docs] apply_patch の対象パスを検査できないため、安全側でブロックしました。"
  fi
  PATCH_PATHS=$(printf '%s\n' "$PATCH_TEXT" | python3 -c '
import re, sys
paths = []
for line in sys.stdin.read().splitlines():
    match = re.match(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", line)
    if not match:
        match = re.match(r"^\*\*\* Move to: (.+)$", line)
    if match:
        paths.append(match.group(1).strip())
for path in dict.fromkeys(paths):
    print(path)
')
  # A recognized apply_patch body without an actionable target cannot be inspected.
  # Unlike arbitrary non-JSON text, this is a declared patch transport, so fail closed.
  [ -n "$PATCH_PATHS" ] || emit_deny_safe "[hook:block-unauthorized-docs] apply_patch の対象パスを解釈できないため、安全側でブロックしました。"
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    check_docs_path "$candidate"
    check_per_app_docs_path "$candidate"
  done <<< "$PATCH_PATHS"
  exit 0
fi

if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "Shell" ]; then
  COMMAND=$(extract_field command)
  CWD=$(extract_field cwd)
  [ -z "$CWD" ] && CWD="$PROJECT_DIR"
  [ -z "$COMMAND" ] && exit 0
  printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:];|&])(:>|[0-9]*>{1,2}|&>{1,2}|touch|cat[[:space:]].*([0-9]*>{1,2}|&>{1,2})|cp|mv|rm|install|mkdir|tee|truncate|sed[[:space:]].*-i|perl[[:space:]].*-pi)' || exit 0
  CANDIDATES=$(
    COMMAND_TEXT="$COMMAND" CWD_TEXT="$CWD" PROJECT_DIR="$PROJECT_DIR" python3 - <<'PY'
import os
import re
import shlex

cmd = os.environ.get("COMMAND_TEXT", "")
root = os.path.abspath(os.environ.get("PROJECT_DIR", "."))
current_cwd = os.path.abspath(os.environ.get("CWD_TEXT") or root)
metachars = {";", "|", "&", "<", ">", ">>", "&>", "&>>", "&&", "||"}
paths = []


def resolve_path(token, cwd):
    if not token or token in metachars or token.startswith("-") or token.startswith("$"):
        return ""
    if os.path.isabs(token):
        return os.path.normpath(token)
    return os.path.normpath(os.path.join(cwd, token))


def add_path(token, cwd=None):
    path = resolve_path(token, cwd or current_cwd)
    if path:
        paths.append(path)


def add_copy_like_paths(segment):
    if not segment:
        return
    destination = resolve_path(segment[-1], current_cwd)
    if not destination:
        return
    if os.path.isdir(destination) and len(segment) > 1:
        # [2026-06-19][fix]
        # 背景:
        #   - `cp foo.md docs/prd/` のように宛先が既存ディレクトリの場合、
        #     `docs/prd/` 自体は既存なので grandfather 判定で許可されていた。
        #   - 守るべき業務ルール: 実際に作られる `docs/prd/foo.md` を検査し、
        #     未承認 SSOT の新規作成は同じく止める。
        #   - 他案不採用理由: docs ディレクトリ宛てを全面 deny すると、
        #     allowlist 済みファイルのコピーまで止まり運用が粗くなるため不採用。
        for source in segment[:-1]:
            name = os.path.basename(source.rstrip("/"))
            if name and name not in {".", ".."}:
                paths.append(os.path.join(destination, name))
        return
    paths.append(destination)


def copy_like_operands(command, raw_tokens):
    option_args = {
        "cp": {"-S", "-t", "--suffix", "--target-directory"},
        "mv": {"-S", "-t", "--suffix", "--target-directory"},
        "install": {"-g", "-m", "-o", "-S", "-t", "--group", "--mode", "--owner", "--suffix", "--target-directory"},
    }
    target_directory = None
    operands = []
    index = 0
    while index < len(raw_tokens):
        token = raw_tokens[index]
        if token == "--":
            operands.extend(raw_tokens[index + 1 :])
            break
        if token.startswith("--target-directory="):
            target_directory = token.split("=", 1)[1]
            index += 1
            continue
        if token.startswith("--") and token != "--":
            option = token.split("=", 1)[0]
            if "=" not in token and option in option_args.get(command, set()):
                if option == "--target-directory" and index + 1 < len(raw_tokens):
                    target_directory = raw_tokens[index + 1]
                index += 2
                continue
            index += 1
            continue
        if token.startswith("-") and token != "-":
            short = token[:2]
            if token == short and short in option_args.get(command, set()):
                if short == "-t" and index + 1 < len(raw_tokens):
                    target_directory = raw_tokens[index + 1]
                index += 2
                continue
            if token.startswith("-t") and len(token) > 2:
                target_directory = token[2:]
                index += 1
                continue
            index += 1
            continue
        operands.append(token)
        index += 1
    if target_directory:
        operands.append(target_directory)
    return operands


try:
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except Exception:
    tokens = []

i = 0
while i < len(tokens):
    tok = tokens[i]
    if tok == "cd" and i + 1 < len(tokens):
        target = tokens[i + 1]
        if target not in metachars and not target.startswith("$"):
            next_cwd = resolve_path(target, current_cwd)
            if next_cwd:
                current_cwd = next_cwd
        i += 2
        continue
    if (tok in {">", ">>", "&>", "&>>"} or re.match(r"^(?:(?:\d*)>{1,2}|&>{1,2})$", tok)) and i + 1 < len(tokens):
        add_path(tokens[i + 1])
        i += 2
        continue
    if tok in {"touch", "tee", "mkdir"}:
        for candidate in tokens[i + 1:]:
            if candidate in metachars:
                break
            add_path(candidate)
    if tok in {"cp", "mv", "install"}:
        raw_segment = []
        for candidate in tokens[i + 1:]:
            if candidate in metachars:
                break
            raw_segment.append(candidate)
        segment = copy_like_operands(tok, raw_segment)
        if segment:
            add_copy_like_paths(segment)
    # Moving an allowlist file away deletes the protected source. Other copy-like
    # commands only alter their destination, which is already handled above.
    if tok == "mv":
        for candidate in segment[:-1]:
            add_path(candidate)
    if tok in {"rm", "truncate"}:
        for candidate in tokens[i + 1:]:
            if candidate in metachars:
                break
            if candidate.startswith("-") or candidate.isdigit():
                continue
            add_path(candidate)
    # [2026-05-27][fix] R2 follow-up: sed/perl の in-place 編集ターゲットも検査対象にする。
    #   背景: 前段 grep は sed -i / perl -pi を作成・編集系として検知するが、ここで対象ファイルを
    #   paths に追加していなかったため docs/.ssot-allowlist の AI 編集が素通りしていた。
    #   守るべき業務ルール: docs/.ssot-allowlist は既存ファイルでも AI 編集を必ず deny する。
    #   他案不採用理由: fallback を常時 docs/ パス抽出に戻す案は、PR本文や commit message の
    #   docs/ 言及を再び作成ターゲットと誤認するため不採用。
    if tok in {"sed", "perl"}:
        for candidate in tokens[i + 1:]:
            if candidate in metachars:
                break
            if candidate.startswith("-"):
                continue
            add_path(candidate)
    i += 1

# [2026-05-27][fix] R2 誤検知: punctuation_chars lexer が 1 トークンも取れなかった
#   (引用が壊れた・極端な複合コマンド) 場合に限り、最終手段として docs/ 明示パスを拾う。
#   正常にトークン化できたコマンド (gh pr create --body "...docs/plan/..." / echo / git commit -m
#   等、説明テキストに docs/ を含むだけ) では作動させない。常時 fallback すると、PR 本文や
#   コミットメッセージ中の docs/ 言及を作成ターゲットと誤認して deny してしまう (R2)。
#   作成系のターゲットは上の operation-aware パス (リダイレクト/touch/tee/mkdir/cp/mv/install) が
#   既に網羅しており、トークン化が成功している限り fallback の追加カバレッジはノイズのみ。
if not tokens:
    try:
        fallback_tokens = shlex.split(cmd, posix=True)
    except Exception:
        fallback_tokens = []
    for token in fallback_tokens:
        if token.startswith("./docs/") or token.startswith("docs/"):
            paths.append(token[2:] if token.startswith("./") else token)
    for match in re.findall(r"(?:^|[\s\"'=<>])(\./docs/[^\s\"'`$;|&<>]+|docs/[^\s\"'`$;|&<>]+)", cmd):
        paths.append(match[2:] if match.startswith("./") else match)
for path in dict.fromkeys(paths):
    print(path)
PY
  )
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    check_docs_path "$candidate"
    check_per_app_docs_path "$candidate"
  done <<< "$CANDIDATES"
  exit 0
fi

FILE_PATH=$(extract_file_path)
[ -z "$FILE_PATH" ] && exit 0
check_docs_path "$FILE_PATH"
check_per_app_docs_path "$FILE_PATH"
