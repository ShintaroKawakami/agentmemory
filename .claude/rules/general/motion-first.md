---
name: motion-first
description: 開発PJで動き・遷移・待つ表示を作る時は、指示が無くても Motion を最初に使い、待つ表示は一呼吸置いてから出す
paths:
  - '**/*.tsx'
  - '**/*.jsx'
  - '**/*.js'
  - '**/*.ts'
  - '**/*.vue'
  - '**/*.svelte'
  - '**/*.astro'
  - '**/*.css'
  - '**/*.blade.php'
  - '**/*.html'
---

<!-- [2026-10-11][feat] Motion を開発PJ共通の既定にする（プラン「Motion を開発PJ共通へ・知恵ふくろうを本番へ」承認）。
背景:
  - ユーザー依頼意図: 伸太郎さん 2026-10-10「指示しない限りAIがMotionを使わない。Motionを最初につかうルールは
    Dev開発PJで共通にしたい」。知恵ふくろうでは自前のCSSアニメと即時表示の「考え中」で、本人が毎回微調整していた。
  - 守るべき業務ルール: 本人は Motion・Motion+ の有料会員。dev 枠（laravel-dev / hub / mcp-server へ継承）だけに届ける。
    motion スキルは on_demand（常時 context 予算外）のまま、必要な時に正本を読む。
  - 他案不採用理由: 全体共通（SHARED_AGENTS.md）は経営・お店のPJに不要なため不採用（PR #3899 の節は撤去）。
    PJごとの記述は書き忘れが起きるため不採用。motion スキルの dev 配布は常時 context 予算を増やすため不採用。
対応: 画面系ファイルを触る時だけ読まれる条件付きルールとして dev 枠へ登録する。 -->

# アニメーションは Motion を先に使う

- 動き・遷移・待つ表示・出てくる演出を作る時は、指示が無くても Motion を最初に使う。
  手順は `~/business/AGENT-HUB/skills/motion/SKILL.md`（日本語入口 `skills/motion-ja`）を読む。
  Motion と Motion+ の公式の例に近いものがあれば、それを先に使う（Motion MCP があれば docs・examples を引く）。
- Motion で作れない時だけ、自前の CSS アニメーションや JS タイマーを使う。その場合は理由を一言添える。
- 待つ表示（「考え中」など）は、すぐ答えが出る時には見せない。人が考え込む時のように一呼吸置いてから出す。
