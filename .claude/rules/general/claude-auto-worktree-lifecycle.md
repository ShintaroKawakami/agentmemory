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

[2026-09-08][fix]
背景:
  - ユーザー依頼意図: auto mode なのに EnterWorktree で Yes/No 確認が出る。allow ルールは既に入っているのに改善されていない。
  - 守るべき業務ルール: 定型確認をゼロにし、AI が止まらず worktree 作業を閉じる。
  - 他案不採用理由: permissions.allow の追加は既に済んでおり効かない（外側パスへの permission root 移動は tool 許可と別の確認のため）。
対応: 新規 worktree は EnterWorktree name（.claude/worktrees/ 配下）で作る。外側パス＋path 入場は残置・隔離 worktree への復帰に限る。

[2026-10-03][fix]
背景:
  - ユーザー依頼意図: Issue #2870。末尾の「-C push は常に拒否」という旧記述が現行 hook と食い違い、正規手順の選択を誤らせる。
  - 守るべき業務ルール: hook の許可/拒否条件は変えない（文書の現行挙動同期のみ）。EnterWorktree 経路の位置づけは維持。
  - 他案不採用理由: -C 単純形の許可まで「常に拒否」とする記述維持は不正確のため不採用。
対応: 単純形許可と証明不能形の拒否を分けて記述し、詳細は docs/worktree-operations.md へ委譲。

[2026-10-04][fix]
背景:
  - ユーザー依頼意図: Issue #2819。別リポジトリを cwd に起動した Claude セッション（jtt-system 起動で
    AGENT-HUB を修正する等）では EnterWorktree が他リポジトリの worktree を「起動リポジトリの
    registered worktree ではない」として拒否し、必須 lifecycle を満たせないまま closeout していた。
    代替経路をルールへ明記してほしい。
  - 守るべき業務ルール: hook の許可/拒否条件と EnterWorktree 経路の位置づけは変えない。
    代替経路は実測で通った形だけを正本化する。
  - 他案不採用理由: EnterWorktree を他リポジトリの worktree へ拡張する案は Claude Code 本体の
    仕様変更が必要で本 repo では解消できないため不採用。lifecycle 義務を無条件で緩める案は同一
    リポジトリ運用の安全境界を緩めるため不採用。
対応: 起動リポジトリと対象 worktree のリポジトリが異なる場合の例外と、実測済みの代替経路を明記。
  実測詳細は docs/worktree-operations.md へ記録。
-->

# Claude Code auto mode：EnterWorktree / ExitWorktree は必須

Claude Code の **auto mode** は、現在のタスク自身が作成または選択した non-main の feature worktree に対して、次を**自律的に必ず**行う。利用者への都度確認や「使ってよい経路」としての任意扱いにしない。

1. worktree-bound なファイル書込み、commit、push、PR merge、または対象 worktree を cwd にする検証の前に、対象の安全なパスを確認して `EnterWorktree` を実行する。
2. 同じ worktree-bound phase 内の操作はその session cwd で実行する。共有 main checkout、他セッションの worktree、削除済みまたは所有を確認できないパスには入らない。
3. phase が終わったら `ExitWorktree` を `action: "keep"` で実行する。`remove` / 削除系 action、main への書込み、他セッションの worktree 操作は自動化しない。
4. `EnterWorktree` が `Already in a worktree session` で拒否された場合だけ、`ExitWorktree` を `action: "keep"` で**一回**実行してから同じ対象へ再試行する。再試行も失敗した場合は main から続行せず、既存の安全な fallback を使える条件かを確認して安全に停止・報告する。

この rule は Claude Code auto mode 専用である。Codex、Cursor、その他クライアントの既存の安全ルールや実行経路は変更しない。

**AI が自分で新しい worktree を作るときは `EnterWorktree` の `name` で作る**（置き場所は `.claude/worktrees/` 配下）。
`git worktree add` で `~/business/<pj>-wt/…` など外側のパスに作ってから `EnterWorktree` の `path` で入ると、
`permissions.allow` に `EnterWorktree` があっても **「permission-root relocation to <path> — a model-supplied worktree
outside .claude/worktrees/」の Yes/No 確認が auto mode で毎回出る**（2026-09-08 実測・Claude Code 2.1.263）。
これは tool 許可とは別の permission root 移動の確認で、allow ルールでは消えない。`path` を使うのは、他の経路で
既に存在する worktree（サブエージェントの隔離 worktree・前セッションの残置）へ戻る場合に限る。

AI セッション（cwd=main）から既存の feature worktree へ移る場合は、`EnterWorktree` の `path` に対象 worktree を指定する。main checkout を cwd にしたままの `git -C <worktree> push` は、`-C` 先が non-main と解決できる単純形（bare push・単一の非 main refspec）は許可されるが、`src:dst` refspec（`HEAD:<branch>` 等）や証明できない形は拒否される（Issue #2870・2026-10-03 実測）。証明できない形を通す時は `EnterWorktree` で対象 worktree を cwd にしてから実行する。作業後は必ず上記の `ExitWorktree` を行う。

**起動リポジトリと対象 worktree のリポジトリが異なるセッションでは `EnterWorktree` を使えない。** 別リポジトリを cwd に起動した Claude Code（例: jtt-system で起動して AGENT-HUB を修正する）から他リポジトリの worktree へ `EnterWorktree` の `path` を渡すと「is not a registered worktree of <起動リポジトリ>」で拒否される。`EnterWorktree` は起動リポジトリ（またはその入れ子リポジトリ）の worktree にしか入れない（Issue #2819・2026-10-04 実測）。この場合は必須 lifecycle を満たせないため、代わりに次の代替経路を使う:

- 編集・テスト: 対象 worktree 配下のファイルを絶対パスで操作する（session cwd は動かさない）。
- commit / push: `git -C <worktree> ...` の**単発コマンド**で実行する。パイプ・複合コマンドは block-main-commit が書込先を証明できず拒否する。
- `gh pr create` / `merge-pr.py`: `cd <worktree> && ...` で対象 worktree を cwd にして実行する。cwd が別リポジトリのままだと release-status-pr-gate が拒否する（`merge-pr.py` は headRefOid 要件上もともと対象 worktree の cwd が必要）。

対象 worktree そのものの作成と cleanup は `git -C <repo> worktree add` / `git worktree remove` 等の単発コマンドで行い、この経路でも main checkout・他セッションの worktree・削除系 action の自動化禁止は同じく守る。

サブエージェントの worktree が古いベース（origin/main 以前）から切られる問題への対処、外側隔離 worktree の残存・cleanup 手順、fallback・session lifecycle・merge-pr.py headRefOid 要件の実測経緯は
`~/business/AGENT-HUB/docs/worktree-operations.md` を参照。
