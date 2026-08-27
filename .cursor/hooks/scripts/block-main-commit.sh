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
# git グローバルオプションを 0個以上許容する共通パターン。
readonly GIT_GLOBAL_OPT='(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--config-env[[:space:]]+[^[:space:]]+|--git-dir(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--work-tree(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--namespace(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)|--exec-path(=[^[:space:]]+|[[:space:]]+[^[:space:]]+)?|--super-prefix[[:space:]]+[^[:space:]]+|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--help|--version|--html-path|--man-path|--info-path|-p)'
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

read_stdin
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

print("".join(" " if mask[position] else char for position, char in enumerate(text)), end="")
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
  case "$guard_reason" in
    *"unknown Git subcommand"*|*"Git alias"*|*"through shell substitution"*|*"through opaque"*|*"across conditional or piped cd"*|*"through env split-string"*|*"through eval"*)
      _emit_deny_with_telemetry "$UNCLASSIFIED_GIT_GUARD_MSG\n\n検出理由: $guard_reason"
      ;;
    *)
      _emit_deny_with_telemetry "$UPSTREAM_GUARD_MSG\n\n検出理由: $guard_reason"
      ;;
  esac
}

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
  local cd_paths cd_path
  cd_paths=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]+' || true)
  if [ -n "$cd_paths" ]; then
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      cd_path=$(echo "$match" | awk '{print $NF}')
      case "$cd_path" in
        "."|"./") ;;  # no-op
        *)
          # cd の後に && または ; があり git が続くことを確認
          if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "cd[[:space:]]+$(printf '%s' "$cd_path" | sed 's/[[\.*^$/]/\\&/g')[[:space:]]*[;&]"; then
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
  local cds dir
  cds=$(echo "$COMMAND_FOR_GIT_MATCH" | grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+[^[:space:];&|()]+' || true)
  [ "$(printf '%s\n' "$cds" | grep -c .)" -ne 1 ] && return 0
  # その単一 cd が「先頭」かつ「&& / ; で後続に効く」形であること（背景 & / パイプ | は対象外）。
  echo "$COMMAND_FOR_GIT_MATCH" | grep -qE '^[[:space:]]*cd[[:space:]]+[^[:space:];&|()]+[[:space:]]*(&&|;)' || return 0
  # [2026-06-16][fix] COMMAND が複数行(heredoc / 改行入りコミットメッセージ等)のとき、
  #   sed が行単位で処理し非マッチ行(2 行目以降のメッセージ本文)を素通しするため dir がゴミ文字列化し、
  #   git -C "$dir" が失敗 → 正当な worktree commit/push が誤 deny されていた。cd は先頭行(上の L427 で
  #   先頭 + &&/; を保証済)にあるため、1 行目だけから抽出する（複数行は安全に L1 のみを見る）。
  dir=$(printf '%s' "$COMMAND" | sed -nE '1s/^[[:space:]]*cd[[:space:]]+([^[:space:];&|()]+).*/\1/p')
  # ~ 展開 / 相対パスは $CWD(JSON の cwd) 基準で正規化（git -C が hook プロセスの cwd で解決するのを防ぐ）。
  case "$dir" in
    ""|"."|"./") return 0 ;;
    "~") dir="$HOME" ;;
    "~/"*) dir="${HOME}/${dir#\~/}" ;;
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
    if echo "$seg" | grep -qE '(^|[[:space:]])--delete([[:space:]]|$)'; then
      echo "$seg" | grep -qE '(^|[[:space:]])--delete([[:space:]]+)(\+)?(refs/heads/)?main([[:space:]]|$)' && return 1
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

if [ -z "$BRANCH" ]; then
  exit 0
fi

# mainブランチの場合 — AI hook 経由では軽量変更でも commit / push を許可しない
if [ "$BRANCH" = "main" ]; then
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
  unresolved_git_target=0
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
    if [ -z "$eff_dir_a" ] && [ -z "$eff_dir_b" ] && [ -z "$eff_dir_c" ]; then
      unresolved_git_target=1  # 3関数とも解決不能＝真に書込先を証明できなかった（パイプ等）
    fi
  fi

  # [2026-05-30][fix] PR #229 codex review NO-GO 追加修正
  # 背景: BRANCH==main かつ $CWD が軽量だけのとき、`git -C /other push`（refspec なし）等で
  #   実効 cwd が /other に切り替わるコマンドが CWD の軽量差分で素通りしていた（line 309 残存fail-open）。
  # 対応: command_targets_other_dir なら CWD ベース判定を信頼せず、main 向けは fail-closed。
  #   `git -C /other push origin feature` (CWD=main) など希少な workflow を deny する副作用は
  #   メイン保護のため許容（自然なワークフローは /other へ cd して実行）。
  if echo "$COMMAND_FOR_GIT_MATCH" | grep -qE "${GIT_CMD}[[:space:]]+(commit|push)"; then
    # [2026-08-27][fix] unresolved_git_target=1（3関数とも解決不能）のときだけ分類不能文言。
    #   それ以外（cwd=main の直接操作、-C 先は解決できたが main 向け/曖昧refspecだった等）は
    #   従来どおり main 保護の DENY_MSG。
    if [ "$unresolved_git_target" = "1" ]; then
      _emit_deny_with_telemetry "$UNCLASSIFIED_GIT_GUARD_MSG\n\n検出理由: cannot prove -C/cd write target through piped or compound command"
    fi
    _emit_deny_with_telemetry "$DENY_MSG"
  fi
fi

# main以外は許可
exit 0
