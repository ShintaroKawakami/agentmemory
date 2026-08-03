#!/bin/bash
set -euo pipefail

env_file="${AGENT_HUB_ENV_FILE:-$HOME/.config/agent-hub/.env}"
repo_dir="${AGENTMEMORY_REPO_DIR:-$HOME/mcp-servers/agentmemory}"

if [ ! -r "$env_file" ]; then
  echo "agentmemory gateway: secret env file is not readable: $env_file" >&2
  exit 1
fi
if [ ! -x "$repo_dir/dist/jtt/scoped-gateway.mjs" ]; then
  echo "agentmemory gateway: build output is missing: $repo_dir/dist/jtt/scoped-gateway.mjs" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

export AGENTMEMORY_UPSTREAM_URL="${AGENTMEMORY_UPSTREAM_URL:-http://127.0.0.1:3111}"
cd "$repo_dir"
node_bin="$(command -v node 2>/dev/null || true)"
if [ -z "$node_bin" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.local/bin/node"; do
    if [ -x "$candidate" ]; then
      node_bin="$candidate"
      break
    fi
  done
fi
if [ -z "$node_bin" ]; then
  echo "agentmemory gateway: node binary not found" >&2
  exit 127
fi
exec "$node_bin" dist/jtt/scoped-gateway.mjs
