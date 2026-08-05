<!-- [2026-07-29][refactor]
背景:
  - ユーザー依頼意図: 常駐ルールダイエット第2弾。全PJに常駐する `ui-stitch-mandatory.md` が6,649字まで
    肥大化し、制定経緯の長文CaDコメント（2件）がコンテキストを圧迫していた。
  - 守るべき業務ルール: 内容は消さない（reference-over-hardcode.md 原則）。義務・トリガー・禁止事項は rule に残し、
    制定経緯は移設先へ移す二段構え（PR1 #997・PR2 #1001 と同型）。
  - 他案不採用理由: rule 側に全文を残す案は再肥大化を放置するため不採用。制定経緯を削除する案は
    過去の不採用判断（brainstorm/parallel-run skill内限定案・Stitch手順転記案 等）の参照材料を失うため不採用。
対応: `.claude/rules/general/ui-stitch-mandatory.md` から `skills/stitch/SKILL.md` へ、
  制定経緯（2026-05-27）・MCP選択正本のmanifest v2切替経緯（2026-07-20）を移設。
-->

# UI / デザインは必ず Stitch を通すルール（強制）

制定経緯（2026-05-27 新設判断・2026-07-20 MCP選択正本切替）は `skills/stitch/SKILL.md` の
「ui-stitch-mandatory 制定経緯」節を参照。

## 原則

UI / 画面 / デザイン / レイアウト / コンポーネントの**新規作成・見た目の変更**依頼は、**必ず Stitch**（`skills/stitch` + Stitch MCP `mcp__stitch__*`）でデザインを生成し、**伸太郎殿が実物を見て確定してから実装に進む**。

理由: UI は AI とユーザーの言語的意思疎通が難しく、テキストだけで合意したつもりで実装すると手戻りが多発する。Stitch で生成した実物を見て双方の認識を合わせることで「手戻りゼロ」を狙う。

## 必須手順

1. **Stitch でデザイン案を生成**（**最低 3・最大 5（ケースバイケース）**）。1 案だけ出して進めるのは**禁止**。
2. **伸太郎殿が Stitch Web（プロジェクト URL）で比較・確定**する。
3. **確定したデザインだけ**を基に実装する（`.stitch/` 出力 / DESIGN.md を参照）。

## 適用トリガー

「UI を作って」「画面作って」「デザイン（して）」「レイアウト変更」「コンポーネント新規」など（`skills/stitch` の triggers と整合）。判断に迷う場合は Stitch を通す側に倒す。

## データ格納ルール（リポジトリルート汚染防止）

Stitch 由来のファイルを散らかさないため、保存先を固定する:

| データ | 置き場所 |
|--------|---------|
| ① デザイン案の比較 | **Stitch Web（プロジェクト URL）で見る** → 全候補をローカル保存しない |
| ② 確定したデザイン | `.stitch/<システム名>/<画面名>/`（`code.html` + `screen.png`）にだけ Export |
| ③ MCP 取得データの一時保存 | **temp ディレクトリ**（その PJ の `/tmp/` 等・gitignored） |
| ④ リポジトリルート直下・任意の場所 | **保存禁止**（ゴミファイル堆積を防ぐ） |

- `.stitch/` は**Stitch を使う PJ ごとに gitignore する**（生成物はコミットしない）。配布先 PJ へ広げる場合は、その PJ 側の `.gitignore` 変更を別途同じ変更束に含める。
- 「とりあえずルートに HTML を置く」は**禁止**。必ず上記 ① 〜 ③ のいずれかに収める。

## 例外（Stitch 不要）

- 既存 UI の微修正（typo 修正・1 色だけ変更など、**見た目の方針が変わらない**もの）。
- UI に変化を伴わない純粋なロジック修正。
- **写真・イラスト・商品画像・掲示物の図解**（画面レイアウトではなく「絵そのもの」を作る作業）。
  → Stitch ではなく下記「画像生成」の導線を使う。

## 画像生成（写真・イラスト・図解）は手順を読んでから着手する（強制）

