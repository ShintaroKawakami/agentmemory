#!/usr/bin/env bash
set -euo pipefail

# [2026-10-24][test] stop-loop-continuity.py の回帰。
# 背景: AI が見張りなしの「待ちます」・途中の一言・承認後の聞き直しで黙って止まる（伸太郎さん 2026-10-24）。
# 対応: 同梱の unittest を実行する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/stop-loop-continuity.test.py"
