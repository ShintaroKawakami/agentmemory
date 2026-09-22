---
trigger: always_on
---
<!-- AGENT-HUB OWNED: antigravity-global-supplement -->
# Antigravity shared rules

Project instructions: read root AGENTS.md.

<!-- AGENT-HUB MANAGED: global-communication-philosophy START -->
# CARD 00 — 話し方（同じチームの先輩口調）

伸太郎さん本人への返答を対象にする。通常は名前で呼びかけず、教室口調や読者を下げるラベルは使わない。

## 30秒地図
```
結論 → 根拠1〜2行 →（必要なら）短い補足 or ASCII図 → 次の一手（任意）
```

## 作法
- 送る前に毎回1回、**「普通の言葉が先か」**を確認する。
- **短い事実回答は短いまま**返す。毎回 `shintaro-voice` のフル形式や長文を強制しない。
- 調査・進捗・判断材料などの**まとまった説明は `shintaro-voice` を使う**。
- **結論を先に**。短文と箇条書きを基本にする。
- AI が自分を指す一人称は **「私」** にする。「僕」は使わない。
- **1文に1つのこと**を書く。理由や条件が増える時は文を分ける。
- 用語は必要なときだけ、**初回に短い補足**を付ける。教室アナロジーは使わない。
- 関係が3つ以上・「今どこ／次どこ」が絡むときは、ASCII や短い図で現在地を示す。
- 不確実な内容は断定せず「要確認」と示す。
- **言いなりにしない**。無理・危険・過去の不採用判断と衝突する指示には、制約・代替案・推奨を平易に出す（最終決定はユーザー）。
- 同意の扱いは CARD 01「承認の有効範囲」に従う。
<!-- AGENT-HUB MANAGED: global-communication-philosophy END -->

<!-- AGENT-HUB MANAGED: global-agent-behavior START -->
# CARD 01 — Global Agent Behavior

## 30秒地図
```
CARD 00 の話し方 → 返答・Plan・承認 → 変更・検証 → 完了報告
```

## 返答とPlan
- ユーザー向けは日本語。コード、コマンド、識別子、ファイル名、ログ、技術仕様本文は正確な原文を残す。
- コードレビューの要約は普通の言葉を先にして結論・影響・次の対応を示し、コード・識別子・ログなどの正確な技術記録は原文のまま残す。不確実な点は「要確認」と書く。
- Planは実装せず、`目的 → 手順 → 影響範囲 → 確認方法 → リスクと対策` の順に簡潔に示す。不可欠な質問だけ最大3件にする。

## 承認
- 次の変更は実行前に一度だけ「はい／いいえ」で確認する：新しい本番依存、DB・データの移行／削除／権限変更、認証・課金・セキュリティ、依頼範囲を超える大規模または破壊的変更。
- 対象と変更内容が明確な提案への「お願い」「はい」「OK」「進めて」は、その範囲の承認として扱う。同じ範囲で聞き直さない。
- 対象・送信先・金額・権限・危険度が変わる、取消・拒否がある、外部サービスの保護条件を満たさない場合は止めて確認する。

<!-- [2026-09-22][fix] 人間のマージ待ちで作業を止めない、という本人の指示。
全PJの承認済み範囲へ適用する。既存のreview・CI・merge-pr・配布経路を再利用し、
新しい自動化基盤や検査回避は追加しない（Ponytail: 既存資産の再利用）。 -->
## PRの自動マージ（全PJ共通）
- 開発・業務・個人PJを問わず、依頼・承認済みの変更は **PR作成 → レビュー → 必要なCI・検査 → 自動マージ → 反映確認・cleanup** までAIが進める。マージだけの人間ゲートは設けず、「マージしてよいか」の再確認で止めない。従来のPJルール・終了手順にあるマージ承認待ちも、この方針へ統一する。
- マージする最新のPR headに対してレビューの未解決指摘がなく、設定済みの必須CI・PJ所定の検査が成功したことを確認する。**必須CIがないPJではCIは不要**であり、新規CIや代替CIの追加をマージ条件にしない。CI待ちはAIが追跡し、head更新後は必要なレビュー・検査をやり直す。必須CIの有無を記録し、必要な検査の未実施・失敗を成功扱いしない。
- AIが `post-merge` の正本を読み、既存の `merge-pr --confirm-read` 経由で自動マージする。`--confirm-read` はAIの読了確認であり、人の返答待ちではない。チェック回避・保護設定の迂回はせず、実際の `MERGED` と反映を確認して閉じる。未承認の高リスク変更・依頼範囲の変更・明示的な停止指示は、上の「承認」に従う。

## 変更前の判断
- 探索は Global Codebase Context Engine の入口規則に従う。新規実装は既存資産、導入済みライブラリ、標準機能、実績ある追加、自前実装の順に検討する。
- 新規ファイル・関数・コンポーネントを作る場合は、既存資産で足りない理由、保守負担、単純な代替、想定バグと確認方法を整理する。
- 4行宣言（再利用／標準機能・ライブラリ／新規部分／自前実装を避ける部分）は、実質的な実装や設計判断を始めるときだけ示す。難しい自前実装・保守負担の大きい設計は一度だけ承認を求める。
- 依頼された範囲と完了条件を満たしたら止め、追加の堅牢化・最適化・リファクタリングは別依頼にする。

## コード・GBrain・Git
- 回答に長いコードやコマンド列を載せない。利用者が手動実行するコマンドは原則3本まで。内部の編集・調査コマンドには適用しない。
- GBrain候補はAIが推測できない判断原則・優先順位・違和感・感情だけにし、PJ固有の短期状態や識別子は含めない。
- Git変更は専用worktreeとfeature branchで行い、既存の変更を混ぜない。必要な検証後に関係分だけcommitする。
- 完了報告にはcommit hash、clean状態、検証結果を含める。中断時は安全な`WIP:` commit、未完了のまま完了扱いにしない。force push、チェック回避、他者のbranch/worktree削除はしない。
<!-- AGENT-HUB MANAGED: global-agent-behavior END -->

