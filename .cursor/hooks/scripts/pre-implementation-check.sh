#!/bin/bash
# UserPromptSubmit フック — 軽量リマインダー（重い処理はしない）
# docs/ の構成を検出し、3層読み込み戦略のリマインダーを出力
#
# 設置先: .claude/hooks/scripts/pre-implementation-check.sh
# トリガー: UserPromptSubmit
# タイムアウト: 5秒
#
# [2026-03-21][fix]
# 背景:
#   - ユーザー依頼意図: PR30レビューで、実装前リマインダーを Claude が次の行動判断に使える状態へ直したい。
#   - 守るべき業務ルール: UserPromptSubmit の非ブロッキング hook は、モデルへ渡したい文言を stdout に出す必要がある。
#   - 他案不採用理由: stderr へ出す方式のままでは、警告文が人間向けログに留まり、実装前コンテキストとして機能しない。
# 対応: 非ブロッキング成功のまま stdout 出力へ統一し、プロジェクト構成に応じたリマインダーを Claude に渡す。
#
# [2026-04-26][fix]
# 背景:
#   - ユーザー依頼意図: AGENT-HUB の UserPromptSubmit hook が毎回大きなリマインダーを表示し、
#     hook失敗のように見えて作業体験を悪化させているため静かにしたい。
#   - 守るべき業務ルール: CaD確認自体はAGENT-HUB運用で必須。ただし通常プロンプトごとに可視出力して
#     失敗表示と混同させてはいけない。
#   - 他案不採用理由:
#     1) stderrへ戻す案はモデル文脈に渡らず、PR30で不採用済みのため不採用。
#     2) settingsだけ残して実体を削除する案は hook 実行時の参照切れを再発させるため不採用。
#     3) CaDリマインダーを完全削除する案は必須運用を失うため不採用。
# 対応: 通常は無音成功にし、明示的に `AGENT_HUB_SHOW_PRE_IMPL_REMINDER=1` を指定した場合だけ stdout に出す。

# プロジェクトルートを検出
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

if [ "${AGENT_HUB_SHOW_PRE_IMPL_REMINDER:-0}" != "1" ]; then
  exit 0
fi

if [ -d "$PROJECT_DIR/docs/business" ]; then
  # docs/business/ が存在する場合: 3層読み込み戦略リマインダー
  cat <<'REMINDER'
⚠️ SSOT 3層読み込み戦略を実行せよ:
Layer 1: CLAUDE.md + rules + prd-active Context Summary
Layer 2: business-design.md / BUSINESS_RULES.md の目次→関係セクション特定
Layer 3: 変更スコープに応じたSSOTの該当セクションだけ全文読み
+ CaD不採用パターンをブロックリスト化 → サブエージェントに引き渡し
+ PM Agent の直接実装禁止 → サブエージェントに委譲
REMINDER
else
  # docs/business/ が存在しない場合: CaD確認リマインダー
  cat <<'REMINDER'
⚠️ CaD確認必須: 変更対象の不採用理由をブロックリスト化 → サブエージェントに引き渡し
REMINDER
fi
