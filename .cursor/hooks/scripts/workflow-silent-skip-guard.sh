#!/usr/bin/env bash

# [2026-10-09][feat] Issue #1988
# 背景:
# - ユーザー依頼意図: GitHub Actions で「check ステップが <name>=false を出力し、後続を
#   if: outputs.<name> == 'true' で skip する」書き方をすると、secret/変数不足時にジョブが
#   success のまま何も実行しない（実測: jtt-system supabase-migrations.yml の production 手動実行が
#   3 秒で success、checkout / db push は全 skipped）。この反パターンをドキュメントではなく
#   書き込み時点の deny で構造的に防ぎたい。
# - 守るべき業務ルール: 各リポジトリの既存 workflow 改修は各 PJ のスコープ（jtt-system の
#   supabase-migrations.yml は 2026-09-06 に fail-closed 化済み）。AGENT-HUB 側では
#   ハーネスの PreToolUse deny が「同じ書き方の再発・他 workflow への波及」を防ぐ恒久策になる
#   （Issue #2024 asana-call-guard と同型の、本体修正は別リポ→ハーネス層で防ぐ先例）。
# - 他案不採用理由:
#   1) warning-only（ci-workflow-cost-guard 型）の案は、黙って読み飛ばされ緑のまま
#      本番未適用が再発するため不採用（Issue 本文の「失敗扱いにする」要求と矛盾）。
#   2) 監査スクリプトを各PJのCIへ入れる案は、CI定義は配布対象外で全PJへ届かず、
#      新規 workflow 追加時にしか効かないため不採用（hook は authoring 時点で効く）。
# 対応: PreToolUse で .github/workflows/*.yml への書き込み・編集・生成コマンドを検査し、
#   「<name>=false 出力 + outputs.<name> == 'true' の skip ゲート + fail 経路なし」を
#   修正手順付きで deny する。緊急回避は AGENT_HUB_ALLOW_WORKFLOW_SILENT_SKIP_GUARD=1
#   （hook-library/BYPASS-CONVENTION.md の規約どおり telemetry に残る）。

# [2026-10-21][fix]
# 背景:
# - ユーザー依頼意図: 既存の workflow に「skip_reset=false 出力 + outputs.skip_reset == 'true' 判定」が
#   元からあるだけで、無関係な 1 行追加（jtt-cms deploy-reservation-staging.yml の TRUNCATE 一覧へ
#   1 行足す Edit）まで deny されていた。hook は Edit/MultiEdit を「適用後の全文」で走査するため、
#   編集箇所と関係なく、元からある該当パターンで全ての編集が止まる誤検知だった。
# - 守るべき業務ルール: 見張りの目的は「新しく足した skip 設計」を書き込み時点で止めること
#   （Issue #1988）。元からある問題の是正は各 PJ のスコープで、別の編集を人質にしない。
#   新規に該当パターンを持ち込む編集は従来どおり deny し続ける。
# - 他案不採用理由:
#   1) 判定自体を弱める（outputs 名の許可リスト・skip_reset 例外）案は、新規持ち込みまで通して
#      見張りを弱めるため不採用。
#   2) 該当ファイルを恒久的に対象外にする案は、同じファイルへ別名の問題を足されても止まらず不採用。
# 対応: Edit/MultiEdit は編集前のディスク上の全文でも同じ判定を行い、編集前から有った offender 名を
#   除外して「編集で新たに生じた offender」だけで deny する。編集前ファイルが読めない・新規作成・
#   Write(全文置換) は従来どおり適用後全文で判定する。Bash/apply_patch 経路は追加行のみ走査のため
#   既存行の問題が小さく現状維持。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

read_stdin

# 緊急バイパス（BYPASS-CONVENTION.md 規約）。意図的に skip 設計を残す場合のみ利用者が設定する。
if [ "${AGENT_HUB_ALLOW_WORKFLOW_SILENT_SKIP_GUARD:-}" = "1" ]; then
  exit 0
fi

