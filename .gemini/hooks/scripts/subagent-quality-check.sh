#!/bin/bash

# [2026-03-03][refactor]
# 背景: hook-libraryコンポーネント化。薄いラッパーでlib/の共通ロジックを呼び出す。
# 対応: SubagentStop → lib/quality-check-common.sh の run_quality_check_hook を呼出。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/quality-check-common.sh"

run_quality_check_hook \
  "subagent-quality-check" \
  "$SCRIPT_DIR/.." \
  "No file changes detected - research/planning agent, skipping quality check." \
  "false"
