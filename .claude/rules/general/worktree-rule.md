<!-- [2026-05-15][feat]
背景:
  - ユーザー依頼意図: `/insights` レポートで「worktree を使わずに main で作業した結果、別セッションのブランチを汚染し cherry-pick で復旧した」という friction が複数件検出されたため、worktree workflow を SSOT 化する。
  - 守るべき業務ルール: worktree 利用を強制ではなく推奨に留める。個人作業（1ファイル編集・1コミット完結タスク）まで worktree 必須にすると運用負荷が増す。並列セッション・複数 PR 同時進行のときだけ worktree を要件とする。
  - 他案不採用理由: (1) SessionStart hook で main 作業を強制ブロックする案は、Markdown / sync-state.json の例外（branch-rule.md）と整合させる条件分岐が複雑になり、誤検出時の復旧コストが高いため不採用。(2) CLAUDE.md にインライン記述する案は、CLAUDE.md が既に 484 行で警告閾値 250 行を超過しているためコンテキスト効率上不採用。
対応: `.claude/rules/general/worktree-rule.md` 新規作成。paths frontmatter は設定せず、全コマンドで参照される常時読み込みルールとする。
-->

<!-- [2026-07-01][refactor]
背景:
  - ユーザー依頼意図: 「メインを掴まない」運用を AGENT-HUB だけでなく全 PJ・全 AI ツールへ広げ、
    AI に main 直接コミットを許す例外をなくしたい。
  - 守るべき業務ルール: AI が変更を加える通常作業では、軽量変更でも専用 worktree + feature branch + PR を使う。
    main 最新化は `git pull` ではなく fetch-only / detached 確認で行う。
  - 他案不採用理由: 「軽量編集なら worktree なし」を残す案は、branch-rule.md の 2026-07-01 方針変更と矛盾するため不採用。
対応: worktree なしでよいケースから main 直接コミットを許す例外を削除し、AI 通常作業では専用 worktree を必須化。
-->

<!-- [2026-07-16][refactor]
背景:
  - ユーザー依頼意図: 常駐ルールダイエット PR2。本ファイルが19,701Bまで肥大化し、全PJ常時読み込みのコンテキストを圧迫。
  - 守るべき業務ルール: 内容は消さない。義務・トリガーはここに残し、復旧手順・実測gotcha・mirror追従の詳細は
    `docs/worktree-operations.md` へ原文のまま移設する（PR1 #997 と同型の二段構え）。
  - 他案不採用理由: 全文をここに残す案は再肥大化を放置。単純削除は復旧手順・実測知見の喪失になり不採用。
対応: 機密symlink/mirror追従/branch contamination復旧/block-main-commit対策/共有checkout詳細を
  `docs/worktree-operations.md` へ移設し、本ファイルは義務・トリガー・骨子だけに縮小。
-->

# Worktree 利用ルール

## いつ worktree を使うか

AI が変更を加える通常作業では、git worktree を作成して別ディレクトリで作業する。
特に以下のいずれかに該当するときは必須:

- **並列セッション**: Claude Code / Codex CLI / Cursor 等を同時に複数立ち上げて別タスクを進める
- **複数 PR 同時進行**: 同一リポジトリで 2 本以上の feature branch を行き来する
- **長期 feature branch**: main から離れて 1 日以上滞在する作業（途中で main を hotfix する可能性がある）
- **軽量変更を含む AI 作業**: 例外なし。詳細は branch-rule.md 参照

例:
```
git worktree add ../jtt-cms-feat-xyz -b feat/xyz
cd ../jtt-cms-feat-xyz
```

## いつ新規 worktree を作らなくてよいか

以下は新規 worktree なしでよい:

- 読み取りだけでファイル変更・commit・push がない場合
- 既に feature branch にチェックアウト済みで、別タスクを差し挟まない場合
- 既にこのタスク専用の worktree / branch にいる場合
- 人間が明示承認した main 直接反映や初回 repo 作成など、branch-rule.md の注記に該当する例外の場合

## 機密ファイル（MCP / .env）の自動 symlink

