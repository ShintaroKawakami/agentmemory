<!-- [2026-08-28][feat]
背景:
  - ユーザー依頼意図: G-Brain を含む各 tool が、初期一覧に見えないだけで OFF と誤判定される再発を止め、全 PJ / 全 client で同じ判断にする。
  - 守るべき業務ルール: SSOT・registry・選択状態・生成面・runtime 実測を分離し、確認できた証拠だけで status を決める。未確認は `UNPROVEN` のままにし、hook は探索や MCP 呼出しをしない。
  - 他案不採用理由:
    1) 初期 catalog の欠落だけを OFF とみなす案は、遅延 catalog や別 scope の選択を見落とすため不採用。
    2) hook が自動で catalog / MCP を探索する案は、client 差と誤爆時の副作用を正本から追えず、既存の案内専用境界を壊すため不採用。
対応: 4 状態と証拠順を共通 rule に集約し、既存 resolver / generator / merge gate の軽量検査で投影と重複を検出する。
-->

<!-- agents-md-card:start -->
### CARD: tool-availability-resolution — Tool availability 解決ルール（共通）
- **いつ**: tool の可用性を判断するとき、または利用できない理由を説明するとき
- **何を**: 初期 catalog → 遅延 catalog → 選択状態 → runtime 実測の順で証拠を確認し、4状態へ分類する
- **できた状態**: `AVAILABLE` / `NOT_SELECTED` / `RUNTIME_UNAVAILABLE` / `UNPROVEN` と根拠が明示され、初期一覧の欠落だけで `OFF` と断定していない
- **詳細**: `.claude/rules/general/tool-availability-resolution.md`
<!-- agents-md-card:end -->

# Tool availability 解決ルール（共通）

tool の可用性は、現在のセッションで確認できた証拠だけで判定する。初期 tool 一覧に無いだけでは `OFF` と判定しない。未確認は未確認のまま扱い、名前や設定から補わない。

## 証拠を確認する順序

次の順で、同じ tool の証拠を確認する。

1. **セッション catalog**: 現在の会話の tool catalog に、対象 tool と callable な操作が明示されているかを見る。
2. **遅延 catalog**: 初期一覧に無い場合は、利用可能な遅延 catalog（Codex の `ALL_TOOLS` / `tool_search`、他 client の同等機能など）を確認する。hook 自身は探索しない。
3. **選択状態**: manifest・client 設定・MCP パネルなどに、現在の project / session へ選択済みか、別 scope で登録済みかの明示があるかを見る。
4. **runtime 実測**: 選択済みの証拠がある場合だけ、health または対象操作の実行結果で runtime が応答するかを見る。失敗を繰り返すための自動 retry はしない。
5. **結論**: 下表の status と、根拠にした証拠を一緒に記録する。証拠が競合する場合は強い証拠を優先し、不足は `UNPROVEN` に下げる。

| status | この status にできる証拠 | 扱い |
|---|---|---|
| `AVAILABLE` | 現在のセッション catalog に callable な tool が明示されている | 通常どおり呼び出せる。必要なら一度実行して結果を確認する |
| `NOT_SELECTED` | tool の登録・存在は確認できるが、現在の project / session へ選択されていないことが明示されている | 選択を案内する。runtime unavailable とは言わない |
| `RUNTIME_UNAVAILABLE` | 選択済みの証拠があり、health または対象操作の live 実測が unavailable / 接続失敗になった | 復旧を案内して停止する。推測で代替しない |
| `UNPROVEN` | catalog の欠落だけ、古い設定だけ、または必要な証拠が不足している | ON / OFF を断定しない。追加の証拠が得られるまで未確認と表示する |

`AVAILABLE` は「登録されている」だけでは足りず、現在のセッションで callable である証拠を要する。反対に、初期 catalog の欠落は `UNPROVEN` であり、`NOT_SELECTED` や `RUNTIME_UNAVAILABLE` へ短絡しない。

選択済みの証拠がある tool で runtime 実測が失敗した場合は、catalog に名前が残っていても `RUNTIME_UNAVAILABLE` を優先する。明示的な選択状態も runtime 実測も無い場合は `UNPROVEN` とする。

## 自動処理の境界

このルールは判定の読み手向けであり、hook が catalog を探索したり MCP tool を呼び出したりすることを認めない。hook は、確認すべき証拠と status を短く案内するだけにする。実際の catalog 確認・選択確認・runtime 実測はモデルまたは利用者が適切な画面・道具で行う。

## G-Brainの共通入口と必要source

本人の会話・開発は `my-gbrain` を共通入口にする。必要なsourceは `.claude/rules/general/gbrain-recall.md`、接続・source指定と未配布環境のlegacy readは `.claude/skills/agentmemory-routing/SKILL.md`（HUB正本: `skills/agentmemory-routing/SKILL.md`） に従う。
旧 `shintaro-gbrain` と `tech-gbrain` の2接続が同時に `AVAILABLE` であることを条件にしない。

My GBrainが `AVAILABLE` でも、必要sourceの読取許可や実取得を確認済みとは限らない。
`whoami` の認可範囲、必要sourceを指定した読取結果、返却sourceを確認する。
必要sourceが未許可・未取得ならその不足を明示し、検索済みと記録しない。
My GBrainが `RUNTIME_UNAVAILABLE` なら復旧を案内する。`NOT_SELECTED` / `UNPROVEN` の場合は、既存の許可済み読取経路の証拠を確認する。

会社source `jtt-gbrain` の取得不足で、取得済みの判断軸・技術の確認まで止めない。
ただし会社の事実が必要な判断は、根拠不足を明示し推測で補わない。読取許可をwrite許可と解釈しない。
