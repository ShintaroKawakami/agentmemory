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

<!-- [2026-08-08][feat] ctx-slim 柱3: AI worker 委譲の既定化
背景:
  - ユーザー依頼意図: $200 プラン上限対策として Claude 本体のトークン消費を抑えるため、実装・大量読みを
    AI worker へ寄せる運用を既定化する（ctx-slim プラン承認済み・2026-08-08）。大量読みの第一候補は
    伸太郎殿の指名により Kimi K3 とする（長大 context が根拠。「Fable の蒸留」説は未確認情報のため根拠にしない）。
  - 守るべき業務ルール: モデル実名・context 上限値をここへハードコードしない（agents.yaml の
    kimi_model_routing を実行時参照）。ガバナンス領域（.claude/ hook 等）は worker が編集できないため
    従来どおり Claude が担う。
  - 他案不採用理由: 専用ルール新設は常時ロード量を増やし ctx-slim の目的に反するため不採用。既存 §4 への
    追記に留める。委譲手順の複製も skills/agent-dispatch との二重管理になるため不採用。
[2026-08-08][feat] 境界行を追記（worker-speed プラン B）。実測（job 8714b5dc）で小タスクの往復コストが
  実装時間を上回る事例が出たため、既定の適用範囲を1行で明示する。閾値・手順の詳細は skills/agent-dispatch
  が正本（ここへ複製しない）。専用ルール新設は ctx-slim に反するため不採用。
-->

**既定（2026-08-08 ctx-slim）**: 実装・大量読み（リポ横断の読み込み・大規模ファイル調査）は AI worker への委譲を既定とし、Claude（PM）は設計・検証・統括に徹する。大量読みの第一候補は **Kimi K3**（長大 context 対応。選択条件・上限は `agents.yaml` の `kimi_model_routing` を正本とする）。目的: Claude 本体のクレジット消費を抑える（ガバナンス領域 `.claude/` `hook` 等は worker 編集不可のため従来どおり Claude が担う）。

**境界（2026-08-08）**: 見積り10分未満の小実装とガバナンス領域（`.claude/` `hook` 等の worker 編集不可領域）は Claude サブエージェント内製、大タスク・並列・大量読みは worker（判定手順は `skills/agent-dispatch` が正本）。

**三役の呼称（2026-08-09）**: 監督=PM（Claude）／参謀=Kimi 長大 context（設計・大量読み）／職人=実装 worker。調査は3段振り分け（小=監督が context-engine 直・中〜大=参謀・急ぎのみ Claude Explore）。正本: `agents.yaml` の `role_titles`／詳細: `docs/model-catalog-policy.md`「三役体制」節。

**Fable 使用条件（2026-08-11・ctx-save）**: Fable は難所（設計・承認判断／原因不明バグの診断／ガバナンス領域編集）限定。調査・大量読み・軽作業は使わない。重い調査が主目的のセッションは、セッションモデル自体を Sonnet 既定で開始する（第二弾 2026-08-11）。正本・境界の全文は `agents.yaml` の `task_routing.fable_usage_policy`（`session_model_default` 含む）を参照（複製しない）。

**調査系サブエージェント（Explore 等）へ委譲する時の規約**: `model:` に下位モデル（`sonnet` / `haiku`）を明示指定する。無指定のまま委譲すると親セッションのモデル（Fable 等）を継承し、大量読みが難所限定の原則から漏れる。

| タスク種別 | 第一候補 | 理由 |
|-----------|---------|------|
| 仕様が明確・クリーンさ重視・UI/結線・お手本コード | **GLM 5.2** | 簡潔・範囲内に収まりやすい・速い |
| 複雑・セキュリティ/堅牢性が重要なバックエンド | **Kimi K2.7 Code** | 安全性を自力で深掘り・テスト厚い |
| 巨大 context の読み込み・リポ横断調査 | **Kimi K3** | 長大 context（ルーティング条件は `agents.yaml` 正本） |
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

<!-- [2026-08-13][fix]
背景:
  - ユーザー依頼意図: 2026-08-13 に AI Worker MCP へ provider:"auto" で委譲したところ、codexbar 実測で
    glm/ocg/kimi/antigravity の4ルートが ok（残量あり）だったにも関わらず、auto ルーターが unknown 判定の
    opencode/latest ルートを選び、さらに agents.yaml の model_catalog に存在しない model_id
    （opencode-go/kimi-k3）で起動し、629秒間ハートビートゼロ・0行編集のまま沈黙死した
    （job_id 59003758-c6b7-4cb3-af0a-5470685ed4ef）。同一経路の失敗は課題 #74（empty_diff）に続く再発であり、
    根本原因は委譲前に既存ツール `get_worker_capabilities` を呼ばず auto 任せにした PM 側の運用だった。
  - 守るべき業務ルール: `plan-commitment-tracking.md` §3「AI worker 摩擦は観測＝即発火（正本修正）」。
    委譲前 preflight は既存 MCP ツールを使うだけで防げる摩擦であり、義務化しないと再発する。
  - 他案不採用理由:
    1) auto ルーター側だけを直す案は tools/ai-worker-mcp/ のコード修正が別タスク範囲であり、
       本追記は PM 側の運用義務（rule）を先に固定する目的のため不採用（別タスクで扱う）。
    2) 手順を skill 側だけに書いてルールへ書かない案は、義務が「常時ロードされるルール」に無いと
       auto 任せの再発を防げないため不採用（義務はルール、手順は skill の二段構えを維持）。
対応: 委譲前 preflight（get_worker_capabilities 必須化・unknown ルート不採用・台帳外モデル禁止・
  2分ハートビート早期見切り）を全PJ共通の義務として追記した。
-->

**委譲前 preflight を必須にする（2026-08-13）**: AI Worker MCP へ委譲する前に必ず `get_worker_capabilities`（`include_usage: true`）を呼び、`state: ok` のルートから **provider を明示指名**する。`provider: "auto"` 任せを既定にしない。

- **`unknown` を「使える」と見なさない**: 残量が `unknown` のルートは、`ok` のルートが 1 つでも存在する限り選ばない。
- **台帳に無いモデルを使わない**: `agents.yaml` の `model_catalog` に `availability: verified` として存在しない model_id では委譲しない。
- **早期見切り**: 委譲後 2 分でハートビート（最初の意味のある出力）が無ければ、stale 判定を待たずキャンセルして別ルートへ振る。
- 上記は**全 PJ 共通**の義務であり、対象 PJ を限定しない。

詳細手順（preflight の呼び出し順・2分ハートビート確認手順）は `skills/agent-dispatch/SKILL.md` を参照（本ルールは義務、skill は手順＝DRY）。

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
