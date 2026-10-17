#!/bin/bash

# [2026-03-03][refactor]
# 背景:
#   依頼意図: AIがmainに直接プッシュする事故の再発防止。
#     ルール記載（branch-rule.md）だけでは防げなかった実績があり（F2直接プッシュ事故）、
#     技術的強制力を追加する必要があった。
#   業務ルール: mainマージ = 本番DB即時適用 + 本番デプロイ発火のため、
#     レビューなし変更は業務リスクが高い。
#   不採用理由: ルール記載のみでは実際の事故を防げなかった実績がある。
#     git hookよりもClaude Code PreToolUseの方が実行パスに近く確実にブロックできる。
# 対応: jtt-cms block-main-commit.sh をポート。lib/hook-io.sh を使用。

# [2026-04-10][fix]
# 背景:
#   依頼意図: `git push origin main` が.mdファイルのみでもブロックされるバグの修正。
#   守るべき業務ルール: .mdのみの変更はmainで直接コミット・プッシュ可能（branch-rule.md）。
#   他案不採用理由: Path Aを削除する案はrefspec経由の非docs pushを見逃すため不採用。
#     軽量変更判定をインライン展開する案はPath Bとの重複（DRY違反）のため不採用。
# 対応: 軽量変更 push 判定を is_push_lightweight_only() に関数化し、Path A/B両方から呼び出し。
# 撤回: 2026-07-01 に AI hook 経由の main 直接 commit/push 例外は全廃。上記は履歴のみ。

# [2026-04-18][fix]
# 背景:
#   依頼意図: エージェント環境で origin/main が未解決のとき Markdown のみの push まで拒否される。
#     Cursor/CLI の PreToolUse が同じスクリプトを通すため、比較基準 ref の解決を強化したい。
#   守るべき業務ルール: main 直 push の例外は「Markdown 系ドキュメント + sync-state.json のみ」（CLAUDE.md / branch-rule.md）。
#   他案不採用理由: 非 .md コードを許可する案は本番自動適用リスクのため不採用。
# 対応: 比較 ref を origin/main → refs/remotes/origin/main → main@{upstream} の順で解決。
#       許可拡張子に .mdc / .mdx を含める（Cursor ルール・MDX ドキュメント）。
#   AGENT-HUB: jtt-cms 正本と同一内容を hook-library に同期（docs/prd/prd-active.md 参照）。
# 撤回: 2026-07-01 に Markdown / sync-state 等の main 直 push 例外は全廃。上記は履歴のみ。
#
# [2026-04-27][fix]
# 背景:
#   依頼意図: .codex/sync-state.json のような同期状態ファイルだけで main 直コミットが止まるのは運用上のノイズ。
#   守るべき業務ルール: sync-state.json はツール自動生成の状態ファイルとして Markdown 系ドキュメントと同じ軽量変更扱いにする。
#   他案不採用理由: .json 全体を許可する案は package.json や設定 JSON までレビューなしで通すため不採用。
# 対応: main 直コミット/プッシュの例外に sync-state.json だけを追加し、commit/push で共通判定を使う。
# 撤回: 2026-07-01 に sync-state.json を含む軽量変更例外は全廃。上記は履歴のみ。

# [2026-05-05][fix]
# 背景:
#   依頼意図: Issue #123 で、PR #121 内で Revert された Issue #122 対応を安全に再導入したい。
#     複合コマンド検知ブロックに
#     軽量変更バイパスが未適用のまま main に残っている。.md のみの変更でも `git switch main && git push` で deny される。
#   守るべき業務ルール: main 直 push の例外は「Markdown 系ドキュメント + sync-state.json のみ」（branch-rule.md）。
#     3つの検知パス（複合コマンド、push refspec、mainブランチ）は対称に保つ。
#   他案不採用理由:
#     1) 複合コマンド検知ブロックを削除する案は、refspec 経由の非 docs push を見逃すため不採用（2026-04-10 と同型）。
#     2) staged diff 判定をインライン展開する案は、mainブランチ検知ブロックとの重複（DRY違反）のため不採用。
#     3) `scripts/` 配下のローカル hook を併用する案は、比較 ref と許可拡張子が分岐し SSOT が壊れるため不採用。
# 対応: `is_commit_lightweight_only()` を新設し、mainブランチ検知から呼び出す。
#       複合コマンド検知では switch 後の target ref (`main`) を比較対象にし、commit を含む場合は安全側で deny。
# 撤回: 2026-07-01 に軽量変更バイパスは全廃。上記は履歴のみ。

# [2026-05-16][feat]
# 背景:
#   依頼意図: ccrec 運用で GitHub Actions / Claude Code クレジットを節約するため、
#     人手レビュー価値の薄い運用設定ファイル（agents.yaml / typinator-sync.yaml /
#     MCP 台帳等）も main 直接 push 可にする。
#   守るべき業務ルール: ソースコード・hook 本体（*.sh）・CI 定義（.github/workflows）・
#     Web ビルド設定（package.json / tsconfig.json / composer.json）・hook 登録設定は引き続き PR 必須。
#     許可は事前定義した allowlist のファイル名・パターンに限定する。
#   他案不採用理由:
#     1) .json / .yaml 拡張子全体を許可: package.json / tsconfig.json / composer.json /
#        src/**/*.json までレビューなしで通るため不採用（2026-04-27 と同型の理由）。
#     2) 拡張子許可 + denylist: denylist 漏れが致命的になるため allowlist で明示する方が安全。
#     3) AGENT-HUB 限定で CWD 分岐: 配布先 PJ の AI ツール設定もツール再同期で書き換わるため、
#        全 PJ 一律許可が運用整合的（ユーザー判断 2026-05-16）。
#     4) .github/workflows/*.yml を許可: CI 挙動を無レビューで変えるリスクのため不採用。
#     5) *.sh を許可: hook スクリプト挙動を無レビューで変えるリスクのため不採用。
#     6) 外部設定ファイル化（allowlist を YAML に切り出す）: 比較 ref と許可判定の SSOT が
#        分岐するため不採用（2026-05-05 と同型）。
#     7) hook 登録設定（.claude/settings.json / .codex/hooks.json 等）を許可: block-main-commit
#        自体をレビューなしで弱められるため不採用。
# 対応: is_allowed_main_direct_path() に case 文 allowlist を追加し、hook 登録を含まない AI ツール設定 /
#       AGENT-HUB ルート運用設定 / codex-mcp 台帳を許可する。
# 撤回: 2026-07-01 に運用設定 allowlist も全廃。上記は履歴のみ。

# [2026-05-21][feat]
# 背景:
#   依頼意図: .codex/config.toml と .gemini/hooks/.hook-library-version は Kimi Code MCP 設定 / .cursor/mcp.json
#     と同等の sync 完全自動生成ファイル（手動編集 0 行）だが、2026-05-16 拡張時に取りこぼされていた。
#     対称性を回復して、sync 実行のたびに main 直 push が deny されて GitHub Actions / Claude Code クレジットを
#     消費する状況を解消したい。
#   守るべき業務ルール:
#     - .codex/config.toml は全 PJ で MANAGED CODEX MCP START/END block の完全自動生成のみ。
#       将来 managed block 外の手動編集領域が追加された場合は branch-rule.md を再評価する。
#     - .gemini/settings.json は hook 登録設定（BeforeTool/AfterTool/BeforeAgent）と MCP を混在で持つため
#       allowlist には載せない（hook 登録設定の許可は 2026-05-16 [feat] 不採用理由 7 と同型で禁止）。
#       なお全 PJ で .gemini/settings.json は gitignore のため commit 経路自体が無く、本 hook へ到達しない。
#   他案不採用理由:
#     1) .gemini/settings.json も同時許可: hook 登録を含む混在ファイルのため、settings.json + bridge スクリプト
#        の同時変更で block-main-commit を弱められる経路を作ってしまう（2026-05-16 不採用理由 7 と同型）。
#     2) .gemini/hooks/{lib,scripts}/*.sh / *.py を許可: hook ロジック本体の無レビュー変更を許す
#        （2026-05-16 不採用理由 5 と同型）。
#     3) .toml 拡張子全体を許可: dotfiles/codex/config.toml.base（features.apps 保護対象）まで通る
#        ため不採用（2026-05-16 不採用理由 1 と同型）。
# 対応: is_allowed_main_direct_path() の case 文に .codex/config.toml と
#       .gemini/hooks/.hook-library-version を対称順で追加する。

# [2026-06-05][feat] .codex/hooks.json を main 直接 allowlist に追加(ユーザー承認・過去判断の変更)
# 背景:
#   - ユーザー依頼意図: Codex hook の user-level 移行(PR #284)で各PJの .codex/hooks.json を
#     縮小版へ再配布する。この派生物コミットを毎回 PR にするのは負荷が高く、伸太郎殿の
#     「AIエージェント設定ファイルだけの変更を毎回PRに出したくない」要望(2026-06-05)に応える。
#   - 守るべき業務ルール: .codex/hooks.json は deploy-hooks.py が hook-registry.yaml から生成する
#     sync 自動生成の派生物(手編集禁止、codex-sync.md)。hook 挙動は AGENT-HUB 側 PR で既にレビュー済み。
#   - 他案不採用理由(過去の不採用判断を覆す根拠):
#     2026-05-21 [feat] 不採用理由1 / 2026-05-16 [feat] 不採用理由7 で「hook 登録設定
#     (.claude/settings.json / .codex/hooks.json 等)は block-main-commit 自体を無レビューで
#     弱められるため allowlist 禁止」としていた。今回 .codex/hooks.json のみ覆すのは、
#     (a) deploy-hooks 生成物に限定され手編集しない運用が確立、(b) block-main-commit は
#     Claude(.claude/settings.json は allowlist 据え置き=PR必須)でも効くため Codex 側を弱めても
#     main 保護の実効性が残る、(c) Codex は補助ツール、の3点でリスク限定的と伸太郎殿が判断したため。
#     .claude/settings.json(hook登録の中核)は引き続き allowlist に入れない(PR必須維持)。
# 対応: is_allowed_main_direct_path() の case に .codex/hooks.json を追加。.claude/settings.json は据え置き。

# [2026-06-05][feat] deploy-hooks 配布物(各PJ .claude/hooks/ ・ .codex/hooks/ の scripts/lib)を allowlist 追加
# 背景:
#   - ユーザー依頼意図: Phase E(PR #283) + Codex 移行(PR #284) + allowlist(PR #285)を全PJへ実配布する際、
#     各PJの hook 配布物(block-main-commit.sh / block-skill-reverse-edit.sh / lib 等)を毎回 PR にするのは
#     16PJ規模で非現実的。「設定・配布物の機械的更新を毎回PRにしたくない」要望(2026-06-05)に応える。
#   - 守るべき業務ルール: 各PJ .claude/hooks/ ・ .codex/hooks/ 配下の scripts/lib は deploy-hooks.py が
#     hook-library(SSOT)から配布する派生物。hook 挙動の変更は hook-library 本体の AGENT-HUB PR でレビュー
#     済み。各PJで人が直接編集する運用はなく、drift は sync-reconcile.py が検出する。
#   - 他案不採用理由(覆した過去判断):
#     2026-05-16 #5 で「*.sh(hook ロジック本体)は allowlist 禁止」としていた。今回 .claude/hooks/scripts/ ・
#     .codex/hooks/scripts/ ・ lib/ 配下の配布物のみ覆すのは、(a) これらは hook-library からの機械配布物で
#     SSOT 本体(hook-library/scripts/)は PR 必須のまま、(b) sync-reconcile で drift 検出可能、(c) 各PJ実配布の
#     運用負荷が許容外、の3点。settings.json(block-main-commit の matcher 登録を含む hook 登録の中核)は
#     許可しない(main 保護自体を無レビューで外せてしまうため。2026-05-16 #7 維持)。hook-library/scripts/
#     (SSOT 本体)も別パスのため PR 必須を維持。
# 対応: is_allowed_main_direct_path() の case に .claude/hooks/{scripts,lib}/ ・ .codex/hooks/{scripts,lib}/ を
#   追加。settings.json と hook-library/scripts/ は据え置き。

# [2026-06-23][refactor] 配布差分放置防止のため 2026-06-05 の main 直接 allowlist を撤回
# 背景:
#   - ユーザー依頼意図: AGENT-HUB から hook / skill / rule / agent 派生物を各PJへ配布した後、
#     AI が「これは私の修正したファイルではない」として配布先差分を放置する事故を防ぐ。
#     配布を実行した担当者が PR 作成・レビュー・マージ・cleanup・clean 確認まで責任を持つ。
#   - 守るべき業務ルール: 機械配布物でも、配布先 PJ の tracked 差分は作った担当者が閉じる。
#     .codex/hooks.json と .claude/.codex hooks scripts/lib は main 直接 push ではなく PR 経由に戻す。
#   - 他案不採用理由:
#     1) ルール文書だけの更新は hook allowlist が残り、main 直 push で closeout を迂回できるため不採用。
#     2) --push を即削除する案は既存運用互換の破壊が大きいため、まず hook 側で main 直許可を撤回する。
# 対応: is_allowed_main_direct_path() から .codex/hooks.json と .claude/.codex hooks scripts/lib を削除。

# [2026-06-15][fix] worktree/別リポへの refspec 省略 bare push を許可（PR #369 の取りこぼし修正）
# 背景:
#   依頼意図: `cd <worktree> && git push --force-with-lease`（refspec 省略の bare push）が
#     PR #369 後も deny される。ハーネスは Bash cwd を毎回 main 直下に戻すため worktree への push は
#     refspec 省略の bare push になることが多く（upstream に任せる常用フロー）、worktree 並行開発が成立しない。
#   守るべき業務ルール: main 直 push/commit の保護は厳密(fail-closed)に維持する。本番デプロイ=main push のため。
#   根本原因: has_unsafe_push() が「remote/refspec 欠落の push」を宛先不明として無条件 unsafe にしていた。
#     しかし実効ターゲット(先頭の単一 cd 先)のカレントブランチは判明済み(非 main)で、bare push はその
#     カレントブランチを push するだけ。一律 unsafe は過剰だった。
#   他案不採用理由:
#     1) bare push を実効ブランチ非 main なら無条件許可: push.default=matching(全 matching ブランチ=main 波及)
#        や push.default=upstream で upstream が main のとき main を押す経路が残るため不採用。
#     2) 何もしない案: refspec 省略の worktree push（ユーザーの主要フロー）が不能のままで不便。
#   対応: dir 解決を effective_target_dir() に関数化し、has_unsafe_push() に eff_dir を渡す。bare/remote-only
#     push は eff_dir の push.default + @{upstream} を解決し、matching / upstream→main / 解決不能のみ unsafe、
#     simple(既定)/current 等は非 main カレントブランチのみ push として安全に許可する。明示的 main 宛て /
#     --all/--mirror/wildcard/複数 ref は従来どおり deny。汎用設計のため worktree 以外の別リポにも同様に効く。

# [2026-07-01][refactor] AI hook 経由の main 直接 commit / push 例外を完全撤回
# 背景:
#   依頼意図: 文書ルールだけでなく、PreToolUse hook 実体でも Markdown / sync-state.json /
#     agents.yaml / typinator-sync.yaml 等の軽量変更 allowlist を閉じ、全ディレクトリ・全 AI で
#     main checkout を掴まない運用を強制したい。
#   守るべき業務ルール: AI の通常作業では main branch の commit / push は軽量変更でも deny。
#     非 main branch / 専用 worktree の commit / push は従来どおり許可し、PR 作成フローを壊さない。
#   他案不採用理由:
#     1) allowlist を文書上だけ廃止して hook に残す案は、AI が実際には main 直 commit / push できるため不採用。
#     2) 環境変数 override を追加する案は、AI が自己判断で例外を使う経路になるため不採用。
#     3) 初回 repo 作成や人間明示承認を hook が推測して許可する案は、安全側で判定できないため不採用。
# 対応: is_allowed_main_direct_path は常に deny にし、main branch 検知・main refspec push 検知では
#       軽量差分判定を呼ばず即 deny する。worktree feature branch の早期許可は維持。

