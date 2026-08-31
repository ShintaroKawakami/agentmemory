<!-- [2026-08-30][fix]
背景:
  - ユーザー依頼意図: Claude auto mode が EnterWorktree / ExitWorktree を任意の経路として案内するだけでなく、自分の feature worktree で自律実行してほしい。
  - 守るべき業務ルール: worktree-bound な書込みから検証までを main や他セッションの worktree に触れず、安全に閉じる。
  - 他案不採用理由: 全AIクライアントの既存経路を一律変更する案は、Claude auto mode 固有の session 操作を他クライアントへ誤適用するため不採用。
対応: Claude auto mode 専用の必須 lifecycle と、残留 session の一回限り復旧を明文化。

[2026-08-31][refactor]
背景:
  - ユーザー依頼意図: lifecycle の義務は維持したまま、Claude 以外の client surface から除外したい。
  - 守るべき業務ルール: client 差分は rule-registry の applies_to selector で表し、生成後の本文加工に依存しない。
  - 他案不採用理由: 全 client 共通の worktree-rule.md に Claude 固有節を残す案は、resolver が file 単位で選別しても内容が漏れるため不採用。
対応: 本文を独立 rule asset に移し、clients: [claude] の selector で選択する。
-->

# Claude Code auto mode：EnterWorktree / ExitWorktree は必須

Claude Code の **auto mode** は、現在のタスク自身が作成または選択した non-main の feature worktree に対して、次を**自律的に必ず**行う。利用者への都度確認や「使ってよい経路」としての任意扱いにしない。

1. worktree-bound なファイル書込み、commit、push、PR merge、または対象 worktree を cwd にする検証の前に、対象の安全なパスを確認して `EnterWorktree` を実行する。
2. 同じ worktree-bound phase 内の操作はその session cwd で実行する。共有 main checkout、他セッションの worktree、削除済みまたは所有を確認できないパスには入らない。
3. phase が終わったら `ExitWorktree` を `action: "keep"` で実行する。`remove` / 削除系 action、main への書込み、他セッションの worktree 操作は自動化しない。
4. `EnterWorktree` が `Already in a worktree session` で拒否された場合だけ、`ExitWorktree` を `action: "keep"` で**一回**実行してから同じ対象へ再試行する。再試行も失敗した場合は main から続行せず、既存の安全な fallback を使える条件かを確認して安全に停止・報告する。

この rule は Claude Code auto mode 専用である。Codex、Cursor、その他クライアントの既存の安全ルールや実行経路は変更しない。

AI セッション（cwd=main）から feature worktree へ移る場合は、`EnterWorktree` の `path` に対象 worktree を指定する。block-main-commit は cwd 自身の branch で判定するため、main checkout を cwd にしたまま `git -C <worktree> push` すると main 扱いで拒否される（2026-08-18 実測）。作業後は必ず上記の `ExitWorktree` を行う。

サブエージェントの worktree が古いベース（origin/main 以前）から切られる問題への対処、外側隔離 worktree の残存・cleanup 手順、fallback・session lifecycle・merge-pr.py headRefOid 要件の実測経緯は
`~/business/AGENT-HUB/docs/worktree-operations.md` を参照。
