# JTT scoped AgentMemory gateway

This fork adds a deliberately small MCP surface for JTT's multi-agent workflow.
The upstream AgentMemory daemon remains the storage and search engine. The JTT
gateway only enforces project binding and exposes four tools:

- `agentmemory_save`
- `agentmemory_search`
- `agentmemory_handoff_save`
- `agentmemory_handoff_get`

## Safety contract

- The project comes from the `X-AgentMemory-Project` connection header. Tools
  cannot silently replace it.
- `AGENTMEMORY_ALLOWED_PROJECTS` is a fail-closed allowlist.
- Cross-project search requires `referenceProjects` or
  `includeGlobalReference: true`; every result includes its source project.
- `agentmemory_handoff_get` reads the exact current project only and returns
  `fallbackUsed: false`. It never selects the latest session from another repo.
- `global/reference` is valid for Hermes conversations, but cannot store or
  retrieve implementation handoffs.
- This gateway does not install AgentMemory's automatic conversation hooks or
  the Hermes memory provider. Saving is explicit.
- If the central daemon is unavailable, a memory tool returns an error. It does
  not create a second local memory store. The calling agent can continue its
  normal work without memory.

## Latest project handoff lookup

`agentmemory_handoff_get` selects the latest saved handoff for the bound project,
not a particular thread. It reads stored memories without a relevance limit.
The envelope `createdAt` instant determines order; equal timestamps use memory
ID descending. Empty projects return `handoff: null` and `fallbackUsed: false`.

The authenticated upstream `GET /agentmemory/memories?handoffProject=<project>`
returns `{ "handoff": <stored memory or null> }`. The opt-in filters both the
stored row project and envelope project, requires category
`implementation_handoff`, and chooses the newest valid timestamp before list
pagination. Existing agent isolation and authentication remain in force.
The project must match the gateway canonical project syntax (1–128 lowercase
letters, digits, `.`, `_`, `/`, `-`, starting with a letter or digit), excluding
`global/reference`. Invalid input returns 400; failed authentication returns 401.
The gateway rejects legacy/unscoped or mismatched backend responses as 502.

Deploy the core and gateway build together. The query/codec module is pure;
importing it from the core must not start the standalone gateway.

## Private deployment

The AgentMemory core stays on `127.0.0.1:3111`. The JTT gateway may listen on a
private Tailscale-reachable address and forwards to the core over loopback.
It requires both a bearer secret and a project header on every MCP request.

Required environment variables:

```text
AGENTMEMORY_SECRET=<core REST bearer secret>
AGENTMEMORY_GATEWAY_SECRET=<gateway bearer secret>
AGENTMEMORY_ALLOWED_PROJECTS=agent-hub,global/reference
AGENTMEMORY_GATEWAY_HOST=0.0.0.0
AGENTMEMORY_GATEWAY_PORT=3121
AGENTMEMORY_UPSTREAM_URL=http://127.0.0.1:3111
```

Keep real values in the machine's secret store. Do not commit them.

Build and start:

```text
npm install --omit=optional
npm run build
npm start
npm run start:jtt-gateway
```

`--omit=optional` keeps local image/embedding native packages out of this
BM25-first pilot. The fork pins the MCP SDK to an exact version.

## Client headers

Each project connection supplies:

```text
Authorization: Bearer <AGENTMEMORY_GATEWAY_SECRET>
X-AgentMemory-Project: agent-hub
X-AgentMemory-Agent: claude-code
```

Hermes' ordinary conversation connection uses
`X-AgentMemory-Project: global/reference`. When a conversation becomes an
implementation task, Hermes must use a separately project-bound connection;
if no canonical project is known, handoff saving stops with an error.

## Internet exposure

The private bearer gateway is not the Claude.ai endpoint. Do not put it behind
a public tunnel. Claude.ai requires a separate standards-based OAuth 2.1 + DCR
front door whose token is bound to an allowed project scope.