# [2026-07-18][fix] git標準ラッパーと先頭空白によるmain保護迂回を防止
# 背景:
#   - ユーザー依頼意図: dirty cleanup PRのレビューで `env git commit` / `command git push` /
#     先頭空白付きgitが検出から漏れ、main直操作を許可できることが判明した。
#   - 守るべき業務ルール: 標準ラッパーや整形上の空白でmain保護の強さを変えない。
#   - 他案不採用理由: `env` 後の任意トークンを許す正規表現は `env echo git ...` まで誤検知するため不採用。
# 対応: command/envの標準形とenv代入だけをコマンド位置で消費し、その後のgitサブコマンドを既存判定へ渡す。

set -euo pipefail

# [2026-05-27][fix] issue #201
# 背景:
#   ユーザー依頼意図: `git -C path push origin main` や `git -c k=v push origin main` のように
#     グローバルオプション付きで git を呼び出すと、既存の正規表現 `git[[:space:]]+push` が
#     マッチせず main 直 push/commit をスルーしてしまう脆弱性を修正したい。
#   守るべき業務ルール: main 直 push/commit のブロックは確実でなければならない。
#     false positive（許可ケースを誤拒否）を増やさないこと。
#   他案不採用理由:
#     1) オプション列を貪欲に `.*` で許可 → セミコロン区切りの複合コマンドで誤マッチしやすい。
#        `[^[:space:]]+` で空白終端を保証する設計の方が安全。
#     2) `-C` / `-c` だけを許可する案 → `git --no-pager push` が fail-open し、
#        main 保護の目的を満たせないため不採用。
#   対応: スクリプト先頭に共通定数 GIT_GLOBAL_OPTS を定義し、値あり/値なしの代表的な
#     git グローバルオプションを消費してから push/commit/switch/checkout を検知する。
# [2026-10-09][fix] issue #2240: git グローバルオプションの値は引用符付き（空白を含む）
#   1トークンも受理する。`git -C "a b" commit` のように引用済み空白を含む値があると
#   `[^[:space:]]+` で値が前半だけに止まり GIT_CMD 全体が不一致になり、commit/push 自体が
#   未検出=無条件許可（fail-open）になっていた穴を塞ぐ。二重引用内の $ ` \ は実行時展開を
#   含みうるため、path 解決側（single_unquoted_git_c_path / effective_target_dir）で
#   改めて解決不能へ倒す。
# git グローバルオプションの値を受理する共通パターン（非引用/単一引用/二重引用の1トークン）。
readonly GIT_ARG_VALUE="(\"([^\"\\\\]|\\\\.)*\"|'[^']*'|[^[:space:]]+)"
# git グローバルオプションを 0個以上許容する共通パターン。
readonly GIT_GLOBAL_OPT="(-C[[:space:]]+${GIT_ARG_VALUE}|-c[[:space:]]+${GIT_ARG_VALUE}|--config-env[[:space:]]+${GIT_ARG_VALUE}|--git-dir(=${GIT_ARG_VALUE}|[[:space:]]+${GIT_ARG_VALUE})|--work-tree(=${GIT_ARG_VALUE}|[[:space:]]+${GIT_ARG_VALUE})|--namespace(=${GIT_ARG_VALUE}|[[:space:]]+${GIT_ARG_VALUE})|--exec-path(=${GIT_ARG_VALUE}|[[:space:]]+${GIT_ARG_VALUE})?|--super-prefix[[:space:]]+${GIT_ARG_VALUE}|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--help|--version|--html-path|--man-path|--info-path|-p)"
readonly GIT_GLOBAL_OPTS="([[:space:]]+${GIT_GLOBAL_OPT})*"
readonly GIT_ENV_VALUE="([^[:space:];&|()'\"]+|'[^']*'|\"([^\"\\\\]|\\\\.)*\")+"
readonly GIT_ENV_ASSIGN="[A-Za-z_][A-Za-z0-9_]*=${GIT_ENV_VALUE}"
readonly GIT_ENV_PREFIX="(${GIT_ENV_ASSIGN}[[:space:]]+)*"
readonly ENV_OPT_WITH_VALUE='(-u|--unset|-C|--chdir|-P|--path|-S|--split-string)[[:space:]]+[^[:space:];&|()]+'
readonly GIT_COMMAND_WRAPPER="(command([[:space:]]+-[^[:space:];&|()]+)*[[:space:]]+|env([[:space:]]+((${ENV_OPT_WITH_VALUE})|-[^[:space:];&|()]+|${GIT_ENV_ASSIGN}))*[[:space:]]+)?"
readonly GIT_CMD="(^|[;&|()])[[:space:]]*${GIT_ENV_PREFIX}${GIT_COMMAND_WRAPPER}${GIT_ENV_PREFIX}git${GIT_GLOBAL_OPTS}"

# [2026-07-18][fix]
# 背景:
#   - PR1018再レビューで、環境変数代入をenv/command wrapperの前に置くとGIT_CMDがgit writeを見失った。
#   - 守るべき業務ルール: POSIXで有効なprefix順序の違いでmain保護の強さを変えない。
#   - 他案不採用理由: FOO=1だけを文字列denyする案は変数名ごとに再発するため不採用。
# 対応: 環境変数prefixをwrapperの前後どちらにも許容し、その後のgit commit/pushを同じ判定へ渡す。

# [2026-07-18][fix]
# 背景:
#   - PR1018最終レビューで、空白を含む引用済み環境変数値がGIT_ENV_PREFIXを分断し、
#     main上の `FOO='a b' git commit` をgit writeなしとして許可できると判明した。
#   - 守るべき業務ルール: shellで有効な引用・escapeを含む代入でもmain保護をfail-openにしない。
#   - 他案不採用理由: quoteを含む行を一律denyすると、説明文やfeature branchの通常操作まで誤拒否する。
# 対応: 環境変数値をunquoted/single-quoted/double-quotedのshell wordとして認識し、wrapper内外で共通利用する。

# [2026-07-18][fix]
# 背景:
#   - ユーザー依頼意図: PR1018再レビューで、feature cwdから `env -C <main>` を使うと
#     hook入力のcwd側ブランチだけを見てmain commit/pushを許可し得る経路が見つかった。
#   - 守るべき業務ルール: 実効cwdを確実に解決できないcommit/pushはfail-closedにする。
#   - 他案不採用理由: env chdir先の完全解決は相対path・複数wrapper・複合commandで誤許可を生むため不採用。
# 対応: env -C/--chdir（=形式を含む）とgit commit/pushが同じ入力にある場合は安全側で拒否する。
# [2026-08-02][fix] env と -C/-S の間に許すトークンを env 自身のオプション/代入に限定する（issue #1344）。
# 背景:
#   - ユーザー依頼意図: 旧パターンの `env([[:space:]]+[^;&|()]*)?` は貪欲で、
#     `env FOO=bar git -C <feature> commit` の **git の -C** まで env の -C（chdir）と誤認し、
#     正当な feature worktree commit/push を fail-closed で誤 deny していた
#     （PR #1343 codex-review 検出・再現ドライバで実測）。
#   - 守るべき業務ルール: env 実行系（-C/--chdir/-S/--split-string）の保守的 deny は維持する。
#     env のオプション解析はコマンド名（最初の非オプション・非代入トークン）で終わるという
#     GNU env の実引数規則を静的に再現し、コマンド名以降の -C/-S は誤認対象から外す。
#   - 他案不採用理由: env 形を全て未解決に倒す従来動作の維持は、日常の env prefix commit を
#     恒常的に止め摩擦が大きい。env の後続を完全 tokenize する案は本 hook の軽量 grep 設計に反する。
# [2026-08-02][fix] 引数を取る env オプション（-u/--unset/シグナル系）は引数ごと消費する
# （PR #1354 codex-review Critical: `env -u FOO -C <main> git commit` の -C が
#   FOO でパターンが止まり chdir 検出から外れるバイパスを塞ぐ）。
# 引数付きを先に列挙し、その後に汎用オプション（-i 等・引数なし）と assignment を置く。
# 汎用側で引数を消費しないのは、`env -i git -C <feature> ...` の git を env の引数と
# 誤認して #1344 の誤 deny を再導入しないため。
readonly ENV_OPT_ARG='(-u|--unset|--block-signal|--default-signal|--ignore-signal)[[:space:]]+[^[:space:];&|()]+'
readonly ENV_OWN_TOKENS='(('"${ENV_OPT_ARG}"'|-[^[:space:];&|()]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|()]*)[[:space:]]+)*'
command_uses_env_chdir() {
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[;&|()])[[:space:]]*(command([[:space:]]+-[^[:space:];&|()]+)*[[:space:]]+)?env[[:space:]]+'"${ENV_OWN_TOKENS}"'(-C([[:space:]]+|[^[:space:];&|()]+)|--chdir(=|[[:space:]]+))'
}

# env -S/--split-string は1引数内の文字列を再分割してコマンド化するため、通常のwrapper解析では
# 実行されるgitを復元できない。git commit/pushを含む場合だけfail-closedにする。
command_uses_env_split_git_write() {
  echo "$COMMAND" | grep -qE '(^|[;&|()])[[:space:]]*(command([[:space:]]+-[^[:space:];&|()]+)*[[:space:]]+)?env[[:space:]]+'"${ENV_OWN_TOKENS}"'(-S([[:space:]]+|[^[:space:];&|()]+)|--split-string(=|[[:space:]]+))' &&
    echo "$COMMAND" | grep -qE 'git.*[[:space:]](commit|push)([^A-Za-z0-9_-]|$)'
}

# [2026-07-11][fix] jtt-apps 本番タグ push 事例（v2.4.37）
# 背景:
#   依頼意図: `git -C <feature-worktree> push origin v2.4.37` のような単発 -C push が、
#     コマンド中に `2>&1` 等のリダイレクトが含まれるだけで single_git_c_target_dir() の
#     `[;&|()]` チェックに誤ヒットし解決不能(deny)になっていた。DEPLOY_CHECKLIST.md の
#     正規タグ push 手順は worktree 経由でしか実行できないため、この誤検知で本番デプロイの
#     唯一の正規経路が塞がれていた。
#   守るべき業務ルール: main 直 push/commit の fail-closed 判定は維持する。リダイレクトは
#     単一コマンドの出力先を変えるだけで複合コマンドの合図ではないため、それだけで
#     解決不能に倒すのは過剰検知。一方 `&`(バックグラウンド実行)や `|`(パイプ)は真に
#     複合コマンドの合図なので、従来どおり解決不能のまま扱う。
#   他案不採用理由:
#     1) `[;&|()]` チェック自体を緩める案: `&` 単体や `|` まで見逃すと後続コマンドの
#        存在を検知できなくなり fail-open になるため不採用。
#     2) has_unsafe_push() のようなトークン単位パーサに全面書き換える案: 影響範囲が
#        広く、今回の誤検知箇所以外の挙動まで変えるリスクがあるため不採用。
# 対応: quote scanner 自身が引用外のリダイレクトだけを識別し、引用済み本文を変更せずに
#   shell 制御演算子を判定する。

# [2026-07-12][fix]
# 背景:
#   依頼意図: main checkout を cwd にした Codex から専用 feature worktree へ
#     `git -C <worktree> commit -m 'fix(auth): ...'` を実行すると、引用符内の `()` を
#     shell 制御演算子と誤認し、正規の branch + PR フローを deny していた。
#   守るべき業務ルール: 引用済みメッセージは git の引数データとして許可する一方、非引用の
#     `; & | ( )`、引用内でも実行される command substitution、壊れた引用は fail-closed にする。
#   他案不採用理由:
#     1) `()` の検査を削る案は subshell を見逃して main 操作を早期許可しうるため不採用。
#     2) conventional commit の括弧だけ正規表現で消す案は、任意の正当な引用済み本文に拡張できず
#        セミコロン等で同じ誤検知が再発するため不採用。
# 対応: 最小の shell quote scanner で、制御演算子が引用の外にある場合だけ真を返す。
#   引用外の `>file` / `<file` / `2>&1` は単一コマンドのリダイレクトとして読み飛ばすが、
#   その後のファイル名や制御演算子は走査を続ける。
has_unquoted_shell_control() {
  local scanner_rc
  if COMMAND_TEXT="$1" python3 - <<'PY'
import os
import sys

text = os.environ.get("COMMAND_TEXT", "")
quote = None
escaped = False
i = 0
while i < len(text):
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if ch == "\\" and quote != "'":
        escaped = True
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        elif ch == '`' or (ch == '$' and i + 1 < len(text) and text[i + 1] == '('):
            raise SystemExit(0)
        i += 1
        continue
    if ch in ("'", '"'):
        quote = ch
    elif ch in "<>":
        # Redirection itself does not compose another command. Skip only its
        # operator/fd-copy portion; keep scanning the target and anything after it.
        direction = ch
        while i + 1 < len(text) and text[i + 1] == direction:
            i += 1
        if i + 1 < len(text) and text[i + 1] == '&':
            i += 1
            while i + 1 < len(text) and (text[i + 1].isdigit() or text[i + 1] == '-'):
                i += 1
    elif ch in ";&|()" or ch == '`':
        raise SystemExit(0)
    i += 1

# Unterminated quoting is ambiguous and therefore unsafe.
raise SystemExit(0 if quote is not None or escaped else 1)
PY
  then
    return 0
  else
    scanner_rc=$?
    # [2026-07-12][fix]
    # 背景:
    #   - 依頼意図: quote scanner の Python 起動不能や異常終了を「安全」と誤認し、main 保護が
    #     fail-open になる経路を閉じたい。
    #   - 守るべき業務ルール: scanner が明示する rc=1 だけを安全とし、未導入・クラッシュ・
    #     想定外終了はすべて曖昧な入力として拒否する。
    #   - 他案不採用理由: テスト用の interpreter override を本番環境変数として公開する案は、
    #     exit 1 を返す任意プログラムで保護を迂回できるため不採用。
    # 対応: python3 は固定し、rc=1 以外を unsafe に正規化する。
    # rc=1 is the scanner's only explicit "safe" result. Missing Python,
    # interpreter crashes, and every other unexpected status stay fail-closed.
    [ "$scanner_rc" -eq 1 ] && return 1
    return 0
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-io.sh"

# telemetry(harness-checkup): deny/バイパスを記録。lib 無しでも壊れない no-op fallback。
# 注意: `set -euo pipefail` 下で `. 存在しないファイル` は `||` フォールバックを素通りして
# シェルごと終了する(bash の source 失敗は errexit 免除の対象外)。存在チェックを先に行い、
# 未配布(telemetry-lib.sh 未同期の配布先)でも deny 本体を絶対に壊さない。
if [ -f "$SCRIPT_DIR/telemetry-lib.sh" ]; then
  . "$SCRIPT_DIR/telemetry-lib.sh" 2>/dev/null || true
fi
if ! declare -f agent_hub_telemetry_log >/dev/null 2>&1; then
  agent_hub_telemetry_log() { :; }
fi

# emit_deny(hook-io.sh) を呼び出す前に telemetry へ deny を記録する薄いラッパ。
# 既存の deny メッセージ・exit 挙動は一切変えない(記録の追加のみ)。
_emit_deny_with_telemetry() {
  agent_hub_telemetry_log hook_deny block-main-commit deny 2>/dev/null || true
  emit_deny "$1"
}

DENY_MSG='[hook:block-main-commit] mainブランチへの直接コミット/プッシュはブロックされました。\n\n対応手順:\n1. git checkout -b feature/xxx でブランチを作成\n2. ブランチ上でコミット\n3. gh pr create でPRを作成\n\n理由: mainマージ = 本番DB自動適用 + 本番デプロイが即座に発動するため、レビューなしの変更は禁止です。'

# [2026-10-03][fix] Issue #3103: 書込先が「別リポジトリ/別worktree」と解決できたのに
# main 文言(DENY_MSG)で止まる誤誘導を直す。
# 背景:
#   - 依頼意図: セッションの作業場所が別リポジトリの main に残ったまま
#     `git -C <worktree> push origin <branch>:refs/heads/wip/...` を投げると、
#     colon refspec は main 波及を静的に否定できず unsafe 判定→最終 deny へ進み、
#     実際は feature 宛てでも「main 直接 push」文言で止まっていた（jtt-apps 9a7c2e83 実害）。
#   - 守るべき業務ルール: 止める条件・許可条件は変えない（文言だけ）。書込先が解決できて
#     session cwd と別リポジトリ/別worktree のときは、別ターゲット文言で
#     「cwd がずれている」ことが分かるメッセージにする。
#   - 他案不採用理由: colon refspec を通す案は main 保護を弱めるため不採用（issue の捨て案）。
OTHER_TARGET_GIT_GUARD_MSG='[hook:block-main-commit] 書込先は別リポジトリ/別worktreeですが、そのブランチが main、または書込が main へ波及しないことを安全に証明できないため停止しました。\n\n対応手順:\n1. 書込先の worktree/リポジトリへ作業場所を移してから、単一の非mainブランチ名だけを指定して commit/push する（src:dst・wildcard・複数 ref・値を取るオプションは証明不能として拒否）\n2. AI worker の未PRブランチを GitHub へ退避する場合は、ai-worker MCP の push_branch_backup(job_id) を使う（refs/heads/wip/ へ安全に push する正式経路）\n\n理由: セッションの作業場所が main のまま別リポジトリ/別worktreeへ書き込むコマンドは、main への波及を静的に否定できない限り拒否します（mainマージ = 本番DB自動適用 + 本番デプロイ）。'

read_stdin

# [2026-10-15][feat] Context Mode 試験導入 F0 / T-08: ctx のコード実行系も同じ検査にかける。
# 背景:
#   - ユーザー依頼意図: Context Mode（MCP サーバー context-mode）のコード実行ツール経由でも
#     main への git commit / push を止める。試験中は実行のたびに確認も出す。
#   - 守るべき業務ルール: 入力が Bash の `command` 欄ではない（ctx_execute / ctx_execute_file は
#     `code`、ctx_batch_execute は `commands[].command`）ため、従来は素通りだった。
#     main への書き込みは「確認」ではなく止める。既存の Bash の挙動は 1 バイトも変えない。
#   - 他案不採用理由: 新しい hook ファイルを足す案は、git 判定を持つ本スクリプトが所有できるため不採用。
#     permissions.ask を hook 断片へ足す案は deploy-hooks.py の assemble/merge が hooks 以外のキーを
#     扱えず、他の読み手（check-pj-readiness 等）にも影響するため不採用。確認（ask）は、既存の配布経路を
#     使う本スクリプトの出力（permissionDecision=ask）で出す。
# 対応: 検査文字列を取り出して Bash 形の入力に組み替え、本スクリプト自身へ渡す（再帰は Bash 入力なので1回だけ）。
#   - deny が返ればそのまま返す。deny でなければ ask を返す（組み立てた命令を静的に見抜けない限界を確認で補う）。
#   - shell 以外の言語の code は `python3 - <<'CTX_EOF'` 形に包み、既存の opaque payload 検査（git→push 並び）にかける。
#   - ctx_upgrade / ctx_insight は常に deny（版の自動更新・外部送信を試験中は使わない）。
# ツール名の接頭辞は分けて組み立てる（hook 本文に MCP ツール名を直書きしない契約: test_active_hook_sources_do_not_call_mcp_tools）。
CTX_PREFIX="mcp""__context-mode__"
CTX_TOOL_NAME=""
case "$HOOK_INPUT" in
  *"${CTX_PREFIX}"*) CTX_TOOL_NAME=$(extract_field tool_name) ;;