worktree 作成時、git 追跡外の機密ファイル（`.mcp.json` / `.env` 系）は main worktree の実体へ**自動 symlink**される（git post-checkout hook 由来）。追加操作は不要。仕組み・手動再設置手順・非破壊の詳細は
`~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

## Mac mini ContextEngine mirror の自動追従

Mac Studio 側の worktree は Mac mini の ContextEngine mirror が自動追従する（対象: jtt-cms / jtt-apps / jtt-system / AGENT-HUB / hermes）。索引はミラーであり当日の新規変更は未反映のことがある。詳細・stale削除・semantic強化ジョブは
`~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

## branch contamination が発生した場合の復旧

別セッションのブランチに誤ってコミットした場合は、誤コミット特定 → 正しいブランチへ `cherry-pick` → 復旧用退避作成、の順で対応する。
**`git reset --hard` と force-push はデフォルト禁止。必ずユーザー承認を得てから実行する。**
詳細手順は `~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

## AI セッションから worktree へ commit / push する方法（block-main-commit 対策）

block-main-commit hook は cwd 変更を伴う複合コマンドでの main 直 commit を fail-closed で deny する。AI セッション（cwd=main）から worktree の feature branch へ commit / push する時は:

1. **`isolation: "worktree"` 付きサブエージェントに委譲する**（正攻法）。
2. isolation 指定ができない場合のみ、GitHub API / connector で remote feature branch commit → PR → CI → merge の fallback を使う（main 直更新は禁止のまま）。
3. commit/push を含まない操作（`git add` / `git status` / `gh pr create` 等）はメインセッションから直接 `cd <worktree> && ...` してよい。
4. hook 検査を `bash -c` 等で素通りさせる回避は**禁止**。

サブエージェントの worktree が古いベース（origin/main 以前）から切られる問題への対処、外側隔離 worktree の残存・cleanup 手順、Codex fallback の実測経緯は
`~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

## 共有 checkout / main 非占有ルール（全 PJ・全 AI ツール共通）

対象ルート: `~/LLM-Dev/` `~/business/` `~/Herd/` `~/mac-mini-server/` `~/mcp-servers/` `~/jtt-system/`。Claude / Codex / Cursor / Kimi / OpenCode / Antigravity 全て同じ意味で読む。

**AI セッションは、他者や他エージェントが使う可能性のある `main` checkout を掴まない。** 共有 checkout で merge / pull / cleanup を実行すると、並行セッションとブランチ・HEAD を奪い合って競合する。背景・実測実害は `~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

### 必須：1 タスク = 1 連の完了フロー（PR を出して放置しない）

**専用 worktree 作成 → 編集/commit/push → PR 作成 → マージ → fetch-only / detached 確認 → clean（worktree/branch 削除）まで、必ず一連で最後まで閉じる。** 「PR を出した」「マージした」で止めない。詳細コマンド列は `~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

### AI が `main` で「やらないこと / 代わりにやること」

- **やらない**: `git checkout main` / `git switch main` / `git pull` while on `main` / `git branch -f main`。
- **やる**: `git fetch origin +refs/heads/main:refs/remotes/origin/main` で remote tracking ref を更新する。確認が必要な時は `git worktree add --detach <verify-dir> origin/main` で detached 確認。
- merge は worktree 内から `gh` / `skills/post-merge/scripts/merge-pr.py --confirm-read` で行う。
- **cleanup は自分が作った worktree / branch だけ**削除する。`git worktree list --porcelain` で他セッションのものを確認し**温存する**。
- allowlist 対象の生成 config を main 直コミットする時の stale-main 注意は `~/business/AGENT-HUB/docs/worktree-operations.md` を参照。

要するに「編集だけ worktree、merge/pull は共有 checkout」をやめる。**着手から cleanup まで一貫して専用 worktree**で閉じる。例外的に人間が明示して main checkout を使う場合は、AI が占有している状態でないことと例外理由を作業ログへ残す。

## 既存 worktree の確認

```bash
git worktree list
```

`~/Herd/jtt-apps` 配下には `jtt-apps-api-rate-limit-guards` / `jtt-apps-wt` / `jtt-apps-worktrees` 等の既存 worktree がある（CLAUDE.md `## プロジェクトルート規約` 参照）。新規作成前に既存 worktree の再利用可否を確認すること。

---

**追記ルール: 実測事例・復旧手順・長文詳細は移設先（references / docs）へ書き、本ルールには義務とトリガーだけ足す（再肥大化防止）。**
