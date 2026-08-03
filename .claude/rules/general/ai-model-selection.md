<!-- [2026-07-18][fix]
背景:
  - ユーザー依頼意図: 常駐ルールを短くしても、Codex effort 方針を変えた理由と旧判断を追跡できる状態を保つ。
  - 守るべき業務ルール: `high` は「Codexで実装」の既定に限り、軽微タスクは `medium`、レビューは codex-review、`xhigh` はユーザー明示時だけにする。
  - 他案不採用理由: 旧既定 `medium` へ一律に戻す案は新しい実測を反映できず、長い実測ログを常駐ルールへ戻す案はコンテキストを再肥大化させるため不採用。
対応: 判断理由だけを CaD に残し、詳細な実測ログは agent-dispatch references を正本とする。
-->

# AI モデル選定指標（GLM 5.2 / Kimi K2.7・K3）

全 PJ 共通。コード実装をAIエージェントに任せる際の初期ヒューリスティック。

> ⚠️ これは**法則ではなく初期判断**。母数が小さい（初期 n=4 + 追加観測・人が見ながら実行）。矛盾する観測が出たら現状を優先し、実測ログ（references）を更新すること。

---

## 0-bis. Codex 指名時の固定ルール

- **`codexで実装` / `Codexで実装` / `codex実装` / `Codex実装`** と言われた時だけ、Codex 実装として扱う。
- Codex 実装の正式設定名は **model = `gpt-5.3-codex-spark`**, **model_reasoning_effort = `high`**（既定。旧既定 `medium`。SWE-Bench Pro 実測で high→xhigh の上げ幅は1pt未満のため常時 xhigh は費用対効果が低い）。
- 起動例は `codex exec -m gpt-5.3-codex-spark -c model_reasoning_effort=high`。
- **`xhigh` はユーザーが明示指定した時だけ使う**。軽微タスクは `medium` を明示指定する。AI が自動・既定・推測で `xhigh` を選ばない。
- **「実装」だけでは Codex 固定にしない**。Cursor / Kimi / GLM / Claude / Codex のどれで進めるかを文脈で判断し、不明なら確認する。
- **Spark は AI Worker MCP の auto routing 候補に対等参加する**（適材適所＋残量バランス・絶対優先ではない）。原因不明バグ・設計判断・DB移行・大規模リファクタ・コンテキストが大きい仕事は Spark に固執せず、auto が適材適所で他 worker（GLM/Kimi/Gemini）へ回避する。
- **「レビュー」または「codexでレビュー」** は既存の `codex-review` 導線を使う。実装専用の `gpt-5.3-codex-spark` 固定には巻き込まない。

---

## 4. 使い分けガイド（第一候補）

| タスク種別 | 第一候補 | 理由 |
|-----------|---------|------|
| 仕様が明確・クリーンさ重視・UI/結線・お手本コード | **GLM 5.2** | 簡潔・範囲内に収まりやすい・速い |
| 複雑・セキュリティ/堅牢性が重要なバックエンド | **Kimi K2.7 Code** | 安全性を自力で深掘り・テスト厚い |
| どちらでも可 | いずれか | ただし下記ガードを必ず付ける |

### Kimi 内モデル選択（決定論的）

`agents.yaml.worker_delegation.kimi_model_routing` を正本とし、優先順は、明示 `provider_model` → 長大/推定不能な巨大contextの `k3` → 明示的な速度優先かつ3倍quota許容時の `kimi-for-coding-highspeed` → 通常の `kimi-for-coding` とする。

- K3条件: `requires_long_context=true`、推定contextが212,992 token超、または推定不能かつraw UTF-8が512KiB超。`max`、上限1,048,576 token。
- 選定結果: `reason_code` / `selected_model` / `estimated_context` / `fallback_reason` を必ず残す。
- K3切替: 新sessionを開始し、必要情報の要約だけを渡す。履歴を丸ごと移送しない。

GLM 5.2 の正式運用は high / max のみ（デフォルト high・他の値はルーティングのバリデーションで拒否される）。母数は n=4 の初期観測であり法則ではない（冒頭⚠️参照）。

---

## 5. 運用上の必須ガード（モデルの弱点を相殺する）

- **完了の定義を検証可能に**（Kimi の過大申告対策）: 「スクショは git にコミット」「テストは緑のログを示す」等、"やったと言うだけ"を許さない。
- **スコープを超えるなを明示**（Kimi の過剰実装対策）: 「指定範囲のみ。追加の堅牢化は別 PR」。
- **長時間タスクは声がけ / 自動継続**（GLM の停滞対策）。
- **リポの前提を渡す**（GLM の取り違え対策）: 言語・パッケージ管理の前提を明記。
- **既存 CaD コメント規約に倣わせる**: 新規関数・ブロック追加時は対象ファイルの既存様式（日付・種別・背景3点）に倣うと明記する。

---

## 6. 候補提案とディスパッチ

実装委譲・並列実装の話題が出たら §4 を根拠に「GLM 5.2 向き / Kimi向き」を 1 行理由つきで先に提案し、Kimi内のK2.7/K3は上記契約で選ぶ。ディスパッチ実行は `agent-dispatch` スキルへ（未導入環境では §4・§5 のみ使う）。役割分担: 方針選定・委譲・進捗確認・結果回収 = Claude / Codex。実行は `agents.yaml` の有効 provider だけを AI Worker MCP 経由で行う。プロンプトには §5 の必須ガードを必ず織り込む。

詳細手順は `skills/agent-dispatch/` を参照（本ルールは方針、skill は手順＝DRY）。

---

## 8. 関連

- `skills/agent-dispatch/` — `agents.yaml` と AI Worker MCP を使う worker 委譲手順（本ルールの実行系）
- `skills/kimi-sync/` — Kimi CLI のPJアタッチ（`sync-kimi-from-cc.py`）
- `.claude/rules/general/response-style.md` — 出力簡潔性
- `.claude/rules/general/visual-progress-map.md` — 進捗可視化
- `dotfiles/kimi/config.toml.base` — Kimi Code CLI の loop/permission 既定（`max_steps_per_turn` 等）
- 実測ログ・スコアカード・OpenCode Go 選定指標の全文: `<AGENT-HUB>/skills/agent-dispatch/references/model-selection-evidence.md`

`<AGENT-HUB>` は中央ハブrepoのルートを表す（標準配置は `~/business/AGENT-HUB`、別環境では実際の配置先）。

**追記ルール: 実測ログ・スコアカードは references（上記）へ追記し、本ルールには足さない（再肥大化防止）。**
