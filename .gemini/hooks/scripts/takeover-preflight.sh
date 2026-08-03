#!/bin/bash
# Compatibility wrapper. Handover is the canonical preflight name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/handover-preflight.sh"