esac
case "$CTX_TOOL_NAME" in
  "${CTX_PREFIX}ctx_upgrade"|"${CTX_PREFIX}ctx_insight")
    emit_deny "[hook:block-main-commit] Context Mode の ${CTX_TOOL_NAME#"$CTX_PREFIX"} は試験中は使いません（版は固定・自動更新や外部への送信をしない方針）。必要なら利用者に依頼してください。"
    ;;
  "${CTX_PREFIX}ctx_execute"|"${CTX_PREFIX}ctx_execute_file"|"${CTX_PREFIX}ctx_batch_execute")
    # [2026-10-16][fix] Codex review: 変換に失敗した時に素通りさせない。入力は環境変数ではなく
    #   一時ファイルで渡す（大きい code / commands で引数・環境変数の上限を超えて起動できない経路を塞ぐ）。
    #   変換の失敗（終了コード非0・出力なし）は deny、検査対象が空の時だけ明示の目印で通す。
    CTX_IN_FILE=$(mktemp "${TMPDIR:-/tmp}/ctx-hook-in.XXXXXX") \
      || emit_deny "[hook:block-main-commit] Context Mode の実行内容を検査用に保存できなかったため止めました。"
    printf '%s' "$HOOK_INPUT" > "$CTX_IN_FILE" \
      || { rm -f "$CTX_IN_FILE"; emit_deny "[hook:block-main-commit] Context Mode の実行内容を検査用に保存できなかったため止めました。"; }
    CTX_RC=0
    CTX_REWRITTEN=$(CTX_IN_FILE="$CTX_IN_FILE" python3 - <<'PY' 2>/dev/null
import json
import os

try:
    with open(os.environ["CTX_IN_FILE"], encoding="utf-8") as fh:
        parsed = json.load(fh)
except Exception:
    raise SystemExit(3)
if not isinstance(parsed, dict):
    raise SystemExit(3)
ti = parsed.get("tool_input")
if not isinstance(ti, dict):
    ti = parsed.get("toolInput") if isinstance(parsed.get("toolInput"), dict) else {}
tool = str(parsed.get("tool_name") or "")
SHELL_LANGS = {"shell", "bash", "sh", "zsh"}
text = ""
if tool.endswith("ctx_batch_execute"):
    cmds = ti.get("commands")
    parts = []
    if isinstance(cmds, list):
        for item in cmds:
            if isinstance(item, dict) and isinstance(item.get("command"), str):
                parts.append(item["command"])
            elif isinstance(item, str):
                parts.append(item)
    text = "\n".join(parts)
else:
    code = ti.get("code")
    if isinstance(code, str) and code.strip():
        lang = str(ti.get("language") or "").strip().lower()
        if lang in SHELL_LANGS:
            text = code
        else:
            text = "python3 - <<'CTX_EOF'\n" + code + "\nCTX_EOF"
if not text.strip():
    print("__CTX_EMPTY__", end="")
    raise SystemExit(0)
new_ti = {"command": text}
cwd = ti.get("cwd") or ti.get("workdir") or parsed.get("cwd") or parsed.get("workdir")
if isinstance(cwd, str) and cwd:
    new_ti["cwd"] = cwd
out = dict(parsed)
out["tool_name"] = "Bash"
out["tool_input"] = new_ti
out.pop("toolInput", None)
print(json.dumps(out, ensure_ascii=False), end="")
PY
) || CTX_RC=$?
    rm -f "$CTX_IN_FILE"
    if [ "$CTX_RC" -ne 0 ] || [ -z "$CTX_REWRITTEN" ]; then
      emit_deny "[hook:block-main-commit] Context Mode の実行内容を検査できなかったため止めました（入力の読み取りに失敗）。"
    fi
    if [ "$CTX_REWRITTEN" = "__CTX_EMPTY__" ]; then
      exit 0
    fi
    # [2026-10-16][fix] Codex review 2: 内部検査の異常終了を握りつぶさない。deny 以外で非0なら止める
    #   （main への書き込みは「確認」ではなく止める方針。検査できなかった時も確認へ進めない）。
    CTX_INNER_RC=0
    CTX_INNER_OUT=$(printf '%s' "$CTX_REWRITTEN" | bash "${BASH_SOURCE[0]}" 2>/dev/null) || CTX_INNER_RC=$?
    if printf '%s' "$CTX_INNER_OUT" | grep -q 'permissionDecision.*deny'; then
      printf '%s\n' "$CTX_INNER_OUT"
      exit 0
    fi
    if [ "$CTX_INNER_RC" -ne 0 ]; then
      emit_deny "[hook:block-main-commit] Context Mode の実行内容の検査が異常終了したため止めました（終了コード ${CTX_INNER_RC}）。"
    fi
    python3 - <<'PY'
import json

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": (
            "[hook:block-main-commit] Context Mode 試験中: コード実行は毎回確認します。"
            "main への git commit / push は自動で止めますが、変数・eval・文字列の組み立てで作った命令は"
            "静的に見抜けないため、実行内容を目で確認してから許可してください。"
        ),
    }
}, ensure_ascii=False, separators=(",", ":")))
PY
    exit 0
    ;;
esac

COMMAND=$(extract_field command)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# CWD取得（push refspec検知より前に必要）
CWD=$(extract_field cwd)
if [ -z "$CWD" ]; then
  CWD="."
fi