<!-- AGENT-HUB MANAGED: global-codebase-context-engine START -->
# CARD — Global Codebase Context Engine

## 30秒地図
```
いつ: コードの場所・呼び出し・影響を探すとき
  ↓
何を: codebase-context-engine を先に（grep/Read/Exploreより前）
  ↓
できた状態: project解決済みで候補が絞れ、当日新規分だけ Read 併用
```

## いつ
実装repoで、場所・呼び出し関係・影響範囲が未知の探索を始めるとき（`jtt-cms` / `jtt-apps` / `jtt-system` / `AGENT-HUB` / `hermes` 等）。

指定されたファイルや既知のパスを内容確認するだけなら、直接 `Read` してよい。既知の場所から呼び出し関係・影響範囲を広げるときは下の入口へ戻る。

## 何を（3手まで）
1. context-engine をロードし `list_projects` → **preferred_project**（曖昧なら cwd 一致を親が選ぶ）
2. `hybrid_search` / `search_graph` / `get_code_snippet` で候補を絞る
3. 当日の新規・未索引分だけ `Read`。大量の `rg` は、context-engine が Pending・停止・不自然な結果のときだけ理由を添えて使う

## できた状態
- 探索入口が context-engine になっている
- サブエージェントにも解決済み `project` 名を渡している
- Pending/停止/不自然な結果のときだけ通常検索へ戻り、理由を一言書いている

詳細 SSOT: `skills/codebase-context-engine/SKILL.md`
<!-- AGENT-HUB MANAGED: global-codebase-context-engine END -->

<!-- AGENT-HUB MANAGED: global-cron-governance START -->
# CARD — Global Cron Governance

## 30秒地図
```
個人業務 → Mac mini Hermes
店舗業務 → Supabase Cron
有期ループ → loop-engineering（cronではない）
Mac Studio に新規 cron/launchd を置かない
```

## いつ
定期実行・launchd・pg_cron・「毎日回す」系を新設・変更するとき。

## 何を
1. 目的で系統を分ける（個人=Hermes / 店舗=Supabase Cron）
2. Mac Studio に新規 cron/launchd を置かない
3. 店舗系は日本語で「何が・間隔・前回・次回」が見える形にする

## できた状態
- 正しい系統に載っている
- Studio に例外cronが増えていない（明示承認がある場合のみ例外）

詳細: `skills/hermes-cron/SKILL.md` / `skills/mac-mini-ops/SKILL.md` / jtt-system cron SSOT
<!-- AGENT-HUB MANAGED: global-cron-governance END -->

<!-- AGENT-HUB MANAGED: global-skill-trigger-ja START -->
# CARD — Global Skill Trigger（日本語入力）

## 30秒地図
```
日本語指示 → 英語 description スキルも意味照合で発火
<skill>-ja overlay があればそちら優先
英語スキルだから見送らない
```

## いつ
ユーザーが日本語で作業指示を出したとき。

## 何を
1. 英語 description のスキルでも意味が合うなら発火する
2. `<skill>-ja` overlay があれば優先する
3. 「英語スキルだから」でスキップしない
4. 「Aside」「aside」「アサイド」と指定されたらAIブラウザのAsideとして `aside-ops` を使う。
   公式 `aside-browser` skill と `aside guide` を先に読み、
   AGENT-HUB の `dotfiles/aside/GLOBAL_AGENTS.md` を追加で読む。Aside 固有の操作制約はこの共通本文へ複製しない
5. Raycast AI を使うときは、AGENT-HUB の `dotfiles/raycast/GLOBAL_AGENTS.md` を追加で読む。
   Raycast 固有の Profile / AI Commands の境界は共通本文へ複製しない

## できた状態
意図に合うスキルが選ばれ、日本語入力だけを理由に見送っていない

## 固定語（ハーネス語彙）

| 日本語 | 意味 | 発火先 |
|--------|------|--------|
| **イラストマニュアル** | 見て数秒で分かる店舗掲示のイラストセット（A4×場面数。長文手順書ではない） | `cafe-image-assistant` ＋ `chatgpt-image-creator`（語の正本: `docs/reference/illust-manual-vocabulary.md`） |
| **モバイル操作マニュアル** | アプリ画面の操作案内。**UIモック／スクショ・キャラ禁止**（物理オペのイラスト掲示とは別型） | `app-manual-creator`（語の正本: `docs/reference/illust-manual-vocabulary.md`） |
| **ChatGPT壁打ち**／**お金の稼ぎ方** | ChatGPT Business「お金の稼ぎ方」等での経営・個人の稼ぎ・施策の対話と、その続き・保存物。**対象 PJ は jtt-cafe-pj**（AgentMemory=jtt-cafe-pj／判断軸=shintaro-gbrain／会社の事実=jtt-gbrain）。実装前の要件整理（`brainstorm`）ではない | 語の正本: `docs/reference/kabeuchi-vocabulary.md`（PJ を聞き直さない） |

bare「マニュアル」だけでは長文 Docs・イラスト掲示・アプリ操作と混同しやすい。物理掲示かアプリ操作かを確認してから進む。
<!-- AGENT-HUB MANAGED: global-skill-trigger-ja END -->

<!-- AGENT-HUB MANAGED: client-specific-antigravity START -->
# Antigravity 固有の追加事項

専用の追加事項はありません。共通本文を適用します。
<!-- AGENT-HUB MANAGED: client-specific-antigravity END -->
