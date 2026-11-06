#!/usr/bin/env bash
set -euo pipefail

# [2026-11-02][test] stop-explain-check.py の回帰。
# 背景: 説明の依頼に検品済みページの URL を付けず返す抜け道を Stop hook で1回だけ止める
#   （伸太郎さん 2026-11-02「言われないと動かないのはあってはならない」）。
# 対応: 同梱の unittest を実行する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/stop-explain-check.test.py"