# [2026-08-02][fix] #1313 / #1256: commit message・PR/Issue本文をgit実行列から除外する。
# 背景:
#   - 依頼意図: `git commit -m '説明; git push origin main'` や
#     `gh pr create --body 'git reset --hard'` の本文を、実行されたgit writeとして
#     誤検知しない。ガード自身の修正記録・PR本文が書けない摩擦を解消する。
#   - 守るべき業務ルール: 引用外の `; git ...`、実際の command substitution、shell wrapper は
#     従来どおり安全側で扱う。除外するのは `-m/--message/--body/--body-file` の引数データだけ。
#   - 他案不採用理由: コマンド全体の `git` 文字列を無視する案は、引用外のmain pushを見逃す。
#     正規表現へ例外を足し続ける案は引用境界を扱えず、同じ誤検知を再発させる。
# 対応: shellの引用境界を小さく走査し、本文系オプションの次の1 tokenだけを空白化した
#       判定用コピーを作る。実行用の COMMAND は変更せず、quote scanner / -C path 解決は従来どおり
#       raw input を参照する。展開を含む本文は空白化せず、保守的に検出・拒否する。
sanitize_git_data_args() {
  COMMAND_TEXT="$1" python3 - <<'PY' 2>/dev/null || printf '%s' "$1"
import os
import shlex

text = os.environ.get("COMMAND_TEXT", "")
mask = [False] * len(text)
data_options = {"-m", "--message", "--body", "--body-file"}

def spans(value):
    result = []
    index = 0
    length = len(value)
    while index < length:
        if value[index].isspace():
            index += 1
            continue
        if value[index] in ";|&()":
            result.append((index, index + 1, value[index]))
            index += 1
            continue
        start = index
        quote = None
        escaped = False
        while index < length:
            char = value[index]
            if escaped:
                escaped = False
                index += 1
                continue
            if quote == "'":
                if char == "'":
                    quote = None
                index += 1
                continue
            if quote == '"':
                if char == '"':
                    quote = None
                elif char == "\\":
                    escaped = True
                index += 1
                continue
            if char in ("'", '"'):
                quote = char
                index += 1
                continue
            if char == "\\":
                escaped = True
                index += 1
                continue
            if char.isspace() or char in ";|&()":
                break
            index += 1
        result.append((start, index, value[start:index]))
    return result

def decoded(raw):
    try:
        values = shlex.split(raw, posix=True)
    except ValueError:
        return raw
    return values[0] if len(values) == 1 else raw

def has_executable_expansion(raw):
    quote = None
    escaped = False
    index = 0
    while index < len(raw):
        char = raw[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if char == '"':
                quote = None
            elif char == "\\":
                escaped = True
            elif char == "$" and index + 1 < len(raw) and raw[index + 1] == "(":
                return True
            elif char == "`":
                return True
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
        elif char == "\\":
            escaped = True
        elif char == "$" and index + 1 < len(raw) and raw[index + 1] == "(":
            return True
        elif char == "`":
            return True
        index += 1
    return False

tokens = spans(text)
expect_data = False
for start, end, raw in tokens:
    if raw in ";|&()":
        expect_data = False
        continue
    value = decoded(raw)
    if expect_data:
        # A command substitution/backtick is executable text, not static data.
        # Keep it visible so the existing fail-closed patterns can reject it.
        if not has_executable_expansion(raw):
            for position in range(start, end):
                mask[position] = True
        expect_data = False
        continue
    if value in data_options:
        expect_data = True
        continue
    if any(value.startswith(option + "=") for option in ("--message", "--body", "--body-file")):
        for position in range(start, end):
            mask[position] = True
        continue
    # `-mtext` is a valid git short option form. The whole token is message data.
    if value.startswith("-m") and len(value) > 2 and not value.startswith("--"):
        for position in range(start, end):
            mask[position] = True

# [2026-10-10][fix] issue #1361 事象2: heredoc 本体（<<'EOF' ... EOF）は
#   実行コマンドではなく stdin データ。`cat <<'EOF'` や
#   `gh issue create --body "$(cat <<'EOF' ... EOF)"` の本文に git/gh の
#   文字列があっても実行されないため、判定用コピーから空白化する。
#   ただし本体が「実行されるプログラム」になりうる形は残す:
#   - 同一パイプラインに python3/sh/bash/node 等の不透明実行名、または
#     $VAR 等の特定不能な実行名がある（body がその stdin プログラムになる）
#   - 非引用デリミタ（<<EOF）で本体に $(...) / バッククォートがある（実行される）
import re

_OPAQUE_SINKS = {
    "node", "nodejs", "ruby", "perl", "php", "lua", "osascript", "expect",
    "eval", "env", "xargs", "source", ".",
    "bash", "sh", "zsh", "dash", "ksh", "fish", "ash", "csh", "tcsh",
    "nu", "pwsh", "powershell",
    "ssh", "sudo", "make", "just", "rake", "bundle",
    "npm", "npx", "yarn", "pnpm", "pipenv", "poetry", "cargo", "go",
    "docker", "kubectl", "watch", "parallel", "tmux", "screen",
}
# [2026-10-13][fix] issue #3922: quoted heredoc 本体が「非シェル系インタプリタ
#   （python3 / node / ruby 等）の stdin プログラム」になる場合、本体を
#   `python3 -c '...'` と同等の単一引用文字列として残す。
#   背景:
#     - ユーザー依頼意図: `python3 - <<'EOF' ... EOF` でファイルを書き換える
#       だけのコマンドが、本体の git/gh 言及をきっかけに shell 構文解析へ進み、
#       Python 本体が shell として解析不能となり「ambiguous shell argument
#       concatenation」で誤拒否されていた。
#   - 守るべき業務ルール: 本体の git/gh 言・github.com 言及と opaque payload
#     検査（git→push 並び）は従来どおり効かせる（`-c` 引数と同じ検査面積）。
#     シェル系実行（sh / bash / zsh 等）が同じパイプラインにある場合は本体が
#     実際に shell として実行されうるため、従来どおり生のまま残す
#     （fail-open を作らない）。非引用デリミタ（$(...) が実行されうる）や
#     終端が見つからない形も同様に残す。
#   - 他案不採用理由: 本体を空白化する案は python 本体の git push 実行を
#     言及・opaque 検査から外してしまうため不採用。シェル判定を追加せず全ての
#     不透明 sink で文字列化する案は `sh <<'EOF' git push EOF` の実行本体を
#     検査不能にするため不採用。
_SHELL_SINKS = {
    "bash", "sh", "zsh", "dash", "ksh", "fish", "ash", "csh", "tcsh",
    "nu", "pwsh", "powershell",
}
_NON_SHELL_SINKS = {
    "node", "nodejs", "ruby", "perl", "php", "lua", "osascript",
}
_COMMAND_KEYWORDS = {
    "for", "do", "done", "if", "then", "else", "elif", "fi",
    "while", "until", "case", "esac", "select", "{", "}",
}
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
n = len(text)


def read_cmd_word(start):
    """実行名位置の1語を読み、(デコード済み語, 特定不能フラグ, 終端index) を返す。"""
    out = []
    j = start
    q = None
    esc = False
    indeterminate = False
    while j < n:
        c = text[j]
        if esc:
            out.append(c)
            esc = False
            j += 1
            continue
        if q:
            if c == q:
                q = None
            else:
                out.append(c)
            j += 1
            continue
        if c == "\\":
            esc = True
            j += 1
            continue
        if c in "'\"":
            q = c
            j += 1
            continue
        if c in " \t\r\n;&|()<>":
            break
        if c in "$`":
            indeterminate = True
        out.append(c)
        j += 1
    return "".join(out), indeterminate, j


def parse_heredoc_delim(k):
    """<< 直後のデリミタを読み (delim, quoted, end_index) を返す。読めなければ None。
    引用符・バックスラッシュを1つでも含むデリミタは本体が展開されない quoted 扱い。"""
    if k >= n or text[k] in " \t\n;&|()<>":
        return None
    if text[k] == "'":
        e = text.find("'", k + 1)
        return None if e < 0 else (text[k + 1:e], True, e + 1)
    if text[k] == '"':
        e = text.find('"', k + 1)
        return None if e < 0 else (text[k + 1:e], True, e + 1)
    out = []
    quoted = False
    j = k
    while j < n and text[j] not in " \t\n;&|()<>":
        c = text[j]
        if c == "\\" and j + 1 < n:
            out.append(text[j + 1])
            quoted = True
            j += 2
            continue
        if c in "'\"":
            e = text.find(c, j + 1)
            if e < 0:
                return None
            out.append(text[j + 1:e])
            quoted = True
            j = e + 1
            continue
        out.append(c)
        j += 1
    if not out:
        return None
    return ("".join(out), quoted, j)


def consume_heredoc_bodies(start):
    """pending の heredoc 本体行（終端行を含む）を消費して新しい index を返す。
    パイプラインに不透明実行が無く、本体に置換が無いものだけ mask する。
    非シェル系インタプリタの stdin になる引用本体は単一引用の文字列へ変換する。"""
    cur = start
    for delim, strip_mode, quoted in pending:
        body_start = cur
        danger = False
        end = None
        term_start = None
        scan = cur
        while scan <= n:
            nl = text.find("\n", scan)
            line = text[scan:] if nl < 0 else text[scan:nl]
            if strip_mode == "tabs":
                check = line.lstrip("\t")
            elif strip_mode == "all":
                check = line.lstrip(" \t")
            else:
                check = line
            if check == delim:
                term_start = scan
                end = (nl + 1) if nl >= 0 else n
                break
            if not quoted and ("$(" in line or "`" in line):
                danger = True
            if nl < 0:
                break
            scan = nl + 1
        if end is None:
            end = n
        if (quoted and term_start is not None and term_start > body_start
                and group_nonshell and not group_shell):
            # 本体は実行コマンドではなく stdin の他言語プログラム。
            # `python3 -c '...'` と同等の不透明ペイロードとして単一引用で包み、
            # shell 構文解析だけを外す（言及・opaque 検査は有効のまま）。
            # 範囲は本体だけ（終端行は外）: 終端行まで包むと引用が終端の改行を
            # またぎ、直後のコマンドが本体の文字列に癒着して git/gh 実行が
            # 見えなくなる。
            quote_wraps.append((body_start, term_start))
            cur = end
            continue
        if not group_opaque and not danger:
            for pos in range(body_start, end):
                mask[pos] = True
        cur = end
    pending.clear()
    return cur


# 引用・$(...)・バッククォートを追跡しながら、コマンド文脈にある << を探す。
# pending: 当該行で見つけた heredoc デリミタのキュー。group_opaque: 現在の
# パイプライン(| で繋がる一群)に不透明/特定不能の実行名が1つでもあるか。
# group_shell / group_nonshell: 同パイプラインのシェル系・非シェル系
# インタプリタ検出（quote_wraps の heredoc 文字列化判定に使う）。
stack = []
pending = []
group_opaque = group_shell = group_nonshell = False
quote_wraps = []
cmd_pos = True
i = 0
quote = None
escaped = False
in_backtick = False
while i < n:
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if in_backtick:
        if ch == "\\":
            escaped = True
        elif ch == "`":
            in_backtick = False
            quote = stack.pop() if stack else None
            cmd_pos = False
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        elif ch == "\\":
            escaped = True
        elif ch == "`":
            stack.append('"')
            in_backtick = True
            cmd_pos = True
            group_opaque = group_shell = group_nonshell = False
        elif ch == "$" and i + 1 < n and text[i + 1] == "(":
            stack.append('"')
            quote = None
            cmd_pos = True
            group_opaque = group_shell = group_nonshell = False
            i += 1
        i += 1
        continue
    if ch == "\\":
        escaped = True
        i += 1
        continue
    if ch in "'\"":
        quote = ch
        i += 1
        continue
    if ch == "`":
        stack.append(None)
        in_backtick = True
        cmd_pos = True
        group_opaque = group_shell = group_nonshell = False
        i += 1
        continue
    if ch == "$" and i + 1 < n and text[i + 1] == "(":
        stack.append(None)
        cmd_pos = True
        group_opaque = group_shell = group_nonshell = False
        i += 2
        continue
    if ch == "(":
        stack.append(None)
        cmd_pos = True
        group_opaque = group_shell = group_nonshell = False
        i += 1
        continue
    if ch == ")":
        quote = stack.pop() if stack else None
        cmd_pos = False
        i += 1
        continue
    if ch == "\n":
        if pending:
            i = consume_heredoc_bodies(i + 1)
            continue
        cmd_pos = True
        group_opaque = group_shell = group_nonshell = False
        i += 1
        continue
    if ch in ";&":
        nxt = text[i + 1] if i + 1 < n else ""
        cmd_pos = True
        group_opaque = group_shell = group_nonshell = False
        i += 2 if nxt == ch else 1
        continue
    if ch == "|":
        cmd_pos = True
        if i + 1 < n and text[i + 1] == "|":
            group_opaque = group_shell = group_nonshell = False
            i += 2
        else:
            i += 1
        continue
    if ch == "<":
        j = i + 1
        while j < n and text[j] == "<":
            j += 1
        if j - i == 2:
            k = j
            strip_mode = None
            if k < n and text[k] in "-~":
                strip_mode = "tabs" if text[k] == "-" else "all"
                k += 1
            while k < n and text[k] in " \t":
                k += 1
            parsed = parse_heredoc_delim(k)
            if parsed is not None:
                delim, quoted_delim, end = parsed
                pending.append((delim, strip_mode, quoted_delim))
                i = end
                continue
        i += 1
        continue
    if ch in " \t\r>":
        i += 1
        continue
    if cmd_pos:
        word, indeterminate, wend = read_cmd_word(i)
        if word:
            if _ASSIGN_RE.match(word):
                cmd_pos = True   # 代入 prefix の後も実行名位置が続く
            elif word == "in":
                cmd_pos = False  # in の直後は列挙値で、; / do で実行名位置へ復帰する
            elif word in _COMMAND_KEYWORDS:
                cmd_pos = True   # do/then/else/done/fi/esac/{/} の後は実行名位置
            else:
                base = word.rsplit("/", 1)[-1].lower()
                if indeterminate or base in _OPAQUE_SINKS or base.startswith("python"):
                    group_opaque = True
                if base in _SHELL_SINKS:
                    group_shell = True
                if base.startswith("python") or base in _NON_SHELL_SINKS:
                    group_nonshell = True
                cmd_pos = False
            i = wend
            continue
    i += 1

# quote_wraps の本体は「本体開始・終端行先頭に単一引用を挿入し、
# 本体内の単一引用を '"'"' へエスケープ」して、不透明ペイロードを1つの
# 文字列引数として残す。言及・opaque 検査は本文を読めるまま、
# shell 構文解析だけを外す。
wrap_starts = {body_start for body_start, _ in quote_wraps}
wrap_ends = {end for _, end in quote_wraps}
wrap_squotes = {
    pos
    for body_start, end in quote_wraps
    for pos in range(body_start, end)
    if text[pos] == "'"
}
out = []
for position, char in enumerate(text):
    if position in wrap_starts or position in wrap_ends:
        out.append("'")
    if position in wrap_squotes:
        out.append('\'"\'"\'')
    elif mask[position]:
        out.append(" ")
    else:
        out.append(char)
if len(text) in wrap_ends:
    out.append("'")
print("".join(out), end="")
PY
}

# All regex-only git write searches below use this copy. Raw COMMAND remains the source for
# quote-aware shell-control and effective path checks.
COMMAND_FOR_GIT_MATCH="$(sanitize_git_data_args "$COMMAND")"

# [2026-08-13][feat] third-party upstream への全writeを禁止し、forkを唯一のwrite先にする。
# 背景:
#   - ユーザー依頼意図: 全PJでupstreamへのpush/PRを全面禁止し、必要なら必ずforkで完結させる。
#   - 守るべき業務ルール: `git config --global github.user` のownerだけを書込先として許可し、
#     third-party upstreamはread-only remoteに限定する。push、gh pr create、REST PR作成を同じ境界で検査する。
#   - 他案不採用理由: remote名`upstream`だけを拒否する案は、外部remoteが`origin`のままのPJやURL直指定を
#     見逃すため不採用。ルール文書だけの禁止も実行時の誤送信を止められないため不採用。
UPSTREAM_GUARD_MSG='[hook:block-main-commit] third-party upstream への書込みは禁止です。\n\n対応手順:\n1. 自分のGitHubアカウントへfork\n2. forkをorigin、元リポジトリをread-only upstreamに設定\n3. pushとPRはfork内だけで実行\n\n全PJ共通ルールです。'
# [2026-08-13][fix] issue #1733: 未分類サブコマンド／alias は third-party write と別メッセージにする。
# 検出理由に subcommand 名は既にあるが、先頭文言が「upstream 書込み禁止」だと原因を取り違える。
# [2026-08-13][fix] issue #1746: shell substitution / opaque payload / piped cd の「own-repo 証明不能」も
# 同じ分類不能系へ振る。deny 自体は維持し、fork 誘導文言だけ外す（HEREDOC 静的緩和はしない）。
UNCLASSIFIED_GIT_GUARD_MSG='[hook:block-main-commit] Git 操作の書込先を安全に証明できないため停止しました。\n\nこれは third-party upstream への書込み検査とは別です。commit メッセージは git commit -F <file>、作業ディレクトリ変更は Shell の working_directory、パイプ付き複合は分割してください。read-only の既知サブコマンドだけを複合実行するか、書き込みが必要なら単発の明確な git/gh コマンドに分けてください。'
guard_reason=$(python3 "$SCRIPT_DIR/../lib/upstream-write-guard.py" --cwd "$CWD" --command "$COMMAND_FOR_GIT_MATCH" 2>&1) || {
  # [2026-10-06][fix] issue #3674: 「証明不能」系の拒否を third-party upstream 文言へ
  #   誤誘導しない。解析不能な複数行コマンド等は原因が upstream ではないため、
  #   upstream 文言は宛先 owner を解決できた上での境界違反（fork owner 不一致 /
  #   github.user 固定の操作 / URL rewrite 設定変更 / 同一コマンド内の宛先変更）だけに
  #   限定し、それ以外はすべて「書込先を安全に証明できない」分類不能文言で止める。
  case "$guard_reason" in
    *"is not fork owner"*|*"github.user is fixed"*|*"Git URL rewrite configuration"*|*"may be changed inside the same command"*)
      _emit_deny_with_telemetry "$UPSTREAM_GUARD_MSG\n\n検出理由: $guard_reason"
      ;;
    *"bare push would update main"*)
      _emit_deny_with_telemetry "$DENY_MSG\n\n検出理由: $guard_reason"
      ;;
    *)
      _emit_deny_with_telemetry "$UNCLASSIFIED_GIT_GUARD_MSG\n\n検出理由: $guard_reason"
      ;;
  esac
}

# [2026-09-22][fix] git worktree add の作成先が $HOME 直下なら fail-closed
# 背景:
#   - ユーザー依頼意図: /Users/shintaro/jtt-system-interview-document のように、
#     primary checkout の隣を $HOME 直下へ作る worktree を止める。
#   - 守るべき業務ルール: AI の編集は git worktree add が必須。作成先の親は
#     docs/worktree-operations.md が既に指定する親だけ。既存の primary checkout
#     （~/jtt-system、~/business/AGENT-HUB、その他の登録ルート）での通常 git 操作は止めない。
#     止めるのは、作成先の親が $HOME である git worktree add だけ。
#   - 他案不採用理由: 新しい hook ファイルを足す案は、git コマンドを既に検査する
#     本スクリプトが所有できるため不採用。$HOME 直下のディレクトリを存在だけで拒否する案は、
#     登録済み primary checkout まで止めるため不採用。
# 対応: worktree add の作成先を静的に解決し、親が $HOME、または親を証明できないときだけ
#       1行の理由で deny する。
home_child_worktree_add_reason() {
  COMMAND_TEXT="$COMMAND_FOR_GIT_MATCH" HOOK_CWD="$CWD" python3 - <<'PY'
import os
import re
import shlex

text = os.environ.get("COMMAND_TEXT", "")
hook_cwd = os.environ.get("HOOK_CWD", "") or "."
home = os.environ.get("HOME", "")
REASON = (
    "[hook:block-main-commit] git worktree add destination must not be a "
    "direct child of $HOME (forbidden example: "
    "/Users/shintaro/jtt-system-interview-document)"
)
UNRESOLVED = (
    "[hook:block-main-commit] git worktree add destination parent could not "
    "be proved, so a direct child of $HOME is refused"
)

WRAPPERS = {"command", "nice", "nohup", "time", "stdbuf", "builtin"}
GLOBAL_VALUE = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--super-prefix",
    "--exec-path",
    "--config-env",
}
GLOBAL_FLAGS = {
    "-p",
    "--paginate",
    "-P",
    "--no-pager",
    "--no-replace-objects",
    "--bare",
    "--literal-pathspecs",
    "--glob-pathspecs",
    "--noglob-pathspecs",
    "--icase-pathspecs",
}
ADD_VALUE = {"-b", "-B", "--reason"}
ADD_FLAGS = {
    "-f",
    "--force",
    "--no-force",
    "--orphan",
    "--no-orphan",
    "-d",
    "--detach",
    "--no-detach",
    "--checkout",
    "--no-checkout",
    "--lock",
    "--no-lock",
    "--no-reason",
    "-q",
    "--quiet",
    "--no-quiet",
    "--track",
    "--no-track",
    "--guess-remote",
    "--no-guess-remote",
    "--relative-paths",
    "--no-relative-paths",
    "-h",
    "--help",
}


def static_expand(token, home_dir):
    if token is None or "$(" in token or "`" in token:
        return None
    expanded = re.sub(r"\$\{HOME\}", home_dir, token)
    expanded = re.sub(r"\$HOME(?![A-Za-z0-9_])", home_dir, expanded)
    if "$" in expanded or any(ch in expanded for ch in "*?[]{}"):
        return None
    if expanded.startswith("~"):
        expanded = os.path.expanduser(expanded)
        if expanded.startswith("~"):
            return None
    return expanded