Stitch の対象外である**絵そのもの**（商品写真・HP 用画像・バナー・掲示物の図解等）を ChatGPT で作る時は、
**着手前に必ず `~/business/AGENT-HUB/agents/global/chatgpt-image-creator.md` と
`~/business/AGENT-HUB/agents/config/chatgpt-image-creator.yaml` を読む**。

- **サブエージェントへ委譲する時も、PM / 親セッションが自分でやる時も同じ**。
  「自分でやるから読まなくていい」は不可（読まずに始めた結果、既知の失敗を踏み直した実測あり）。
- 手順の正本は上記2ファイル。本ルールは義務とトリガーだけを持ち、手順を複製しない
  （`plan-approval-gate` / 本ルール上部の Stitch と同じ二段構え）。

### トリガー

「画像を作って」「写真を生成して」「イラストを作って」「バナー作って」「図解を作り直して」
「ChatGPT で画像」など。判断に迷う場合は**読む側**に倒す（読むコストは小さく、踏み直すコストは大きい）。

### なぜ強制するか

2026-08-05、jtt-cafe-pj の掲示物で図解を差し替えた際、手順を読まずに着手した結果、
①自分で開いたタブが数秒で閉じる ②送信できていないのに成功と誤認 ③古い応答を最新と誤認、
を繰り返して**10回以上リトライを空費**した。いずれも上記2ファイルに対処が書かれている
（タブ借用ファースト / 送信の実証 / 停止ボタンでの完了判定 / 手渡し fallback）。

## MCP 前提

Stitch MCPの接続definitionは`~/business/AGENT-HUB/docs/codex-mcp-definitions.yaml`、project採否は
`registries/harness-manifest.yaml#asset_contract` のeffective `mcp` setを正とする。
未接続時は `scripts/sync-agents.py --project <pj> --dry-run` で継承・surface・envを確認し、apply後にfresh clientでruntime proofを取る。

## 接続

- 手順 SSOT: `skills/stitch/SKILL.md`（プロンプトテンプレ・`.stitch/` 規約・DESIGN.md 抽出・MCP 前提）。本ルールは手順を複製せず参照する。
- dev フローの普遍 UI ルール（Tailwind 等）は `skills/dev-guardrails/SKILL.md`（2-10 ほか）の上に乗る。業務 PJ は `skills/business-guardrails/SKILL.md`。
- 要件固め・実装フローでの発火点: `skills/brainstorm/SKILL.md` / `skills/parallel-run/SKILL.md`。
- Stitch でデザインを作る際は `~/business/AGENT-HUB/docs/design/design-philosophy.md`（伸太郎殿の設計思想 SSOT）に従うこと。本ルールは思想本文を複製せず参照する。
- 「Stitchで作って」の委譲は `agents/global/stitch-screen-creator.md`（着手前に設計思想 doc を必読）が実行役を担う。

## 関連

- `skills/stitch/SKILL.md` — Stitch ワークフロー SSOT
- `skills/dev-guardrails/SKILL.md` / `skills/business-guardrails/SKILL.md` — ガードレール
- `skills/brainstorm/SKILL.md` / `skills/parallel-run/SKILL.md` — 発火フロー
- `~/business/AGENT-HUB/docs/codex-mcp-definitions.yaml` — Stitch MCPのtransport / 認証definition
- `registries/harness-manifest.yaml` — global / harness type / projectの採否とsurface契約
- `~/business/AGENT-HUB/docs/design/design-philosophy.md` — 伸太郎殿の設計思想 SSOT
- `agents/global/stitch-screen-creator.md` — Stitch 画面作成グローバルエージェント
- `agents/global/chatgpt-image-creator.md` / `agents/config/chatgpt-image-creator.yaml` — **画像生成（絵そのもの）の手順 SSOT**。本ルールの「画像生成」節が指す先

---

**追記ルール: 制定経緯・実測詳細は `skills/stitch/SKILL.md` へ書き、本ルールには義務・トリガー・禁止事項だけ足す（再肥大化防止）。**
