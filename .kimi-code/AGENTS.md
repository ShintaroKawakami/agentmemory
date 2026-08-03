# agentmemory Kimi Code CLI Runtime

このファイルは `sync-kimi-from-cc.py` が生成する Kimi Code CLI 用の補助 instruction です。
手編集せず、Claude Code 側の正本を更新してから再同期してください。

## 正本

- ルールの正本はルートの `AGENTS.md` / `CLAUDE.md` / `.claude/rules/` です。
- Kimi はプロジェクトの `AGENTS.md` も読むため、ここでは Kimi 固有の差分だけを補足します。
- 旧 `.kimi/agent.yaml` / `.kimi/agents/` は使いません。

## 起動

- 通常起動: `kimi`
- 自動承認: `kimi --yolo`
- 計画モード: `kimi --plan`
- 直近セッション再開: `kimi --continue`
- セッション選択: `kimi --session`

`default_thinking = true` を `~/.kimi-code/config.toml` で管理します。Thinking 用 CLI flag は現在の
Kimi Code CLI help に出ていないため、起動案内には使いません。
`--continue` / `--session` は `--plan` / `--yolo` と併用しません。

## Hook と Sub-Agent

- block 可能な hook は `PreToolUse` / `UserPromptSubmit` / `Stop` だけです。
- 観測系 event では重い処理を走らせません。
- 旧 `PostToolUse` 系の整形・表示・同期ガードは Kimi では未強制です。
  未変換 hook 名は `.kimi-code/sync-state.json` の `warnings` に列挙されます。
- Sub-agent は Kimi 内蔵の `coder` / `explore` / `plan` を使います。
- Claude の `.claude/agents/*.md` は Kimi 独自 YAML へ変換しません。必要な知識は Skill か本 instruction へ寄せます。
