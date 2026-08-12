# メモリ参照ルール

制定経緯（CaD）: `~/business/AGENT-HUB/docs/architecture/rules-general-cad-archive.md`「memory-lookups.md からの移設」節を参照。

## 基本方針

memory は、前回までの作業状態・人物名・用語・過去の判断を思い出すための**参照補助**である。
売上・タスク・勤怠・予約・確定ルールの正本ではない。

以下のケースに該当するとき、応答を出す前に `~/.claude/projects/*/memory/MEMORY.md` および同階層の個別メモリファイルを検索する:

- **人名・略称・愛称**に遭遇したとき（読み方・関係性が記録されている可能性）
- **PJ 固有用語・コードネーム**に遭遇したとき
- **過去の不採用判断**を覆そうとしているとき
- ユーザーが「あの〜」「以前話した〜」等の指示語で参照しているとき

## 検索手順

`~/.claude/projects/*/memory/` 配下を検索し、`MEMORY.md` のインデックスから該当する個別ファイルを特定して読み、応答に反映する。

## 該当メモリがあった場合

- メモリの内容を踏まえて応答する
- メモリの記述が古い可能性がある場合は、現在の状態（コード・設定・正本MCP・Markdown SSOT）と突き合わせる
- 矛盾があれば**現状を優先**し、メモリの更新を提案する

## JTT 業務情報の正本

| 情報 | 正本 |
|------|------|
| 売上・取引・商品実績 | スマレジ / `jtt-smaregi-mcp` |
| 施策・担当・期限・進捗 | Asana / `asana-mcp` |
| 勤怠・シフト・出勤者 | 出パンダ / 将来の Depanda MCP |
| 予約・来店予定 | よやくま / 将来の Yoyakuma MCP |
| 確定した方針・ルール・議事録 | プロジェクトの Markdown SSOT |
| 横断分析・再利用する学び | G-Brain |
| 作業途中の短期文脈 | Claude / Codex / Hermes の memory |

memory と正本が矛盾する場合は、正本を優先する。G-Brain は検索・分析・要約の層であり、MCP から取得した生データの保管先にはしない。

**Asana のどこに何があるか**（workspace / project gid / section 構造 / 周期 PJ の命名規則）は
`~/business/AGENT-HUB/docs/reference/asana-project-map.md` が地図。gid を推測せず、まずこの地図を引く。
地図には参照先だけがあり、タスクの中身は載せない（中身は `asana-mcp` でその場で取る）。

## 該当メモリがなかった場合

- 推測で補完せず、ユーザーに直接確認する
- 確認後、必要に応じて新規メモリとして記録する（auto memory ルール参照）

## 関連

- グローバル auto memory: Claude Code ハーネス標準の Memory 機能（旧 CLAUDE.md「auto memory」セクションは廃止済み・保存実体は下記 PJ 別ディレクトリ）
- PJ 別 auto memory: `~/.claude/projects/<encoded-path>/memory/`

---

**追記ルール: 実測事例・長文詳細・制定経緯は `docs/architecture/rules-general-cad-archive.md` へ書き、本ルールには義務・トリガー・禁止事項だけ足す（再肥大化防止）。**
