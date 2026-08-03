#!/bin/bash
set -euo pipefail

env_file="${AGENT_HUB_ENV_FILE:-$HOME/.config/agent-hub/.env}"
repo_dir="${AGENTMEMORY_REPO_DIR:-$HOME/mcp-servers/agentmemory}"

if [ ! -r "$env_file" ]; then
  echo "agentmemory: secret env file is not readable: $env_file" >&2
  exit 1
fi
if [ ! -x "$repo_dir/dist/cli.mjs" ]; then
  echo "agentmemory: build output is missing: $repo_dir/dist/cli.mjs" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd "$repo_dir"
exec node dist/cli.mjs --tools core --data-dir "${AGENTMEMORY_DATA_DIR:-$HOME/.agentmemory/data}"
