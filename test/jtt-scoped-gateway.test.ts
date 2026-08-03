import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import {
  GatewayError,
  ScopedMemoryService,
  createScopedMcpServer,
  resolveRequestScope,
  type AgentMemoryBackend,
  type GatewayConfig,
} from "../src/jtt/scoped-gateway.js";

class FakeBackend implements AgentMemoryBackend {
  readonly remembers: Array<Parameters<AgentMemoryBackend["remember"]>[0]> = [];
  readonly searches: Array<Parameters<AgentMemoryBackend["search"]>[0]> = [];
  searchResponse: Awaited<ReturnType<AgentMemoryBackend["search"]>> = { results: [] };

  async remember(input: Parameters<AgentMemoryBackend["remember"]>[0]): Promise<unknown> {
    this.remembers.push(input);
    return { success: true, memory: { id: `mem-${this.remembers.length}` } };
  }

  async search(input: Parameters<AgentMemoryBackend["search"]>[0]) {
    this.searches.push(input);
    return this.searchResponse;
  }
}

const config: GatewayConfig = {
  host: "127.0.0.1",
  port: 3121,
  gatewaySecret: "test-secret",
  upstreamUrl: "http://127.0.0.1:3111",
  allowedProjects: new Set(["agent-hub", "jtt-cms", "global/reference"]),
  requestTimeoutMs: 100,
};

function headers(project: string, agent = "hermes"): Headers {
  return new Headers({
    authorization: "Bearer test-secret",
    "x-agentmemory-project": project,
    "x-agentmemory-agent": agent,
  });
}

function encoded(project: string, category: string, content: string, createdAt: string): string {
  return `JTT_AGENTMEMORY ${category} ${project}\n${JSON.stringify({
    schema: "jtt-agentmemory/v1",
    project,
    category,
    sourceAgent: "hermes",
    content,
    files: [],
    createdAt,
    ...(category === "implementation_handoff"
      ? { handoff: { summary: content, nextStep: "continue", openQuestions: [] } }
      : {}),
  })}`;
}

describe("resolveRequestScope", () => {
  it("binds the request to an allowlisted canonical project", () => {
    expect(resolveRequestScope(headers("AGENT-HUB", "Claude-Code"), config)).toEqual({
      project: "agent-hub",
      agent: "claude-code",
    });
  });

  it("rejects missing auth and unknown projects", () => {
    expect(() => resolveRequestScope(new Headers({ "x-agentmemory-project": "agent-hub" }), config)).toThrow(
      GatewayError,
    );
    expect(() => resolveRequestScope(headers("other-project"), config)).toThrow(/not enabled/);
  });
});

describe("ScopedMemoryService", () => {
  it("always writes the connection-bound project", async () => {
    const backend = new FakeBackend();
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    await service.save(
      { project: "agent-hub", agent: "codex" },
      { content: "Use manifest v2", category: "decision", files: ["registries/harness-manifest.yaml"] },
    );
    expect(backend.remembers).toHaveLength(1);
    expect(backend.remembers[0]?.project).toBe("agent-hub");
    expect(backend.remembers[0]?.content).toContain('"project":"agent-hub"');
  });

  it("refuses a handoff from the global Hermes reference scope", async () => {
    const service = new ScopedMemoryService(new FakeBackend(), config.allowedProjects);
    await expect(
      service.saveHandoff(
        { project: "global/reference", agent: "hermes" },
        { summary: "Discussed an idea", nextStep: "Choose a project" },
      ),
    ).rejects.toMatchObject({ code: "handoff_project_required" });
  });

  it("searches other projects only when explicitly requested and labels every result", async () => {
    const backend = new FakeBackend();
    backend.searchResponse = {
      results: [
        {
          observation: {
            id: "mem-1",
            narrative: encoded("jtt-cms", "reference", "Coupon flow", "2026-08-03T00:00:00Z"),
          },
          score: 0.8,
        },
      ],
    };
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const result = await service.search(
      { project: "agent-hub", agent: "codex" },
      { query: "coupon", limit: 5, referenceProjects: ["jtt-cms"] },
    );
    expect(backend.searches.map((call) => call.project)).toEqual(["agent-hub", "jtt-cms"]);
    expect(result.results).toEqual([
      expect.objectContaining({ project: "jtt-cms", source: "explicit_reference" }),
    ]);
  });

  it("never falls back to another project's handoff", async () => {
    const backend = new FakeBackend();
    backend.searchResponse = {
      results: [
        {
          observation: {
            id: "wrong",
            narrative: encoded("jtt-cms", "implementation_handoff", "Wrong project", "2026-08-03T02:00:00Z"),
          },
          score: 1,
        },
        {
          observation: {
            id: "right",
            narrative: encoded("agent-hub", "implementation_handoff", "Right project", "2026-08-03T01:00:00Z"),
          },
          score: 0.9,
        },
        {
          observation: {
            id: "newest",
            narrative: encoded("agent-hub", "implementation_handoff", "Newest project handoff", "2026-08-03T03:00:00Z"),
          },
          score: 0.1,
        },
      ],
    };
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const result = await service.getHandoff({ project: "agent-hub", agent: "claude-code" });
    expect(result).toMatchObject({
      project: "agent-hub",
      fallbackUsed: false,
      handoff: { project: "agent-hub", content: "Newest project handoff" },
    });
  });
});

describe("JTT scoped MCP surface", () => {
  it("initializes, lists only the four safe tools, and performs a scoped save", async () => {
    const backend = new FakeBackend();
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const server = createScopedMcpServer(service, { project: "agent-hub", agent: "codex" });
    const client = new Client({ name: "test-client", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    try {
      const tools = await client.listTools();
      expect(tools.tools.map((tool) => tool.name)).toEqual([
        "agentmemory_save",
        "agentmemory_search",
        "agentmemory_handoff_save",
        "agentmemory_handoff_get",
      ]);
      const saved = await client.callTool({
        name: "agentmemory_save",
        arguments: { content: "Manifest v2 is the distribution SSOT", category: "decision" },
      });
      expect(saved.isError).not.toBe(true);
      expect(backend.remembers[0]?.project).toBe("agent-hub");
    } finally {
      await client.close();
      await server.close();
    }
  });
});