def split_segments(command):
    parts = []
    buf = []
    quote = None
    escaped = False
    i = 0
    while i < len(command):
        ch = command[i]
        if escaped:
            buf.append(ch)
            escaped = False
            i += 1
            continue
        if ch == "\\" and quote != "'":
            buf.append(ch)
            escaped = True
            i += 1
            continue
        if quote:
            if ch == quote:
                quote = None
            buf.append(ch)
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "&" and i + 1 < len(command) and command[i + 1] == "&":
            parts.append(("".join(buf), "&&"))
            buf = []
            i += 2
            continue
        if ch == "|" and i + 1 < len(command) and command[i + 1] == "|":
            parts.append(("".join(buf), "||"))
            buf = []
            i += 2
            continue
        if ch in "|\n;":
            parts.append(("".join(buf), ch))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if quote is not None or escaped:
        return None
    parts.append(("".join(buf), None))
    return parts


def is_redirect(token):
    return bool(re.match(r"^[0-9]*[<>]&?[0-9]*$|^[<>]", token))


def skip_wrappers(tokens):
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if "=" in tok and not tok.startswith("-") and not tok.startswith("/") and not tok.startswith("."):
            key = tok.split("=", 1)[0]
            if key in {"GIT_DIR", "GIT_WORK_TREE"} or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                return None
            i += 1
            continue
        if tok == "timeout" and i + 1 < len(tokens) and re.match(r"^[0-9]+(\.[0-9]+)?$", tokens[i + 1]):
            i += 2
            continue
        if tok == "env":
            if i + 1 < len(tokens) and tokens[i + 1].startswith("-"):
                return None
            i += 1
            continue
        if tok in WRAPPERS:
            i += 1
            continue
        break
    return i


def parse_add(tokens, start, base):
    i = start
    path = None
    saw_help = False
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            i += 1
            if path is None and i < len(tokens):
                path = tokens[i]
            break
        if tok in {"-h", "--help"}:
            saw_help = True
            i += 1
            continue
        if tok in ADD_VALUE:
            if i + 1 >= len(tokens):
                return "unresolved"
            i += 2
            continue
        if tok.startswith("--reason="):
            i += 1
            continue
        if tok.startswith("-b") and len(tok) > 2 and not tok.startswith("--"):
            i += 1
            continue
        if tok.startswith("-B") and len(tok) > 2 and not tok.startswith("--"):
            i += 1
            continue
        if tok in ADD_FLAGS or tok in GLOBAL_FLAGS:
            i += 1
            continue
        if tok.startswith("-"):
            return "unresolved"
        if is_redirect(tok):
            i += 1
            continue
        if path is None:
            path = tok
            i += 1
            continue
        i += 1
    if saw_help and path is None:
        return "allow"
    if path is None:
        return "unresolved"
    return destination_parent(path, base)


def destination_parent(path_token, base):
    if not home:
        return "unresolved"
    expanded = static_expand(path_token, home)
    if expanded is None:
        return "unresolved"
    if not os.path.isabs(expanded):
        if base is None:
            return "unresolved"
        base_expanded = static_expand(base, home)
        if base_expanded is None:
            return "unresolved"
        if not os.path.isabs(base_expanded):
            return "unresolved"
        expanded = os.path.join(base_expanded, expanded)
    destination = os.path.normpath(expanded)
    parent = os.path.realpath(os.path.dirname(destination))
    if parent == os.path.realpath(home):
        return "deny"
    return "allow"


def inspect_git(tokens, base):
    start = skip_wrappers(tokens)
    if start is None or start >= len(tokens):
        return None
    exe = tokens[start]
    if not (exe == "git" or exe.endswith("/git")):
        if exe in {"bash", "sh", "zsh", "eval"}:
            return inspect_shell(tokens[start:], base)
        return None
    i = start + 1
    c_base = None
    c_unresolved = False
    while i < len(tokens) and tokens[i].startswith("-"):
        tok = tokens[i]
        if tok == "--":
            i += 1
            break
        attached_c = None
        if tok.startswith("-C") and len(tok) > 2:
            attached_c = tok[2:]
        elif tok.startswith("--git-dir="):
            attached_c = tok.split("=", 1)[1]
        if attached_c is not None:
            resolved = static_expand(attached_c, home)
            if resolved is None:
                c_unresolved = True
            else:
                if not os.path.isabs(resolved):
                    if base is None:
                        c_unresolved = True
                    else:
                        resolved = os.path.normpath(os.path.join(base, resolved))
                c_base = resolved
            i += 1
            continue
        if tok in GLOBAL_VALUE:
            if i + 1 >= len(tokens):
                return "unresolved"
            if tok == "-C":
                resolved = static_expand(tokens[i + 1], home)
                if resolved is None:
                    c_unresolved = True
                else:
                    if not os.path.isabs(resolved):
                        if base is None:
                            c_unresolved = True
                        else:
                            resolved = os.path.normpath(os.path.join(base, resolved))
                    c_base = resolved
            i += 2
            continue
        if tok in GLOBAL_FLAGS or tok.startswith("--no-") or tok.startswith("--"):
            if tok not in GLOBAL_FLAGS and "=" not in tok and tok not in {"--bare", "--no-pager", "--paginate"}:
                # unknown long option: fail closed only if this is worktree add
                rest = tokens[i + 1 :]
                if "worktree" in rest and "add" in rest:
                    return "unresolved"
            i += 1
            continue
        return "unresolved"
    if i >= len(tokens) or tokens[i] != "worktree":
        return None
    if i + 1 >= len(tokens) or tokens[i + 1] != "add":
        return None
    use_base = c_base if c_base is not None else base
    if c_unresolved:
        # An absolute destination does not depend on -C. A relative one does.
        probe = parse_add(tokens, i + 2, None)
        if probe == "allow":
            return "allow"
        if probe == "deny":
            return "deny"
        return "unresolved"
    return parse_add(tokens, i + 2, use_base)


def inspect_shell(tokens, base):
    exe = tokens[0]
    if exe == "eval":
        if len(tokens) < 2:
            return None
        body = tokens[1]
        if not static_expand(body, home) and ("$(" in body or "`" in body or "$" in body.replace("$HOME", "").replace("${HOME}", "")):
            if "worktree" in body and re.search(r"\badd\b", body):
                return "unresolved"
        return scan_command(body, base)
    if exe in {"bash", "sh", "zsh"}:
        if "-c" not in tokens:
            return None
        idx = tokens.index("-c")
        if idx + 1 >= len(tokens):
            return "unresolved"
        body = tokens[idx + 1]
        if "$(" in body or "`" in body:
            if "worktree" in body:
                return "unresolved"
        return scan_command(body, base)
    return None


def simple_cd(tokens):
    start = skip_wrappers(tokens)
    if start is None or start >= len(tokens) or tokens[start] != "cd":
        return None
    args = [tok for tok in tokens[start + 1 :] if not is_redirect(tok)]
    if not args:
        return home or None
    if len(args) != 1 or args[0] in {"-", "--"}:
        return "unresolved"
    expanded = static_expand(args[0], home)
    if expanded is None:
        return "unresolved"
    return expanded


def scan_command(command, initial_base):
    if "worktree" not in command:
        return None
    parts = split_segments(command)
    if parts is None:
        if re.search(r"\bgit\b", command) and re.search(r"\bworktree\b", command) and re.search(r"\badd\b", command):
            return "unresolved"
        return None
    base = initial_base
    base_trusted = True
    for segment, sep_after in parts:
        segment = segment.strip()
        if not segment:
            if sep_after in {"|", "||"}:
                base_trusted = False
            continue
        try:
            tokens = shlex.split(segment, posix=True)
        except ValueError:
            if "worktree" in segment:
                return "unresolved"
            continue
        cd_target = simple_cd(tokens)
        git_result = inspect_git(tokens, base if base_trusted else None)
        if git_result in {"deny", "unresolved"}:
            return git_result
        if cd_target == "unresolved":
            base_trusted = False
        elif isinstance(cd_target, str) and sep_after in {"&&", ";", "\n"}:
            if not os.path.isabs(cd_target):
                if not base_trusted or base is None:
                    base_trusted = False
                else:
                    base = os.path.normpath(os.path.join(base, cd_target))
                    base_trusted = True
            else:
                base = os.path.normpath(cd_target)
                base_trusted = True
        elif sep_after in {"|", "||"}:
            base_trusted = False
        elif cd_target == "unresolved" or (cd_target and sep_after not in {"&&", ";", "\n", None}):
            base_trusted = False
    return None


result = scan_command(text, os.path.abspath(hook_cwd) if hook_cwd else None)
if result == "deny":
    print(REASON)
elif result == "unresolved":
    print(UNRESOLVED)
PY
}

if echo "$COMMAND_FOR_GIT_MATCH" | grep -q 'worktree'; then
  home_child_worktree_reason="$(home_child_worktree_add_reason)"
  if [ -n "${home_child_worktree_reason:-}" ]; then
    _emit_deny_with_telemetry "$home_child_worktree_reason"
  fi
fi

is_allowed_main_direct_path() {
  # 2026-07-01: AI hook 経由の main direct allowlist は廃止。
  # 互換テスト用に関数名は残すが、どの path も許可しない。
  return 1
}

# [2026-05-30][fix] issue #210 / cafe48 codex review follow-up
# 背景:
#   ユーザー依頼意図: `git -C <別repo> push origin main` のように実効ディレクトリを変える
#     グローバルオプション付き push/commit を、hook 実行 cwd ($CWD) の branch/差分で判定すると、
#     「$CWD が main かつ軽量変更」のとき別 repo の main 直 push を軽量バイパスで許可してしまう
#     fail-open が残っていた（#213 で git_command_query=実効 cwd 解決を削除した際の取りこぼし）。
#   守るべき業務ルール: main 直 push/commit のブロックは確実(fail-closed)であること。
#   他案不採用理由:
#     1) -C <path> を抽出し実効 cwd を完全復元する案: 複数 -C の相対累積や --git-dir/--work-tree の
#        組合せまで正確に追うのは複雑で、#213 が regex 方式へ寄せた設計に逆行する。
#     2) 何もしない案: 別 repo の main 直 push を $CWD=main・軽量時に通すため main 保護目的を満たさない。
#     3) -C/--git-dir/--work-tree のみ検知（PR #229 初版）: PR #229 codex レビューで指摘の通り
#        `GIT_DIR=` / `GIT_WORK_TREE=` env 経由と `cd /other && git push` の複合コマンドが
#        残存 fail-open になるため不採用（v3.5.7 で同時対応）。
#   対応: 実効ディレクトリを変える経路(-C / --git-dir / --work-tree / GIT_DIR= / GIT_WORK_TREE= /
#     cd <path> && git ...)が push/commit に付く場合は $CWD ベースの軽量バイパスを信頼せず、
#     main 向けは安全側で deny する(fail-closed)。-C なしの通常 cwd 上の Markdown 軽量直 push は
#     従来どおり許可され、false positive を広げない。
command_targets_other_dir() {
  # -C <path> / --git-dir / --work-tree
  # ただし `-C .` / `-C ./` は no-op（current dir）のため除外する。
  # path 部分を抽出して `.` または `./` でないことを確認する。
  local c_paths c_path
  c_paths=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE '(^|[[:space:]])-C[[:space:]]+[^[:space:]]+' || true)
  if [ -n "$c_paths" ]; then
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      # 最後のフィールド = path（先頭の空白と -C を除去）
      c_path=$(echo "$match" | awk '{print $NF}')
      # [2026-10-09][fix] issue #2240: 引用符付きパスの no-op 判定用に外側の1組だけ剥がす
      case "$c_path" in
        \"*\") c_path="${c_path#\"}"; c_path="${c_path%\"}" ;;
        \'*\') c_path="${c_path#\'}"; c_path="${c_path%\'}" ;;
      esac
      case "$c_path" in
        "."|"./") ;;  # no-op
        *) return 0 ;;
      esac
    done <<< "$c_paths"
  fi
  if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(--git-dir(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--work-tree(=[^[:space:]]+|[[:space:]]+[^[:space:]]+))'; then
    return 0
  fi
  # GIT_DIR= / GIT_WORK_TREE= / GIT_NAMESPACE= 環境変数 prefix
  if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]]|[;&|])(GIT_DIR|GIT_WORK_TREE|GIT_NAMESPACE)='; then
    return 0
  fi
  # cd <path> && git ... / cd <path> ; git ... (複合コマンドで実効 cwd を変える)
  # `cd .` / `cd ./` は no-op のため除外する。
  # [2026-10-09][fix] issue #2240:
  #   - cd の引数は非引用/単一引用/二重引用の1トークン（空白を含む引用パスも拾う）。
  #   - subshell 先頭の `( cd <main> && git commit )` も拾うため境界に `(` を足す。
  #   - `cd <path>` 改行 `git ...` の改行区切りも後続に効くため、行末を終端として受理する。
  local cd_paths cd_path cd_unquoted
  cd_paths=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|()]+)' || true)
  if [ -n "$cd_paths" ]; then
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      # 先頭の区切り文字・空白・cd を取り除いて引数だけにする（引用符は保持）
      cd_path=$(printf '%s' "$match" | sed -E 's/^[\;&|(]?[[:space:]]*cd[[:space:]]+//')
      cd_unquoted="$cd_path"
      case "$cd_unquoted" in
        \"*\") cd_unquoted="${cd_unquoted#\"}"; cd_unquoted="${cd_unquoted%\"}" ;;
        \'*\') cd_unquoted="${cd_unquoted#\'}"; cd_unquoted="${cd_unquoted%\'}" ;;
      esac
      case "$cd_unquoted" in
        "."|"./") ;;  # no-op
        *)
          # cd の後に && / ; / 行末(改行区切り)があることを確認（raw token で再検索）
          if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "cd[[:space:]]+$(printf '%s' "$cd_path" | sed 's/[[\.*^$/]/\\&/g')[[:space:]]*([;&]|$)"; then
            return 0
          fi
          ;;
      esac
    done <<< "$cd_paths"
  fi
  return 1
}

