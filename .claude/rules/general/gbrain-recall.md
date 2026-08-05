<!-- [2026-08-04][feat] G-Brain ハーネス Phase 1（gbrain-recall rule 新設）
背景:
  - ユーザー依頼意図: 承認済み仕様書「G-Brain ハーネス設計仕様書（v2）」D6（リコール層）に基づき、
    バグ修正・障害調査・経営相談・戦略検討などの**通常の会話**でも、AI が能動的に G-Brain
    （shintaro-gbrain / tech-gbrain）や agentmemory を検索しに行く発火条件を明文化したい。
    従来は plan 入口の preflight（plan-commitment-registry seq 0.1/0.15）・保存先の3層判断
    （agentmemory-routing）・closeout 時の候補提示（handover-manual）はあったが、非 plan の
    日常会話で「読みに行く」入口が欠けていた（仕様書 D9 の役割分担精査で確認済みの穴）。
  - 守るべき業務ルール: 本ルールは仕様書 D9 の役割分担表に厳密に従い、非 plan の日常会話における
    「読む側」の発火条件だけを担当する。plan 入口 preflight・保存先の3層判断・put_page の安全手順・
    closeout 候補提示は、それぞれの既存正本（下記 §0 参照）を複製しない（reference-over-hardcode）。
  - 他案不採用理由:
    1) 発火条件を dev-guardrails / business-guardrails 等の各スキルへ個別に埋め込む案は、条件表が
       複数ファイルに分散し改訂のたび全部を直す必要が生じるため不採用（本ルールへ集約し各スキルは
       1行参照に留める）。
    2) global CLAUDE.md（`~/.claude/CLAUDE.md`）に置く案は Claude Code 専用で Codex / Cursor / Kimi /
       Antigravity へ届かないため不採用（D6 記載のとおり）。AGENT-HUB rule + manifest 配布が
       全クライアントに届く唯一の経路。
対応: `.claude/rules/general/gbrain-recall.md` を新設。常時ロード（`registries/always-load-rules.yaml`
  へ理由付き登録）とし、manifest v2 global 層（`registries/harness-manifest.yaml`）から全クライアントへ
  配布する。
-->

# G-Brain リコール層（会話中の「読む側」発火条件）

## 0. scope 宣言（重複防止・複製しない）

本ルールは **非 plan の日常会話における「読む側」の発火条件だけ** を定義する。以下は別の正本が担当し、
本ルールでは内容を複製しない（G-Brain ハーネス設計仕様書 D9 役割分担表）:

| 責務 | 正本（変更しない・本ルールは複製しない） |
|------|------|
| plan 入口の preflight（読む） | `skills/plan-approval/plan-commitment-registry.yaml` seq 0.1 / 0.15 |
| 保存先の3層判断（書く） | `skills/agentmemory-routing/SKILL.md` + `agent-memory/registry/placement-policy.md` |
| put_page の安全手順・承認ゲート・合図式保存 | `skills/shintaro-gbrain/SKILL.md` |
| closeout 時の GBrain 候補承認キュー | `skills/handover-manual/SKILL.md`（合図式＝会話中の即時承認、closeout＝session 末の候補提示で別物） |
| auto-memory の参照 | `.claude/rules/general/memory-lookups.md`（相互参照のみ、内容は複製しない） |
| 敵対的レビュー手順（business） | `skills/adversarial-review/references/business-review.md` |

## 1. 発火条件表

会話の中でユーザー発話や作業内容が次のいずれかに該当したら、応答を出す前に該当 brain を検索する。

| 発話・作業の性質 | 検索する先 | 例 |
|---|---|---|
| バグ修正・障害調査・回帰の原因特定 | `tech-gbrain`（`mcp__tech-gbrain__search` / `recall`） | 「〇〇が直らない」「なぜこのエラーが出るか」「前も似た不具合あったはず」 |
| 経営相談・戦略・クレーム対応・売上・オペレーション改善 | `shintaro-gbrain`（`mcp__shintaro-gbrain__search` / `recall`） | 「この施策どう思う」「クレームにどう対応すべきか」「オペレーションを改善したい」 |
| 作業再開・引き継ぎ・「あの続き」 | `agentmemory`（continuation） | 「〇〇の続き」「前回どこまでやったか」 |

判断に迷う場合は検索する側に倒す（誤爆コストは低く、未検索コストは高い）。

## 2. 検索実行の判断はモデル側に残す

本ルールは「検索しに行くべきタイミング」を定義するだけで、検索実行を強制する hook ではない。
`hook-library` の UserPromptSubmit hook（`gbrain-recall-preflight`）は軽量キーワード検知による
短いリマインドだけを担い、実際に検索するかどうかの判断はモデル自身が行う（仕様書 D6）。

## 3. 関連

- 手順・落とし穴の詳細: `skills/shintaro-gbrain/SKILL.md`
- 保存先判断の詳細: `skills/agentmemory-routing/SKILL.md`
- 仕様書: `claude-plans/2026-08-04-jtt-gbrain-harness-spec.md`（D6 / D9）
