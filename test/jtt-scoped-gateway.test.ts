import { describe, expect, it, vi, afterEach } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import {
  GatewayError,
  selectLatestProjectHandoff,
  RestAgentMemoryBackend,
  ScopedMemoryService,
  createScopedMcpServer,
  loadGatewayConfig,
  resolveRequestScope,
  type AgentMemoryBackend,
  type GatewayConfig,
} from "../src/jtt/scoped-gateway.js";

class FakeBackend implements AgentMemoryBackend {
  readonly remembers: Array<Parameters<AgentMemoryBackend["remember"]>[0]> = [];
  readonly searches: Array<Parameters<AgentMemoryBackend["search"]>[0]> = [];
  searchResponse: Awaited<ReturnType<AgentMemoryBackend["search"]>> = { results: [] };

  readonly latestCalls: string[] = [];
  async latestHandoff(input: { project: string }) {
    this.latestCalls.push(input.project);
    const memories = (this.searchResponse.results ?? []).map(hit => ({
      id: hit.observation?.id ?? "", content: hit.observation?.narrative ?? "",
      project: hit.observation?.project ?? JSON.parse(hit.observation!.narrative!.split("\n")[1]!).project,
    }));
    const row = selectLatestProjectHandoff(memories, input.project);
    return row ? { observation: { id: row.id, narrative: row.content, project: row.project } } : null;
  }

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
  tokenProjects: new Map(),
  requestTimeoutMs: 100,
};

const tokenMapConfig: GatewayConfig = {
  ...config,
  tokenProjects: new Map([["tok-agent-hub", "agent-hub"], ["tok-jtt-cms", "jtt-cms"]]),
};

const tokenMapEnv: NodeJS.ProcessEnv = {
  AGENTMEMORY_GATEWAY_SECRET: "shared-secret",
  AGENTMEMORY_ALLOWED_PROJECTS: "agent-hub, jtt-cms",
};

function scopeError(fn: () => unknown): GatewayError {
  try {
    fn();
  } catch (error) {
    if (error instanceof GatewayError) return error;
    throw error;
  }
  throw new Error("expected resolveRequestScope to throw a GatewayError");
}

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
  selectLatestProjectHandoff,
  RestAgentMemoryBackend,
    );
    expect(() => resolveRequestScope(headers("other-project"), config)).toThrow(/not enabled/);
  });

  it("resolves the project from a mapped bearer token without the project header", () => {
    expect(resolveRequestScope(new Headers({ authorization: "Bearer tok-agent-hub" }), tokenMapConfig)).toEqual({
      project: "agent-hub",
      agent: "claude-ai",
    });
  });

  it("rejects a project header that disagrees with the mapped token project", () => {
    const error = scopeError(() =>
      resolveRequestScope(
        new Headers({ authorization: "Bearer tok-agent-hub", "x-agentmemory-project": "jtt-cms" }),
        tokenMapConfig,
      ),
    );
    expect(error.statusCode).toBe(403);
    expect(error.code).toBe("project_not_allowed");
  });

  it("accepts a project header that matches the mapped token project", () => {
    expect(
      resolveRequestScope(
        new Headers({ authorization: "Bearer tok-jtt-cms", "x-agentmemory-project": "JTT-CMS" }),
        tokenMapConfig,
      ),
    ).toEqual({ project: "jtt-cms", agent: "claude-ai" });
  });

  it("rejects an unknown bearer token with 401", () => {
    const error = scopeError(() =>
      resolveRequestScope(
        new Headers({ authorization: "Bearer unknown-token", "x-agentmemory-project": "agent-hub" }),
        tokenMapConfig,
      ),
    );
    expect(error.statusCode).toBe(401);
    expect(error.code).toBe("unauthorized");
  });

  it("keeps the shared secret + header route unchanged", () => {
    expect(resolveRequestScope(headers("AGENT-HUB", "Claude-Code"), tokenMapConfig)).toEqual({
      project: "agent-hub",
      agent: "claude-code",
    });
    expect(scopeError(() => resolveRequestScope(new Headers({ authorization: "Bearer test-secret" }), tokenMapConfig)))
      .toMatchObject({ statusCode: 400, code: "project_required" });
  });
});