# [2026-06-14][feat] 実効ターゲットディレクトリ(先頭の単一 cd 先)のブランチを解決する。-C は不採用=deny。
# 背景:
#   依頼意図: Claude Code 等のハーネスは Bash の cwd を毎回プロジェクト直下(main)に戻すため、
#     worktree への操作は `cd <worktree> && git commit/push` の形になる。$CWD(main) の枝で判定すると
#     worktree(feature) への正当なコミット・PR push まで fail-closed で弾かれ、worktree 開発が成立しない。
#   守るべき業務ルール: 解決対象は「コマンド先頭の単一 cd <path> && ...」だけ（cd は後続コマンドの cwd に
#     効くため commit/push の実効ディレクトリになる）。GIT_DIR/GIT_WORK_TREE env・--git-dir/--work-tree/
#     --namespace・-C・複数 cd・先頭以外の cd が含まれる場合は解決不能(空)を返し、従来どおり fail-closed にする。
#   他案不採用理由:
#     1) -C <path> を解決に使う案: -C はその git 1 回にしか効かず、`git -C <wt> status && git commit` のように
#        後続 commit が main で動く形を誤許可するため不採用（-C は解決根拠にしない＝従来 deny のまま）。
#     2) 複数 cd の相対累積・env トリックまで追う案: 複雑で誤許可リスクが高い。安全に解決できる
#        「先頭単一 cd」だけを許可し、それ以外は安全側(空)に倒す。
# 実効ターゲットディレクトリ(先頭の単一 cd 先)を解決して絶対パスを stdout に返す。解決不能なら空。
# [2026-06-15][fix] dir 解決を effective_target_branch から切り出して関数化（bare push の宛先判定で
#   has_unsafe_push が同じ dir を再利用するため）。ガード条件は従来と同一（変更なし）。
effective_target_dir() {
  # 実体を差し替える env / オプション / -C が含まれるものは解決不能（fail-closed 用に空を返す）。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]]|[;&|])(GIT_DIR|GIT_WORK_TREE|GIT_NAMESPACE)=' && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(--git-dir|--work-tree|--namespace)([=[:space:]])' && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])-C([[:space:]]|$)' && return 0
  # eval / exec / `<shell> -c` は cd の効果範囲が静的に読めない → 解決不能（fail-closed）。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(eval|exec)([[:space:]]|$)' && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(sh|bash|zsh|dash|ksh)[[:space:]]+-[A-Za-z]*c([[:space:]]|$)' && return 0
  # コマンド位置(^ / ; & | 直後・サブシェル ( 直後)の cd を数える。複数あれば実効 cwd が曖昧 → 解決不能。
  #   サブシェル `( cd /main && git commit )` の隠れた cd も ( を境界に含めることで検出する。
  # [2026-10-09][fix] issue #2240: cd の引数は非引用/単一引用/二重引用の1トークン
  #   （空白を含む引用パスも拾う）。後続の区切りは && / ; / 行末(改行区切り)を受理する。
  local cd_arg='"([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|()]+'
  local cds dir
  cds=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE "(^|[;&|(])[[:space:]]*cd[[:space:]]+($cd_arg)" || true)
  [ "$(printf '%s\n' "$cds" | grep -c .)" -ne 1 ] && return 0
  # その単一 cd が「先頭」かつ「&& / ; / 改行で後続に効く」形であること（背景 & / パイプ | は対象外）。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "^[[:space:]]*cd[[:space:]]+($cd_arg)[[:space:]]*(&&|;|$)" || return 0
  # [2026-06-16][fix] COMMAND が複数行(heredoc / 改行入りコミットメッセージ等)のとき、
  #   sed が行単位で処理し非マッチ行(2 行目以降のメッセージ本文)を素通しするため dir がゴミ文字列化し、
  #   git -C "$dir" が失敗 → 正当な worktree commit/push が誤 deny されていた。cd は先頭行(上の L427 で
  #   先頭 + &&/; を保証済)にあるため、1 行目だけから抽出する（複数行は安全に L1 のみを見る）。
  dir=$(printf '%s' "$COMMAND" | sed -nE "1s/^[[:space:]]*cd[[:space:]]+($cd_arg).*/\\1/p")
  # [2026-10-09][fix] issue #2240: 引用符を剥がしてから正規化する。
  #   二重引用内の $ ` \ は実行時展開/エスケープを含みうるため解決不能(空)に倒す。
  #   引用符内では ~ 展開も起きないため、引用符付きの ~ は literal の相対パスとして扱う。
  local dir_quoted=0
  case "$dir" in
    \"*\")
      dir_quoted=1
      dir="${dir#\"}"
      dir="${dir%\"}"
      case "$dir" in
        *'$'*|*'`'*|*'\'*) return 0 ;;
      esac
      ;;
    \'*\')
      dir_quoted=1
      dir="${dir#\'}"
      dir="${dir%\'}"
      ;;
  esac
  # ~ 展開 / 相対パスは $CWD(JSON の cwd) 基準で正規化（git -C が hook プロセスの cwd で解決するのを防ぐ）。
  case "$dir" in
    ""|"."|"./") return 0 ;;
  esac
  if [ "$dir_quoted" = "0" ]; then
    case "$dir" in
      "~") dir="$HOME" ;;
      "~/"*) dir="${HOME}/${dir#\~/}" ;;
    esac
  fi
  case "$dir" in
    /*) ;;
    *) dir="$CWD/$dir" ;;
  esac
  printf '%s' "$dir"
}

effective_target_branch() {
  local dir
  dir="$(effective_target_dir)"
  [ -z "$dir" ] && return 0
  git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# [2026-07-09][fix]
# 背景:
#   依頼意図: AGENT-HUB の専用 worktree 上で正当な `git -C <feature-worktree> commit` が
#     block-main-commit に誤ブロックされ、正規の branch + PR フローを閉じられなかった。
#   守るべき業務ルール: main 直 commit / push は引き続き fail-closed で止める。一方で、実効対象が
#     非 main branch だと確認できる単発 `git -C <dir> commit/push` は本番 main に影響しないため許可する。
#   他案不採用理由:
#     1) `-C` を全面許可する案は、`git -C <wt> status && git commit` の後続 commit が main で動く形を
#        誤許可するため不採用。
#     2) 複合 shell 構文まで静的解析する案は誤許可リスクが高いため不採用。
#     3) 従来どおり全部 deny する案は、AGENT-HUB の標準 worktree 運用を阻害するため不採用。
# 対応: shell 制御演算子を含まない単発 git コマンドだけ `-C` の対象 dir を解決し、非 main branch かつ
#       unsafe push でない場合だけ早期許可する。env / git-dir / namespace trick は従来どおり fail-closed。
# [2026-08-02][fix] Wave B / #1258: 引用内の `-C` を git global option と数えない。
# 背景:
#   - ユーザー依頼意図: `git -C <feature> commit -m '... -C ...'` のようにメッセージへ `-C` と
#     書いただけで単発 feature commit が deny され、文書・回帰テストが書けない。
#   - 守るべき業務ルール: 引用外の複数 `-C` は従来どおり解決不能。引用済み本文の `-C` はデータ。
#   - 他案不採用理由: メッセージから `-C` 文字を禁止する案は説明文を歪める。複合への -C 対称化はしない。
# 対応: quote-aware に引用外の `-C <path>` をちょうど1つだけ抽出し、それを target dir にする。
single_unquoted_git_c_path() {
  COMMAND_TEXT="$1" python3 - <<'PY' 2>/dev/null || true
import os

text = os.environ.get("COMMAND_TEXT", "")
quote = None
escaped = False
paths = []
i = 0
while i < len(text):
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if ch == "\\" and quote != "'":
        escaped = True
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        i += 1
        continue
    if ch in ("'", '"'):
        quote = ch
        i += 1
        continue
    if ch == "-" and i + 1 < len(text) and text[i + 1] == "C":
        prev = text[i - 1] if i > 0 else " "
        if prev.isspace() or i == 0:
            j = i + 2
            while j < len(text) and text[j] in " \t":
                j += 1
            if j < len(text) and text[j] in "'\"":
                # [2026-10-09][fix] issue #2240: 引用符付き -C パスを解決対象にする。
                #   内容は閉じる引用符の内側。二重引用で $ ` \ を含む値は実行時展開を
                #   含みうるため、パスとして採用せず解決不能(空)側へ倒す。
                #   引用符内では ~ も展開されない（literal の ~ ディレクトリ名を指す）ため、
                #   resolve_git_c_dir の ~ 展開と乖離する ~ 先頭パスも解決不能へ倒す。
                q = text[j]
                k = j + 1
                while k < len(text) and text[k] != q:
                    k += 1
                if k < len(text):
                    inner = text[j + 1:k]
                    if inner and not inner.startswith("~") \
                            and not (q == '"' and any(c in inner for c in "$`\\")):
                        paths.append(inner)
                    i = k + 1
                    continue
            if j < len(text) and text[j] not in " \t\n;'\"|&()":
                start = j
                while j < len(text) and text[j] not in " \t\n;'\"|&()":
                    j += 1
                paths.append(text[start:j])
                i = j
                continue
    i += 1

if quote is not None or escaped or len(paths) != 1:
    raise SystemExit(0)
print(paths[0], end="")
PY
}

# [2026-08-13][fix] issue #1672: 同一 -C 先への `git -C <dir> add && git -C <dir> commit` 複合を許可
# 背景:
#   - ユーザー依頼意図: feature worktree 内の正当な `git -C … add && git -C … commit` が
#     single_git_c_target_dir の shell-control 判定（&&）と複数 -C 検出で誤 deny されていた。
#   - 守るべき業務ルール: 引用外の -C がすべて同一 path で非 main なら compound でも early allow。
#     パイプ・subshell・env chdir・main 宛 push / commit は従来どおり fail-closed。
#   - 他案不採用理由: has_unquoted_shell_control から & 単体を外す案は subshell 検知を弱めるため不採用。
# 対応: && / ; のみ許容する compound risk scanner と、全 -C path 一致時の target dir 解決を追加。
consistent_unquoted_git_c_path() {
  COMMAND_TEXT="$1" python3 - <<'PY' 2>/dev/null || true
import os

text = os.environ.get("COMMAND_TEXT", "")
quote = None
escaped = False
paths = []
i = 0
while i < len(text):
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if ch == "\\" and quote != "'":
        escaped = True
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        i += 1
        continue
    if ch in ("'", '"'):
        quote = ch
        i += 1
        continue
    if ch == "-" and i + 1 < len(text) and text[i + 1] == "C":
        prev = text[i - 1] if i > 0 else " "
        if prev.isspace() or i == 0:
            j = i + 2
            while j < len(text) and text[j] in " \t":
                j += 1
            if j < len(text) and text[j] in "'\"":
                # [2026-10-09][fix] issue #2240: 引用符付き -C パスを解決対象にする。
                #   内容は閉じる引用符の内側。二重引用で $ ` \ を含む値は実行時展開を
                #   含みうるため、パスとして採用せず解決不能(空)側へ倒す。
                #   引用符内では ~ も展開されない（literal の ~ ディレクトリ名を指す）ため、
                #   resolve_git_c_dir の ~ 展開と乖離する ~ 先頭パスも解決不能へ倒す。
                q = text[j]
                k = j + 1
                while k < len(text) and text[k] != q:
                    k += 1
                if k < len(text):
                    inner = text[j + 1:k]
                    if inner and not inner.startswith("~") \
                            and not (q == '"' and any(c in inner for c in "$`\\")):
                        paths.append(inner)
                    i = k + 1
                    continue
            if j < len(text) and text[j] not in " \t\n;'\"|&()":
                start = j
                while j < len(text) and text[j] not in " \t\n;'\"|&()":
                    j += 1
                paths.append(text[start:j])
                i = j
                continue
    i += 1

if quote is not None or escaped or not paths or len(set(paths)) != 1:
    raise SystemExit(0)
print(paths[0], end="")
PY
}

has_unquoted_compound_risk() {
  local scanner_rc
  if COMMAND_TEXT="$1" python3 - <<'PY'
import os
import sys

text = os.environ.get("COMMAND_TEXT", "")
quote = None
escaped = False
i = 0
while i < len(text):
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if ch == "\\" and quote != "'":
        escaped = True
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        elif ch == "`" or (ch == "$" and i + 1 < len(text) and text[i + 1] == "("):
            raise SystemExit(0)
        i += 1
        continue
    if ch in ("'", '"'):
        quote = ch
    elif ch == "&" and i + 1 < len(text) and text[i + 1] == "&":
        i += 2
        continue
    elif ch == ";":
        i += 1
        continue
    elif ch in "<>":
        direction = ch
        while i + 1 < len(text) and text[i + 1] == direction:
            i += 1
        if i + 1 < len(text) and text[i + 1] == "&":
            i += 1
            while i + 1 < len(text) and (text[i + 1].isdigit() or text[i + 1] == "-"):
                i += 1
    elif ch in "|()" or ch == "`":
        raise SystemExit(0)
    i += 1

raise SystemExit(0 if quote is not None or escaped else 1)
PY
  then
    return 0
  else
    scanner_rc=$?
    [ "$scanner_rc" -eq 1 ] && return 1
    return 0
  fi
}

resolve_git_c_dir() {
  local dir="$1"
  case "$dir" in
    ""|"."|"./") printf '%s' "" ;;
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${dir#\~/}" ;;
    /*) printf '%s' "$dir" ;;
    *) printf '%s' "$CWD/$dir" ;;
  esac
}

consistent_git_c_target_dir() {
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]]|[;&|])(GIT_DIR|GIT_WORK_TREE|GIT_NAMESPACE)=' && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(--git-dir|--work-tree|--namespace)([=[:space:]])' && return 0
  command_uses_env_chdir && return 0
  has_unquoted_compound_risk "$COMMAND" && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+(commit|push|add)" || return 0

  local dir
  dir="$(consistent_unquoted_git_c_path "$COMMAND")"
  [ -n "$dir" ] || return 0
  compound_git_c_covers_all_writes "$COMMAND" "$dir" || return 0
  dir="$(resolve_git_c_dir "$dir")"
  [ -n "$dir" ] || return 0
  printf '%s' "$dir"
}

compound_git_c_covers_all_writes() {
  COMMAND_TEXT="$1" EXPECTED_C="$2" python3 - <<'PY' 2>/dev/null || return 1
import os
import re

text = os.environ.get("COMMAND_TEXT", "")
expected = os.environ.get("EXPECTED_C", "")

def split_segments(value):
    quote = None
    escaped = False
    segments = []
    current = []
    i = 0
    while i < len(value):
        ch = value[i]
        if escaped:
            escaped = False
            current.append(ch)
            i += 1
            continue
        if ch == "\\" and quote != "'":
            escaped = True
            current.append(ch)
            i += 1
            continue
        if quote == "'":
            current.append(ch)
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            current.append(ch)
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            current.append(ch)
            i += 1
            continue
        if ch == "&" and i + 1 < len(value) and value[i + 1] == "&":
            segments.append("".join(current))
            current = []
            i += 2
            continue
        if ch == ";":
            segments.append("".join(current))
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    segments.append("".join(current))
    return [segment.strip() for segment in segments if segment.strip()]

def extract_c_path(segment):
    quote = None
    escaped = False
    i = 0
    while i < len(segment):
        ch = segment[i]
        if escaped:
            escaped = False
            i += 1
            continue
        if ch == "\\" and quote != "'":
            escaped = True
            i += 1
            continue
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        if ch == "-" and i + 1 < len(segment) and segment[i + 1] == "C":
            prev = segment[i - 1] if i > 0 else " "
            if prev.isspace() or i == 0:
                j = i + 2
                while j < len(segment) and segment[j] in " \t":
                    j += 1
                if j < len(segment) and segment[j] in "'\"":
                    # [2026-10-09][fix] issue #2240: 引用符付き -C パス（空白含み）を
                    #   解決対象にする。二重引用内の $ ` \ は展開を含みうるため、
                    #   生トークンを返して「別ターゲット=不一致=解決不能」側へ倒す。
                    q = segment[j]
                    k = j + 1
                    while k < len(segment) and segment[k] != q:
                        k += 1
                    if k < len(segment):
                        inner = segment[j + 1:k]
                        if q == '"' and any(c in inner for c in "$`\\"):
                            return segment[j:k + 1]
                        return inner
                    return None
                if j < len(segment) and segment[j] not in " \t\n;'\"|&()":
                    start = j
                    while j < len(segment) and segment[j] not in " \t\n;'\"|&()":
                        j += 1
                    return segment[start:j]
        i += 1
    return None

write_re = re.compile(r"\bgit\b.*\b(commit|push|add)\b")
for segment in split_segments(text):
    if not write_re.search(segment):
        continue
    c_path = extract_c_path(segment)
    if c_path != expected:
        raise SystemExit(1)
raise SystemExit(0)
PY
}

single_git_c_target_dir() {
  # 単発 `git -C <dir> commit/push` だけを解決する。
  # `git -C <dir> status && git commit` のような後続 git へ -C が効かない形は従来どおり解決しない。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]]|[;&|])(GIT_DIR|GIT_WORK_TREE|GIT_NAMESPACE)=' && return 0
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '(^|[[:space:]])(--git-dir|--work-tree|--namespace)([=[:space:]])' && return 0
  has_unquoted_shell_control "$COMMAND" && return 0
  # shell controlを除外済みの単発コマンドは、git本体とsubcommandだけを軽量に確認する。
  # ここで巨大な GIT_CMD 正規表現を再利用すると、引用本文を空白化した長い -C pathで
  # EREのバックトラックが不安定になり、正当なfeature commit/pushを誤denyするため分離する。
  # [2026-08-02][fix] env / VAR=value prefix 付きの単発 git -C を解決対象に含める（issue #1344）。
  # 背景:
  #   - ユーザー依頼意図: `env FOO=bar git -C <feature> commit` / `FOO=bar git -C <feature> commit`
  #     が本軽量正規表現に一致せず未解決 → fail-closed で正当な feature commit/push まで
  #     誤 deny されていた（PR #1343 codex-review が検出・再現ドライバで実測）。
  #   - 守るべき業務ルール: GIT_DIR / GIT_WORK_TREE / GIT_NAMESPACE の assignment は本関数
  #     冒頭のガードが先に未解決へ倒す（実効 dir を -C 以外で動かす形は従来どおり保守的）。
  #     値に空白・引用を含む assignment は本パターンに一致せず未解決のまま（安全側）。
  #   - 他案不採用理由: GIT_CMD 全体の再利用は上記バックトラック不安定のため不採用（既存判断）。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '^[[:space:]]*(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(env[[:space:]]+)?(command[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|push)([[:space:]]|$)' || return 0

  local dir
  dir="$(single_unquoted_git_c_path "$COMMAND")"
  dir="$(resolve_git_c_dir "$dir")"
  [ -n "$dir" ] || return 0
  printf '%s' "$dir"
}

# [2026-10-09][fix] issue #2240: 「書込先を解決してから判定」するための第4 resolver。
# 背景:
#   - 依頼意図: `git -C <repo> status && git commit` / `git -C <repo> log | git commit`
#     のように -C が read 系だけに付く複合コマンドでは、書込(commit/push/add)が dir 差し替えを
#     持たず session cwd 宛てと証明できる。これを解決不能として一律拒否すると、feature 上の
#     正当な確定まで止まる。
#   - 守るべき業務ルール: 書込セグメントに -C/--git-dir/--work-tree/--namespace/GIT_*=
#     や cd が残る形、subshell・command substitution・eval/exec/シェル -c・wrapper を
#     含む形は静的に追えないため解決不能(空)に倒し、従来どおり fail-closed で拒否する。
#   - 他案不採用理由:
#     1) 複合形を全部解決不能=deny にする案: read 系 -C と cwd 宛て書込の混在という正当な
#        形まで止まり、issue の「通常確定は許可」条件に反するため不採用。
#     2) セグメントごとの実効 dir を完全復元する案: 相対 cd の累積や条件分岐まで追うのは
#        複雑で誤許可リスクが高いため不採用。「書込に差し替えが無い」の一点だけを証明する。
# 対応: 引用を追跡してセグメント分割し、全 write セグメントが dir 差し替えを持たず、
#   コマンド位置に cd / eval 系 / subshell / 展開が無いときだけ $CWD を返す。
session_cwd_target_dir() {
  if COMMAND_TEXT="$COMMAND" python3 - <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

text = os.environ.get("COMMAND_TEXT", "")

# 引用を追跡しながら && ; | 単体 & 改行 でセグメントに分割する。
# 引用外の ( ) ` $ と heredoc は静的に追えないため即 fail-closed。
segments = []
buf = []
quote = None
escaped = False
fail = False
i = 0

def flush():
    seg = "".join(buf).strip()
    if seg:
        segments.append(seg)

while i < len(text):
    ch = text[i]
    if escaped:
        escaped = False
        i += 1
        continue
    if ch == "\\" and quote != "'":
        escaped = True
        i += 1
        continue
    if quote == "'":
        if ch == "'":
            quote = None
        i += 1
        continue
    if quote == '"':
        if ch == '"':
            quote = None
        elif ch == "`" or (ch == "$" and i + 1 < len(text) and text[i + 1] == "("):
            fail = True
        i += 1
        continue
    if ch in ("'", '"'):
        quote = ch
        i += 1
        continue
    if ch == "&" and i + 1 < len(text) and text[i + 1] == "&":
        flush()
        buf = []
        i += 2
        continue
    if ch in ";&|\n":
        flush()
        buf = []
        i += 1
        continue
    if ch in "()":
        fail = True
        i += 1
        continue
    if ch == "`" or ch == "$":
        # コマンド置換・変数展開の結果は静的に読めない（-C 注入もありうる）
        fail = True
        i += 1
        continue
    if ch == "<" and i + 1 < len(text) and text[i + 1] == "<":
        # heredoc 本体はコマンド列に見えるため解析しない
        fail = True
        i += 1
        continue
    if ch in "<>":
        # リダイレクトは書込先ディレクトリに無関係。演算子/fd 複写部分だけ読み飛ばす。
        direction = ch
        while i + 1 < len(text) and text[i + 1] == direction:
            i += 1
        if i + 1 < len(text) and text[i + 1] == "&":
            i += 1
            while i + 1 < len(text) and (text[i + 1].isdigit() or text[i + 1] == "-"):
                i += 1
        i += 1
        continue
    buf.append(ch)
    i += 1
flush()

if fail or quote is not None or escaped:
    sys.exit(1)

WRITE_WORDS = {"commit", "push", "add"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"command", "builtin", "nice", "nohup", "time", "stdbuf", "xargs"}
SHELLS = {"eval", "exec", "sh", "bash", "zsh", "dash", "ksh"}

for seg in segments:
    try:
        toks = shlex.split(seg)
    except ValueError:
        sys.exit(1)
    if not toks:
        continue
    # 先頭の VAR= 代入と env オプションを剥がしてコマンド名を取る
    j = 0
    while j < len(toks) and ASSIGN_RE.match(toks[j]):
        j += 1
    if j < len(toks) and toks[j] == "env":
        j += 1
        while j < len(toks) and (toks[j].startswith("-") or ASSIGN_RE.match(toks[j])):
            j += 1
    if j >= len(toks):
        continue
    cmd = toks[j]
    if cmd == "cd" or cmd in SHELLS or cmd in WRAPPERS:
        # cd / eval / exec / <shell> -c / wrapper 経由は実効 dir を静的に追わない
        sys.exit(1)
    # git の write セグメントに dir 差し替えが残っていないか
    if "git" in toks and any(t in WRITE_WORDS for t in toks):
        for t in toks:
            if t == "-C" or t.startswith("-C") \
               or t.startswith("--git-dir") or t.startswith("--work-tree") \
               or t.startswith("--namespace"):
                sys.exit(1)
            if re.match(r"^(GIT_DIR|GIT_WORK_TREE|GIT_NAMESPACE)=", t):
                sys.exit(1)
sys.exit(0)
PY
  then
    printf '%s' "$CWD"
    return 0
  fi
  # 証明不能(rc=1)も interpreter 起動失敗も同じく空=解決不能に倒す。
  return 0
}

# [2026-08-13][fix] issue #1672: `git push origin --delete <branch>` を main 直 push と誤判定しない
# 背景:
#   - ユーザー依頼意図: merge 済みリモート枝の cleanup（`git push origin --delete …`）が
#     main checkout から実行されても、main への refspec push ではないため許可したい。
#   - 守るべき業務ルール: リモート main 削除（--delete main / :main）は引き続き deny。
#     push と commit が同一入力にある場合は commit 側の main 保護を維持する。
#   - 他案不採用理由: push 全体を無条件許可する案は main refspec push の穴になるため不採用。
push_is_safe_remote_branch_deletion() {
  local segs seg
  segs=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE "${GIT_CMD}[[:space:]]+push[^;&|]*" || true)
  [ -n "$segs" ] || return 1
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    # [2026-08-27][fix] `git push --delete <remote> main`（--delete の直後が remote 名になる語順）
    # 背景:
    #   - ユーザー依頼意図: read-only 診断ドライバで `git push --delete origin main` /
    #     `git push -C <feature WT> --delete origin main` が誤って ALLOW（リモート main 削除）に
    #     なっていることが実測された。旧パターンは「--delete の直後トークンが main か」しか見ておらず、
    #     `--delete <remote> main` のように remote 名が間に挟まる語順を見逃していた。
    #   - 守るべき業務ルール: リモート main 削除（`--delete main` / `--delete <remote> main` いずれの
    #     語順でも）は引き続き deny。merge cleanup（`--delete <remote> <feature>`）は従来どおり許可し続ける。
    #   - 他案不採用理由:
    #     (a) `-d`（--delete の短縮形）を本 allowlist 側へ足す案 → 現状 `-d` はこの関数で
    #         「安全な枝削除」と認識されず後段の fail-closed で deny されている（意図せず安全側）。
    #         ここに `-d` を足すと `push -d origin feature/x` が新たに ALLOW になり、許可が広がるため不採用。
    #     (b) `--delete` の allowlist 自体を撤廃する案 → merge 後のリモート枝掃除（本来の用途）が
    #         止まるため不採用。
    #   対応: 「--delete の直後が main か」ではなく「セグメント中に main がトークンとして現れるか」で
    #   判定する。PUSH_SEGMENTS ブロック（本ファイル下部）の main 検知パターンと同一の正規表現を
    #   再利用し、新しい正規表現を発明しない（`main-old` / `feature/main` 等は従来どおり誤検知しない）。
    if echo "$seg" | grep -qE '(^|[[:space:]])--delete([[:space:]]|$)'; then
      echo "$seg" | grep -qE '(^|[[:space:]])\+?(refs/heads/)?main([[:space:]]|$)' && return 1
      continue
    fi
    if echo "$seg" | grep -qE '(^|[[:space:]]+)([^[:space:]]+[[:space:]]+)?:[^[:space:]]+'; then
      echo "$seg" | grep -qE '(^|[[:space:]]+)([^[:space:]]+[[:space:]]+)?:(\+)?(refs/heads/)?main([[:space:]]|$)' && return 1
      continue
    fi
    return 1
  done <<< "$segs"
  return 0
}

# [2026-10-10][feat] issue #1361 事象1: 全 refspec が明示的 refs/tags/<name> の
# tag push を main 直 push と誤判定しない。
# 背景:
#   - ユーザー依頼意図: jtt-cms 等の本番リリース正規手順（production HEAD への
#     r-v* タグ push）を main checkout から実行すると、「push を含む」だけで
#     最終 deny が発火し、`git tag r-v1.31.0 <sha> && git push origin refs/tags/r-v1.31.0`
#     の正規経路が塞がれていた。
#   - 守るべき業務ルール: タグ push は main ブランチの HEAD を一切動かさないため
#     main 保護の趣旨（レビューなし変更の防止）に抵触しない。ただし:
#     - 短縮形（refs/tags/ プレフィックスなしのタグ名）は同名 branch と区別できず
#       曖昧なので従来どおり fail-closed で拒否する（運用は refs/tags/ 形式に統一）。
#     - --tags / --follow-tags / --all / --mirror / --delete / -d や、コロン付き
#       refspec（src:dst）・複数 ref・値を取るオプションは対象外（従来どおり deny）。
#     - commit サブコマンド同梱時は呼び出し側で早期許可しない（commit 側の判定へ）。
#   - 他案不採用理由:
#     1) 短縮タグ名も許可する案: `git push origin v1` が branch v1 と区別できず、
#        branch push を誤許可しうるため不採用（issue 本文の判断と同じ）。
#     2) main cwd のときだけ許可する案: refs/tags/* だけの push はどのブランチでも
#        main に触れないため不採用。
# 対応: push セグメントの位置引数が「remote + 1個以上の refs/tags/<name>」だけだと
#   静的に証明できる場合のみ真を返す。証明できない形は従来どおり fail-closed。
push_is_only_explicit_tag_refspecs() {
  local segs seg
  segs=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE "${GIT_CMD}[[:space:]]+push[^;&|]*" || true)
  [ -n "$segs" ] || return 1
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    local args remote_seen=0 tag_refs=0
    args=$(printf '%s' "$seg" | sed -E 's/^.*[[:space:]]push([[:space:]]|$)/ /')
    # glob 展開を抑止して push 引数をトークン化（refspec 内の * がファイル展開されないように）。
    set -f
    # shellcheck disable=SC2086
    set -- $args
    set +f
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # リダイレクトトークンは無視（has_unsafe_push と同じ扱い）。
        *'>'*|*'<'*) ;;
        # 値を取らない安全フラグのみ消費。--tags/--follow-tags/--all/--mirror/
        #   --delete/-d/-o 等はここに含めず、下の -* で証明不能側へ倒す。
        -u|--set-upstream|-f|--force|--force-with-lease|-q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--porcelain|--progress|--atomic) ;;
        refs/tags/*)
          # コロン・ワイルドカードを含まない完全な refs/tags/<name> 形式だけを認める。
          echo "$1" | grep -qE '^refs/tags/[A-Za-z0-9._/-]+$' || return 1
          tag_refs=$((tag_refs + 1)) ;;
        -*) return 1 ;;   # 未知/値を取るオプション・一括系 → 証明不能
        *)
          # 最初の位置引数は remote。remote 以外の非 refs/tags 位置引数が1つでも
          # あれば tag-only ではない（remote 自体が refs/tags/* 形のときは上の
          # case が先に消費するため remote_seen が立たず、ここには来ない）。
          if [ "$remote_seen" = 0 ]; then remote_seen=1
          else return 1; fi ;;
      esac
      shift
    done
    # remote + 1個以上の refs/tags/* refspec が両方ある場合だけ許可側。
    [ "$remote_seen" = 1 ] && [ "$tag_refs" -ge 1 ] || return 1
  done <<< "$segs"
  return 0
}

# [2026-06-14][feat] / [2026-06-15][fix] 早期許可してはならない push が含まれるか（main 保護の fail-closed 判定）。
# 引数 $1: 実効ターゲットディレクトリ(effective_target_dir の解決結果)。bare/remote-only push の宛先を
#   この dir の push.default + upstream で判定するために使う。空なら bare push は解決不能=unsafe に倒す。
# 早期許可(worktree feature への exit 0)を通してよいのは:
#   1) 明示的非 main push:  git push [安全フラグ]* <remote> <非main・非wildcard・非colon の単一ブランチ>
#   2) [2026-06-15][fix] refspec 省略の bare push（git push / git push <remote> / git push --force-with-lease）で、
#      実効 dir のカレントブランチ(=呼び出し側が非 main を保証済み)が push.default 上 main に波及しないもの。
#      `cd <worktree> && git push --force-with-lease` 形（refspec 省略の常用フロー）を許可するための拡張。
# それ以外（複数 ref / 値を取るオプション(-o 等) / --all/--mirror / wildcard / main 宛て /
#   push.default=matching / upstream が main）は main を押しうるため unsafe=true を返す。
# トークン単位で解析し、未知オプション（値を取りうる）が残れば unsafe に倒す（保守的）。
has_unsafe_push() {
  local eff_dir="${1:-}"
  local segs seg
  segs=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE "${GIT_CMD}[[:space:]]+push[^;&|]*" || true)
  [ -z "$segs" ] && return 1  # push なし（commit only）→ 安全
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    local args remote="" ref="" extra=0
    args=$(printf '%s' "$seg" | sed -E 's/^.*[[:space:]]push([[:space:]]|$)/ /')
    # glob 展開を抑止して push 引数をトークン化（refspec 内の * がファイル展開されないように）。
    set -f
    # shellcheck disable=SC2086
    set -- $args
    set +f
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # [2026-06-16][fix] リダイレクトトークン(2>&1 / 2> / >file / 1>&2 / &>file 等)を無視する。
        #   segment 抽出 [^;&|]* は `2>&1` の `&` で切れ `2>` が残るため、従来はこれを余分な refspec
        #   と誤認し extra=1 → unsafe → 正当な worktree push が誤 deny されていた。git の refname は
        #   `<` `>` を含めないため(refname 規則)、これらを含むトークンは refspec ではない＝安全に無視できる。
        *'>'*|*'<'*) ;;
        # 値を取らない安全フラグのみ消費。
        -u|--set-upstream|-f|--force|--force-with-lease|-q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--porcelain|--progress|--atomic|--tags|--follow-tags) ;;
        -*) return 0 ;;  # 未知/値を取るオプション(--all/--mirror/-o 等) → 解析不能 → unsafe
        *)
          if [ -z "$remote" ]; then remote="$1"
          elif [ -z "$ref" ]; then ref="$1"
          else extra=1; fi ;;
      esac
      shift
    done
    [ "$extra" = 1 ] && return 0                 # ref が 2 個以上 → 曖昧 → unsafe
    if [ -z "$ref" ]; then
      # refspec 省略（git push / git push <remote>）→ カレントブランチを push.default に従って push する。
      # 呼び出し側で「実効 dir のカレントブランチ != main」を保証済み。main に波及する設定のみ unsafe。
      [ -z "$eff_dir" ] && return 0  # dir 未解決 → 宛先を検証できない → unsafe(fail-closed)
      local pd up
      pd=$(git -C "$eff_dir" config --get push.default 2>/dev/null || true)
      case "$pd" in
        matching)
          return 0 ;;  # 全 matching ブランチ(main 含む)を push しうる → unsafe
        upstream|tracking)
          # 設定上の upstream を push。main(またはそれを指す upstream)なら unsafe、解決不能も unsafe。
          up=$(git -C "$eff_dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
          { [ -z "$up" ] || echo "$up" | grep -qE '(^|/)main$'; } && return 0 ;;
        *)
          : ;;  # simple(既定)/current/nothing/未設定 → カレント(非main)ブランチのみ push → 安全
      esac
      continue
    fi
    echo "$ref" | grep -qE '^[A-Za-z0-9._/-]+$' || return 0  # : や * を含む → unsafe
    [ "$ref" = "main" ] && return 0
    echo "$ref" | grep -qE '(^|/)main$' && return 0  # refs/heads/main 等 → unsafe
  done <<< "$segs"
  return 1
}

BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

# merge cleanup 等: リモート枝削除だけの push は main 直 push ではない（commit 同梱時は下流で deny）
if push_is_safe_remote_branch_deletion && ! echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+commit"; then
  exit 0
fi

# issue #1361 事象1: 本番リリース正規手順。全 refspec が明示的 refs/tags/<name> の
# tag push は main の HEAD を動かさないため許可（commit 同梱時は下流で deny）。
if push_is_only_explicit_tag_refspecs && ! echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+commit"; then
  exit 0
fi

# 複合コマンド: checkout/switch main && commit/push を検知
if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+(switch|checkout)([[:space:]]+-[^[:space:]]+)*[[:space:]]+main([[:space:]]|$).*${GIT_CMD}[[:space:]]+(commit|push)([[:space:]]|$)"; then
  if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+commit"; then
    _emit_deny_with_telemetry "$DENY_MSG"
  fi

  if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+push"; then
    _emit_deny_with_telemetry "$DENY_MSG"
  fi
fi

# push コマンドからmain向けrefspecを検知
PUSH_SEGMENTS=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE "${GIT_CMD}[[:space:]]+push[^;&|]*" || true)
if [ -n "$PUSH_SEGMENTS" ]; then
  while IFS= read -r push_segment; do
    if echo "$push_segment" | grep -qE '(^|[[:space:]])\+?(refs/heads/)?main([[:space:]]|$)'; then
      if [ "$BRANCH" != "main" ]; then
        _emit_deny_with_telemetry "$DENY_MSG"
      fi
      if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+commit"; then
        continue
      fi
      _emit_deny_with_telemetry "$DENY_MSG"
    fi
    if echo "$push_segment" | grep -qE '(^|[[:space:]])\+?[^[:space:]]*:(refs/heads/)?main([[:space:]]|$)'; then
      if [ "$BRANCH" != "main" ]; then
        _emit_deny_with_telemetry "$DENY_MSG"
      fi
      if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+commit"; then
        continue
      fi
      _emit_deny_with_telemetry "$DENY_MSG"
    fi
  done <<< "$PUSH_SEGMENTS"
fi

# [2026-07-18][fix] env split-string内のgit writeはGIT_CMDへ展開できないため、先に拒否する。
if command_uses_env_split_git_write; then
  _emit_deny_with_telemetry "$DENY_MSG"
fi

# git commit / git push を含まない場合は許可
if ! echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+(commit|push)"; then
  exit 0
fi

# env の chdir は hook JSON の cwd と異なる実効branchへ切り替わる。完全解決せずfail-closed。
if command_uses_env_chdir; then
  _emit_deny_with_telemetry "$DENY_MSG"
fi

# [2026-10-09][fix] issue #2240: 書込先を解決してから判定する。
# 背景:
#   - 依頼意図: session cwd の branch で判定していたため、対象 workdir が別リポジトリの
#     feature branch でも親の main checkout を見て「main 扱い」で誤拒否していた
#     （workdir alias 対応で session cwd 側の修正は済み）。さらに逆方向にも穴があり、
#     session が feature のとき `git -C <main> commit` / `cd <main> && git commit` /
#     `(cd <main> && git commit)` / 改行区切りの cd が BRANCH 判定をすり抜けて素通りしていた。
#   - 守るべき業務ルール: 実効書込先が非 main と証明できる確定だけを許可する。
#     main・解決不能・unsafe push は session cwd の branch に関係なく fail-closed で拒否する。
#   - 他案不採用理由: cwd が main のときだけ別ターゲット解決を回す従来構造を維持する案は、
#     「cwd が feature なら別ターゲットを見ない」対称性の欠落が残り fail-open になるため不採用。
# 対応: 書込先解決（先頭の単一 cd 先 / 単発 -C 先 / 同一 -C 複合 / 書込が dir 差し替えを
#   持たない場合の session cwd）を branch 判定の前に常に実行し、解決結果の branch で
#   許可・拒否を決める。実効ターゲットのブランチが main 以外で、かつ main への push を
#   含まないなら、本番デプロイ(=main push/merge)に一切影響しないため許可する。
#   env トリック/複数 cd/サブシェル/eval/-c シェルは解決不能=従来どおり deny。
#   注: 本フックは「権限ルールの実体(SSOT)」そのもの。別途の権限ドキュメント同期は不要（ここが正本）。
# [2026-06-14][fix] worktree(別ディレクトリ・feature ブランチ)への commit / 非 main push を許可。
# 背景:
#   依頼意図: ハーネスが Bash cwd を毎回 main 直下に戻すため、worktree 運用は
#     `cd <worktree> && git commit/push` になる。従来は $CWD(main) の枝で fail-closed deny し、
#     worktree(feature) への正当なコミット・PR push まで弾けて worktree 並行開発が成立しなかった。
#   守るべき業務ルール: 実効ターゲット(先頭の単一 cd 先)のブランチが main 以外で、かつ main への push を
#     含まないなら、本番デプロイ(=main push/merge)に一切影響しないため許可する。
#   他案不採用理由:
#     1) 何もしない案: worktree 並行開発(ユーザーの主要フロー)が不能のままで不便。
#     2) commit/push を全面許可する案: main push の fail-open を生むため不可。実効ブランチ判定 +
#        has_unsafe_push ガードで main 保護を厳密に保つ（曖昧/全ref/wildcard/main 宛て push は早期許可しない）。
#     3) 実効 cwd を完全復元する案: 複数 cd・env トリック・サブシェル・-c まで追うのは複雑で誤許可リスク。
#        先頭の単一 cd のみ解決し（-C は git 1 回しか効かないため不採用＝deny）、env トリック/複数 cd/
#        サブシェル/eval/-c シェルは effective_target_branch が空を返す=従来 deny。
#     注: 本フックは「権限ルールの実体(SSOT)」そのもの。別途の権限ドキュメント同期は不要（ここが正本）。
# [2026-08-27][fix] issue: block-main-commit-deny-message
# 背景:
#   依頼意図: `git -C <feature-worktree> push -u origin feature/x 2>&1 | tail -6` のように
#     パイプ付き複合コマンドで -C の書込先を安全に証明できず deny になったケースが、
#     下の最終 deny で main 保護と同じ DENY_MSG（「main ブランチへの直接コミット/プッシュは
#     ブロックされました。git checkout -b feature/xxx でブランチを作成…」）を返していた。
#     既に feature branch で作業している AI がこの文面を読んで「main を直接触った」と
#     誤解し、人間へブランチ作成を手作業で依頼する誤誘導が実際に発生した。
#   守るべき業務ルール: 止める条件・許可条件は 1 文字も変えない（既存 exit 0 の位置・条件は不変）。
#     変えるのは「止めた理由の説明文」だけ。3 つの解決関数（effective_target_dir /
#     single_git_c_target_dir / consistent_git_c_target_dir）が全て空を返した（＝真に書込先を
#     証明できなかった）場合だけ UNCLASSIFIED_GIT_GUARD_MSG（分類不能文言）を使う。
#     いずれか 1 つでも解決できていた（例: refspec に `:` を含み has_unsafe_push が unsafe 判定した
#     ケース＝ eff_dir 自体は解決済み）場合は、従来どおり main 保護の DENY_MSG のまま。
#   他案不採用理由:
#     1) 3 関数とも同じ変数 `eff_dir` へ代入したまま「最後の eff_dir が空か」だけで判定する案:
#        1 つの戻り値しか見ていない実装でもテストが偶然緑になり、正しさの証明にならないため不採用。
#        3 つを別変数（eff_dir_a/b/c）へ保持し、明示的 OR で「3 つとも空」を判定する。
#     2) `command_targets_other_dir` ブロックの内側だけで判定変数を宣言する案: `set -euo pipefail`
#        (190行目) 下で -C を含まない main 直 commit（ブロック非到達）のとき unbound variable で
#        クラッシュし deny の JSON すら返せなくなる（＝保護が消える）ため、ブロック手前で
#        必ず初期化してから判定する。
# 対応: `unresolved_git_target` をブロック手前で 0 初期化し、3 つの解決結果が全て空のときだけ 1 を立てる。
#   最終 deny はこのフラグだけで DENY_MSG / UNCLASSIFIED_GIT_GUARD_MSG を振り分ける。
# [2026-10-03][fix] #3103: `resolved_eff_dir` も同じくブロック手前で空初期化する
#   （set -u 下で unset 参照によるクラッシュを防ぐ）。解決できた dir が
#   session cwd と別リポジトリ/別worktree のときだけ最終 deny を
#   OTHER_TARGET_GIT_GUARD_MSG へ振り分ける。
unresolved_git_target=0
resolved_eff_dir=""
if command_targets_other_dir; then
  eff_dir_a="$(effective_target_dir)"
  if [ -n "$eff_dir_a" ]; then
    eff_branch="$(git -C "$eff_dir_a" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$eff_branch" ] && [ "$eff_branch" != "main" ] && ! has_unsafe_push "$eff_dir_a"; then
      exit 0  # 別 worktree/別リポの feature への commit / 安全な非 main push（refspec 省略含む）→ 許可
    fi
  fi
  eff_dir_b="$(single_git_c_target_dir)"
  if [ -n "$eff_dir_b" ]; then
    eff_branch="$(git -C "$eff_dir_b" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$eff_branch" ] && [ "$eff_branch" != "main" ] && ! has_unsafe_push "$eff_dir_b"; then
      exit 0  # 単発 `git -C <feature> commit/push` は -C が対象 git へだけ効くため許可
    fi
  fi
  eff_dir_c="$(consistent_git_c_target_dir)"
  if [ -n "$eff_dir_c" ]; then
    eff_branch="$(git -C "$eff_dir_c" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$eff_branch" ] && [ "$eff_branch" != "main" ] && ! has_unsafe_push "$eff_dir_c"; then
      exit 0  # 同一 -C 先への add && commit 等の複合（issue #1672）
    fi
  fi
  # 第4 resolver: 書込セグメントに dir 差し替えが無い複合（read 系だけに -C が付く形等）なら
  #   書込先は session cwd と証明できる。$CWD を返すので以降は cwd の branch で判定される。
  eff_dir_d="$(session_cwd_target_dir)"
  if [ -n "$eff_dir_d" ]; then
    eff_branch="$(git -C "$eff_dir_d" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$eff_branch" ] && [ "$eff_branch" != "main" ] && ! has_unsafe_push "$eff_dir_d"; then
      exit 0  # 書込は session cwd(非 main)宛てと証明できた → 許可
    fi
  fi
  resolved_eff_dir="${eff_dir_a:-${eff_dir_b:-${eff_dir_c:-${eff_dir_d:-}}}}"
  if [ -z "$eff_dir_a" ] && [ -z "$eff_dir_b" ] && [ -z "$eff_dir_c" ] && [ -z "$eff_dir_d" ]; then
    unresolved_git_target=1  # 4関数とも解決不能＝真に書込先を証明できなかった（パイプ等）
  fi
fi

# [2026-05-30][fix] PR #229 codex review NO-GO 追加修正
# 背景: BRANCH==main かつ $CWD が軽量だけのとき、`git -C /other push`（refspec なし）等で
#   実効 cwd が /other に切り替わるコマンドが CWD の軽量差分で素通りしていた（line 309 残存fail-open）。
# 対応: command_targets_other_dir なら CWD ベース判定を信頼せず、main 向けは fail-closed。
#   `git -C /other push origin feature` (CWD=main) など希少な workflow を deny する副作用は
#   メイン保護のため許容（自然なワークフローは /other へ cd して実行）。
if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+(commit|push)"; then
  # [2026-08-27][fix] unresolved_git_target=1（解決関数が全て空）のときだけ分類不能文言。
  #   それ以外（cwd=main の直接操作、-C 先は解決できたが main 向け/曖昧refspecだった等）は
  #   従来どおり main 保護の DENY_MSG。
  if [ "$unresolved_git_target" = "1" ]; then
    _emit_deny_with_telemetry "$UNCLASSIFIED_GIT_GUARD_MSG\n\n検出理由: cannot prove -C/cd write target through piped or compound command"
  fi
  # [2026-10-03][fix] #3103: 書込先は解決できたが session cwd とは別リポジトリ/別worktreeの
  #   場合（cwd ずれ・colon refspec 等で unsafe 判定・-C 先が main）は main 文言を使わず、
  #   作業場所のずれが分かる別ターゲット文言で止める。許可/拒否の条件は不変。
  if [ -n "$resolved_eff_dir" ]; then
    target_top="$(git -C "$resolved_eff_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    cwd_top="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$target_top" ] && [ -n "$cwd_top" ] && [ "$target_top" != "$cwd_top" ]; then
      _emit_deny_with_telemetry "$OTHER_TARGET_GIT_GUARD_MSG\n\n書込先: ${target_top}\nセッション cwd: ${cwd_top}"
    fi
    # 解決できたのに早期許可されなかった = 書込先が main / branch 解決不能 / unsafe push。
    # session cwd と同一リポジトリなら従来どおり main 保護の DENY_MSG で止める。
    _emit_deny_with_telemetry "$DENY_MSG"
  fi
  # 書込先の差し替えが無い（または書込が session cwd 宛てと証明できた）場合は、
  # 従来どおり session cwd の branch で判定する。
  if [ "$BRANCH" = "main" ]; then
    _emit_deny_with_telemetry "$DENY_MSG"
  fi
fi

# main以外は許可
exit 0