# deny 理由を返す。空出力なら何もせず終了（allow 扱い）。
# python3 側の想定外エラーは fail-open（hook 自体の失敗で正当な編集を止めない）。
REASON=$(HOOK_INPUT_PAYLOAD="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || true
import json
import os
import re

raw = os.environ.get("HOOK_INPUT_PAYLOAD", "")
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    payload = {}
if not isinstance(payload, dict):
    payload = {}

# tool_input の取り出しは extract_field と同じ優先順位
# （tool_input > toolInput > arguments）。arguments が JSON 文字列の経路も吸収する。
tool_input = {}
for key in ("tool_input", "toolInput", "arguments"):
    candidate = payload.get(key)
    if isinstance(candidate, dict):
        tool_input = candidate
        break
    if isinstance(candidate, str):
        try:
            parsed = json.loads(candidate)
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            tool_input = parsed
            break


def as_text(value):
    return value if isinstance(value, str) else ""


file_path = as_text(tool_input.get("file_path")) or as_text(tool_input.get("path"))
content = as_text(tool_input.get("content"))
old_string = as_text(tool_input.get("old_string"))
new_string = as_text(tool_input.get("new_string"))
command = as_text(tool_input.get("command"))
patch_text = ""
# Codex apply_patch は arguments が raw 文字列で届く経路がある
raw_arguments = payload.get("arguments")
if isinstance(raw_arguments, str):
    patch_text = raw_arguments
for key in ("patch", "input"):
    candidate = tool_input.get(key)
    if isinstance(candidate, str) and candidate:
        patch_text = patch_text + "\n" + candidate if patch_text else candidate
# MultiEdit は edits 配列で届く
edits = tool_input.get("edits")
if not isinstance(edits, list):
    edits = []

WORKFLOW_PATH_RE = re.compile(r"(^|/)\.github/workflows/[^/\s]+\.ya?ml$")
WORKFLOW_MENTION_RE = re.compile(r"\.github/workflows/[^ \t\n;|&'\"]+\.ya?ml")

is_workflow_path = bool(WORKFLOW_PATH_RE.search(file_path))
mentions_workflow = bool(
    WORKFLOW_MENTION_RE.search(command) or WORKFLOW_MENTION_RE.search(patch_text)
)

if not is_workflow_path and not mentions_workflow:
    raise SystemExit

scan = ""
# Edit/MultiEdit で「編集前から有った offender」を除外するための編集前全文（読めなければ None）
base_text = None
if is_workflow_path:
    # Write: content がそのまま対象。Edit/MultiEdit: ディスク上の現行内容へ
    # old_string -> new_string を適用して「書き込み後の姿」を推定する。
    if content:
        scan = content
    else:
        base = ""
        if file_path and os.path.exists(file_path):
            try:
                with open(file_path, encoding="utf-8") as f:
                    base = f.read()
            except Exception:
                base = ""
        if file_path and os.path.exists(file_path):
            base_text = base
        applied = base
        for edit in edits:
            if isinstance(edit, dict):
                old = as_text(edit.get("old_string"))
                new = as_text(edit.get("new_string"))
                if old and old in applied:
                    applied = applied.replace(old, new, 1)
                elif new:
                    applied = applied + "\n" + new
        if old_string and old_string in applied:
            applied = applied.replace(old_string, new_string, 1)
        elif new_string:
            applied = applied + "\n" + new_string
        scan = applied
else:
    # Bash 経由（cat <<EOF > workflow.yml / apply_patch 等）:
    # コマンド本文と patch 本文を対象にする。patch の削除行(-)は除外し、
    # 追加行(+)はマーカーを剥がす（修正 patch が pattern を消す方向なら通す）。
    merged = command + "\n" + patch_text
    kept = []
    for line in merged.splitlines():
        if line.startswith("-"):
            continue
        if line.startswith("+"):
            kept.append(line[1:])
        else:
            kept.append(line)
    scan = "\n".join(kept)

if not scan.strip():
    raise SystemExit

FAIL_RE = re.compile(r"\bexit\s+[1-9]")
EMIT_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['\"]?false")


def find_offenders(lines: list[str]) -> list[str]:
    """「<name>=false 出力 + outputs.<name> == 'true' の skip ゲート + fail 経路なし」の name 一覧。"""
    # 1) GITHUB_OUTPUT へ <name>=false を書き出す行を拾う
    #    （echo "available=false" >> "$GITHUB_OUTPUT" 等。名前は available 以外も拾う）
    emitted: dict[str, list[int]] = {}
    for i, line in enumerate(lines):
        if "GITHUB_OUTPUT" not in line:
            continue
        m = EMIT_RE.search(line)
        if m:
            emitted.setdefault(m.group(1), []).append(i)

    def block_window(start: int, limit: int = 60) -> list[str]:
        """emit 行が属する run ブロック相当の範囲（dedent で打ち切る簡易近似）。"""
        emit_line = lines[start]
        emit_indent = len(emit_line) - len(emit_line.lstrip())
        out = [emit_line]
        for line in lines[start + 1 :]:
            if len(out) >= limit:
                break
            if not line.strip():
                out.append(line)
                continue
            indent = len(line) - len(line.lstrip())
            # fi / else は emit より浅いことがあるため -2 まで許容。
            # 次のステップ（- name: 等）はさらに浅いのでここで打ち切る。
            if indent < emit_indent - 2:
                break
            out.append(line)
        return out

    found: list[str] = []
    for name, idxs in emitted.items():
        # 2) if: <expr>.outputs.<name> == 'true' で後続を skip しているか
        gate_re = re.compile(r"outputs\." + re.escape(name) + r"\s*==\s*['\"]?true")
        if not any(gate_re.search(line) for line in lines):
            continue

        has_fail = False
        # 3a) emit しているブロックの中に exit 1+ があるか（check 時点で fail-closed）
        for i in idxs:
            if any(FAIL_RE.search(line) for line in block_window(i)):
                has_fail = True
                break
        # 3b) outputs.<name> != 'true' / == 'false' で発火する fail ステップがあるか
        if not has_fail:
            neg_re = re.compile(
                r"outputs\."
                + re.escape(name)
                + r"\s*(?:!=\s*['\"]?true|==\s*['\"]?false)"
            )
            for i, line in enumerate(lines):
                if neg_re.search(line) and any(
                    FAIL_RE.search(x) for x in lines[i : i + 40]
                ):
                    has_fail = True
                    break
        if not has_fail:
            found.append(name)
    return found


offenders = find_offenders(scan.splitlines())
if base_text is not None:
    # Edit/MultiEdit: 編集前から有った offender 名は除外し、編集で新たに生じたものだけ止める。
    pre_existing = set(find_offenders(base_text.splitlines()))
    offenders = [n for n in offenders if n not in pre_existing]

if offenders:
    names = ", ".join(sorted(set(offenders)))
    target = file_path or ".github/workflows/*.yml"
    print(
        f"[hook:workflow-silent-skip-guard] {target} に"
        f"「{names}=false を出力 → if: outputs.{offenders[0]} == 'true' で後続 skip → "
        "ジョブ自体は success」パターンがあります。secret/変数が欠けると緑のまま何も適用されません"
        "（AGENT-HUB Issue #1988）。次のどちらかで fail-closed にしてください: "
        "(1) check ステップの不足分岐で ::error:: を出して exit 1 する / "
        f"(2) `if: ...outputs.{offenders[0]} != 'true'` で発火し exit 1 する fail ステップを足す。"
        "意図的な skip 設計のまま進める場合は利用者が "
        "AGENT_HUB_ALLOW_WORKFLOW_SILENT_SKIP_GUARD=1 を設定"
        "（hook-library/BYPASS-CONVENTION.md）。"
    )
PY
)

if [ -n "$REASON" ]; then
  emit_deny "$REASON"
fi

exit 0