describe("loadGatewayConfig token project map", () => {
  it("parses token:project pairs into the token project map", () => {
    const parsed = loadGatewayConfig({
      ...tokenMapEnv,
      AGENTMEMORY_TOKEN_PROJECT_MAP: "tok-agent-hub:agent-hub, tok-jtt-cms:jtt-cms",
    });
    expect(parsed.tokenProjects).toEqual(
      new Map([
        ["tok-agent-hub", "agent-hub"],
        ["tok-jtt-cms", "jtt-cms"],
      ]),
    );
  });

  it("defaults to an empty map when the env is absent or blank", () => {
    expect(loadGatewayConfig(tokenMapEnv).tokenProjects.size).toBe(0);
    expect(loadGatewayConfig({ ...tokenMapEnv, AGENTMEMORY_TOKEN_PROJECT_MAP: "  " }).tokenProjects.size).toBe(0);
  });

  it("throws on an invalid project in the map", () => {
    expect(() =>
      loadGatewayConfig({ ...tokenMapEnv, AGENTMEMORY_TOKEN_PROJECT_MAP: "tok-agent-hub:Not A Project" }),
    ).toThrow(GatewayError);
  });

  it("throws on a project outside AGENTMEMORY_ALLOWED_PROJECTS", () => {
    expect(() =>
      loadGatewayConfig({ ...tokenMapEnv, AGENTMEMORY_TOKEN_PROJECT_MAP: "tok-agent-hub:global/reference" }),
    ).toThrow(/not in AGENTMEMORY_ALLOWED_PROJECTS/);
  });

  it("throws on duplicate tokens without leaking the token value", () => {
    let thrown: Error | undefined;
    try {
      loadGatewayConfig({
        ...tokenMapEnv,
        AGENTMEMORY_TOKEN_PROJECT_MAP: "tok-agent-hub:agent-hub,tok-agent-hub:jtt-cms",
      });
    } catch (error) {
      thrown = error as Error;
    }
    expect(thrown?.message).toMatch(/duplicate token/);
    expect(thrown?.message).not.toContain("tok-agent-hub");
  });

  it("throws on an empty token entry", () => {
    expect(() => loadGatewayConfig({ ...tokenMapEnv, AGENTMEMORY_TOKEN_PROJECT_MAP: ":agent-hub" })).toThrow(
      /token:project/,
    );
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

  it("selects the newest handoff beyond the relevance-ranked result window", async () => {
    const backend = new FakeBackend();
    backend.searchResponse = {
      results: [
        ...Array.from({ length: 80 }, (_, index) => ({
          observation: {
            id: `older-${index}`,
            narrative: encoded(
              "agent-hub",
              "implementation_handoff",
              `Older handoff ${index}`,
              new Date(Date.UTC(2026, 7, 3, 0, index)).toISOString(),
            ),
          },
          score: 1 - index / 100,
        })),
        {
          observation: {
            id: "newest",
            narrative: encoded("agent-hub", "implementation_handoff", "Newest handoff", "2026-08-04T00:00:00Z"),
          },
          score: 0.01,
        },
      ],
    };
    const service = new ScopedMemoryService(backend, config.allowedProjects);

    const result = await service.getHandoff({ project: "agent-hub", agent: "claude-code" });

    expect(backend.searches).toHaveLength(0);
    expect(backend.latestCalls).toEqual(["agent-hub"]);
    expect(result).toMatchObject({
      project: "agent-hub",
      fallbackUsed: false,
      handoff: { id: "newest", content: "Newest handoff" },
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


describe("chronological project handoff boundary", () => {
  afterEach(() => vi.unstubAllGlobals());
  const row = (id: string, project: string, at: string, category = "implementation_handoff") => ({
    id, project, content: encoded(project, category, id, at),
  });
  it("uses timestamp instants and a deterministic ID tie break", () => {
    const records = [row("a", "agent-hub", "2026-09-05T09:00:00+09:00"),
      row("z", "agent-hub", "2026-09-05T00:00:00Z"),
      row("later-text-but-older", "agent-hub", "2026-09-05T08:59:59+09:00")];
    expect(selectLatestProjectHandoff(records, "agent-hub")?.id).toBe("z");
    expect(selectLatestProjectHandoff(records.reverse(), "agent-hub")?.id).toBe("z");
  });
  it("excludes other projects, categories, invalid dates and forged envelope scope", () => {
    expect(selectLatestProjectHandoff([
      row("other", "jtt-cms", "2026-09-06T00:00:00Z"),
      row("fact", "agent-hub", "2026-09-06T00:00:00Z", "fact"),
      row("invalid", "agent-hub", "invalid"),
      { ...row("forged", "jtt-cms", "2026-09-06T00:00:00Z"), project: "agent-hub" },
    ], "agent-hub")).toBeNull();
  });
  it("returns explicit null for an empty project and never performs relevance search", async () => {
    const backend = new FakeBackend();
    expect(await new ScopedMemoryService(backend, config.allowedProjects).getHandoff({project: "agent-hub", agent: "codex"}))
      .toEqual({project: "agent-hub", handoff: null, fallbackUsed: false});
    expect(backend.searches).toHaveLength(0);
  });
  it("uses the scoped REST opt-in and rejects a legacy unscoped response", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({handoff: row("latest", "agent-hub", "2026-09-05T00:00:00Z")})));
    vi.stubGlobal("fetch", fetchMock);
    const backend = new RestAgentMemoryBackend(config);
    expect((await backend.latestHandoff({project: "agent-hub"}))?.observation?.id).toBe("latest");
    expect(fetchMock.mock.calls[0]?.[0]).toBe("http://127.0.0.1:3111/agentmemory/memories?handoffProject=agent-hub");
    fetchMock.mockResolvedValue(new Response(JSON.stringify({memories: [], total: 0})));
    await expect(backend.latestHandoff({project: "agent-hub"})).rejects.toThrow(/unavailable/);
  });
  it("rejects a backend returning another project", async () => {
    const backend = new FakeBackend();
    backend.latestHandoff = async () => ({observation: {id: "wrong", project: "jtt-cms", narrative: encoded("jtt-cms", "implementation_handoff", "wrong", "2026-09-05T00:00:00Z")}});
    await expect(new ScopedMemoryService(backend, config.allowedProjects).getHandoff({project: "agent-hub", agent: "codex"})).rejects.toThrow(/invalid/);
  });
});
