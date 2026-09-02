#!/bin/bash

# [2026-03-03][refactor]
# 背景: jtt-cms Gen 3 のhook-io.shをAGENT-HUBのhook-libraryにポート。
#   PreToolUse/PostToolUse共通のJSON解析・出力関数を一元管理。
#   3PJで同一ロジックが重複しており、修正時の漏れを防止するためコンポーネント化。
# 対応: jtt-cms hook-io.sh をそのままポート。
#
# [2026-03-04][fix]
# 背景: ユーザー意図は「フック判定が環境差（Node有無）で揺れず、同じ入力なら同じ結果になること」。
#   業務ルールとして、JSON抽出はエスケープ文字や改行を含む実データでも破綻してはならない。
#   代替案として sed ベースの簡易抽出を維持すると、文字列中の引用符で誤抽出が起きるため不採用。
# 対応: Node未導入時は Python JSON パースを使う安全フォールバックへ変更。

# --- stdin読み込み ---
# stdinからJSON入力を読み込み、HOOK_INPUT変数に格納する。
# 各フックのエントリポイントで最初に呼ぶこと。
read_stdin() {
  HOOK_INPUT="$(cat)"
}

# --- JSON フィールド抽出 (PreToolUse用) ---
# tool_input内の文字列フィールドを抽出する。Node.js優先、sed fallback。
# 使用例: COMMAND=$(extract_field command)
# [2026-08-30][fix]
# 背景:
#   - ユーザー依頼意図: Codex bridge が apply_patch 本文を top-level arguments に
#     渡す時も、既存ファイルの正当な更新を誤って拒否しないようにする。
#   - 守るべき業務ルール: patch の全経路を同じ docs path gate で検査し、
#     未承認 SSOT や docs/.ssot-allowlist の編集は引き続き fail-closed にする。
#   - 他案不採用理由: arguments 全体を無条件に許可する案は、入力形式の違いで
#     docs 承認制を迂回できるため不採用。
# 対応: tool_input/toolInput に加えて、同じ field 名の arguments object と
# apply_patch 専用の raw arguments string を抽出対象にする。
extract_field() {
  local field="$1"
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$HOOK_INPUT" | node -e '
      const fs = require("fs");
      const field = process.argv[1];
      const raw = fs.readFileSync(0, "utf8");
      let value = "";
      try {
        const parsed = JSON.parse(raw);
        const isObject = (candidate) => candidate && typeof candidate === "object" && !Array.isArray(candidate);
        const containers = [
          isObject(parsed && parsed.tool_input) ? parsed.tool_input : null,
          isObject(parsed && parsed.toolInput) ? parsed.toolInput : null,
          isObject(parsed && parsed.arguments) ? parsed.arguments : null,
          isObject(parsed) ? parsed : null,
        ];
        for (const container of containers) {
          if (!container) continue;
          if (typeof container[field] === "string" && container[field]) {
            value = container[field];
            break;
          }
          if (field === "cwd" && typeof container.workdir === "string" && container.workdir) {
            value = container.workdir;
            break;
          }
        }
        if (!value &&
          parsed &&
          typeof parsed.arguments === "string" &&
          (field === "patch" || field === "input")
        ) {
          value = parsed.arguments;
        }
      } catch {}
      process.stdout.write(value);
    ' "$field" 2>/dev/null || true
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    PY_FIELD="$field" HOOK_JSON="$HOOK_INPUT" python3 - <<'PY' 2>/dev/null || true
import json
import os

field = os.environ.get("PY_FIELD", "")
raw = os.environ.get("HOOK_JSON", "")
value = ""
try:
    parsed = json.loads(raw)
    if isinstance(parsed, dict):
        containers = (
            parsed.get("tool_input"),
            parsed.get("toolInput"),
            parsed.get("arguments"),
            parsed,
        )
        candidate = None
        for container in containers:
            if not isinstance(container, dict):
                continue
            possible = container.get(field)
            if isinstance(possible, str) and possible:
                candidate = possible
                break
            if field == "cwd":
                possible = container.get("workdir")
                if isinstance(possible, str) and possible:
                    candidate = possible
                    break
        if not candidate and isinstance(parsed.get("arguments"), str) and field in {"patch", "input"}:
            candidate = parsed["arguments"]
    if isinstance(candidate, str):
        value = candidate
except Exception:
    pass
print(value, end="")
PY
    return 0
  fi

  # Node / Python が未導入の場合のみ簡易フォールバック（誤抽出リスクあり）
  echo "$HOOK_INPUT" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1 || true
}

# --- file_path抽出 (PostToolUse用) ---
# tool_inputからfile_path（またはpath）を抽出する。Python3使用。
# 使用例: filepath=$(extract_file_path)
extract_file_path() {
  printf '%s' "$HOOK_INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input') or data.get('toolInput') or {}
    print(ti.get('file_path', ti.get('path', '')))
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# --- deny JSON出力 (PreToolUse用) ---
# hookSpecificOutput形式のdeny JSONを出力し、exit 0で終了する。
# 使用例: emit_deny "ブロック理由メッセージ"
# [2026-06-19][fix]
# 背景:
#   - Claude/Codex/Kimi の hook deny 出力で旧 `reason` キーが混在すると、
#     新しい権限UIで理由が表示されない環境がある。
#   - 守るべき業務ルール: deny 理由は `permissionDecisionReason` に統一し、
#     JSON 文字列は Python で escape して壊れた hook 出力を防ぐ。
#   - 他案不採用理由: 各 hook で個別に printf する案は schema 差分と escape 漏れが再発するため不採用。
emit_deny() {
  local reason="$1"
  HOOK_REASON="$reason" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": os.environ.get("HOOK_REASON", ""),
    }
}, ensure_ascii=False, separators=(",", ":")))
PY
  exit 0
}
