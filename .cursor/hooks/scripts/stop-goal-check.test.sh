#!/usr/bin/env bash
set -euo pipefail

# [2026-10-02][test] stop-goal-check.py の回帰（#1709）。
# 背景: /compact 後の台帳証拠と §6 明示保留を Stop hook が誤って見落とす。
# 対応: 同梱の unittest を実行する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/stop-goal-check.test.py"
