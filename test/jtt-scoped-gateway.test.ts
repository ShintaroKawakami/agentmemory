import { selectLatestProjectHandoff } from "../src/jtt/stored-envelope.js";
import { describe, expect, it, vi, afterEach } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import {
  GatewayError,
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
  dayRows = new Map<string, Awaited<ReturnType<AgentMemoryBackend["dayMemories"]>>["memories"]>();
  dayFailures = new Set<string>();

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

  async dayMemories(input: Parameters<AgentMemoryBackend["dayMemories"]>[0]) {
    if (this.dayFailures.has(input.project)) throw new Error("private backend detail");
    const all = this.dayRows.get(input.project) ?? [];
    const unknownEventCount = input.timeBasis === "event_at" ? all.filter((row) => row.event_at === null).length : 0;
    const start = Date.parse(input.startAt);
    const end = Date.parse(input.endAt);
    const rows = all.filter((row) => {
      const timestamp = Date.parse(input.timeBasis === "saved_at" ? row.saved_at : row.event_at ?? "");
      return Number.isFinite(timestamp) && timestamp >= start && timestamp < end;
    });
    return { memories: rows.slice(input.offset, input.offset + input.limit), total: rows.length, unknownEventCount };
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

function dayRow(id: string, project: string, savedAt: string, eventAt: string | null = null, metadata: Record<string, unknown> = {}) {
  return { id, project, content: `JTT_AGENTMEMORY fact ${project}\n${JSON.stringify({ schema: "jtt-agentmemory/v1", project, category: "fact", sourceAgent: "codex", content: id, files: [], createdAt: "2020-01-01T00:00:00.000Z", ...metadata, ...(eventAt ? { event_at: eventAt } : {}) })}`, saved_at: savedAt, event_at: eventAt, category: "fact" };
}

describe("resolveRequestScope", () => {
  it("binds the request to an allowlisted canonical project", () => {
    expect(resolveRequestScope(headers("AGENT-HUB", "Claude-Code"), config)).toEqual({
      project: "agent-hub",
      agent: "claude-code",
      readableProjects: new Set(config.allowedProjects),
    });
  });

  it("rejects missing auth and unknown projects", () => {
    expect(() => resolveRequestScope(new Headers({ "x-agentmemory-project": "agent-hub" }), config)).toThrow(
      GatewayError,
    );
    expect(() => resolveRequestScope(headers("other-project"), config)).toThrow(/not enabled/);
  });

  it("resolves the project from a mapped bearer token without the project header", () => {
    expect(resolveRequestScope(new Headers({ authorization: "Bearer tok-agent-hub" }), tokenMapConfig)).toEqual({
      project: "agent-hub",
      agent: "claude-ai",
      readableProjects: new Set(["agent-hub"]),
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
    ).toEqual({ project: "jtt-cms", agent: "claude-ai", readableProjects: new Set(["jtt-cms"]) });
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
      readableProjects: new Set(tokenMapConfig.allowedProjects),
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
  it("initializes, lists only the scoped tools, and performs a scoped save", async () => {
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
        "agentmemory_day",
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

  it("routes Save project memory implementation_handoff into handoff storage without category downgrade", async () => {
    const backend = new FakeBackend();
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const result = await service.save(
      { project: "agent-hub", agent: "chatgpt-business" },
      {
        content: "summary: manga prompt bookbind\nnextStep: merge PRs and deploy gateway",
        category: "implementation_handoff",
        files: ["運用/ツール/chatgpt-instructions/manga-manual.md"],
      },
    );
    expect(result.success).toBe(true);
    expect(result.project).toBe("agent-hub");
    expect(result.handoff).toMatchObject({
      summary: "manga prompt bookbind",
      nextStep: "merge PRs and deploy gateway",
    });
    expect(backend.remembers).toHaveLength(1);
    expect(backend.remembers[0]?.concepts).toContain("implementation_handoff");
    expect(backend.remembers[0]?.content).toContain('"category":"implementation_handoff"');
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

describe("agentmemory_day", () => {
  afterEach(() => vi.unstubAllGlobals());
  it("aggregates authorized projects and paginates after a stable global sort", async () => {
    const backend = new FakeBackend();
    backend.dayRows.set("agent-hub", [dayRow("hub", "agent-hub", "2026-10-09T15:00:00.000Z")]);
    backend.dayRows.set("jtt-cms", [dayRow("cms-a", "jtt-cms", "2026-10-09T15:00:00.000Z"), dayRow("cms-b", "jtt-cms", "2026-10-09T16:00:00.000Z")]);
    backend.dayRows.set("global/reference", [dayRow("private", "global/reference", "2026-10-09T17:00:00.000Z")]);
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const result = await service.day({ project: "agent-hub", agent: "codex", readableProjects: config.allowedProjects }, { start_date: "2026-10-10", limit: 2 });
    expect(result).toMatchObject({ total: 4, offset: 0, limit: 2, has_more: true, next_offset: 2, target_project_count: 3, range: { start: "2026-10-10", end: "2026-10-11", timezone: "Asia/Tokyo" } });
    expect((result.results as Array<{id: string}>).map((row) => row.id)).toEqual(["hub", "cms-a"]);
  });

  it("limits mapped tokens and scopes without readableProjects to the current project", async () => {
    const backend = new FakeBackend();
    backend.dayRows.set("agent-hub", [dayRow("hub", "agent-hub", "2026-10-09T15:00:00.000Z")]);
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const mapped = resolveRequestScope(new Headers({ authorization: "Bearer tok-agent-hub" }), tokenMapConfig);
    expect((await service.day(mapped, { start_date: "2026-10-10" })).searched_projects).toEqual(["agent-hub"]);
    expect((await service.day({ project: "agent-hub", agent: "codex" }, { start_date: "2026-10-10" })).searched_projects).toEqual(["agent-hub"]);
    expect(scopeError(() => resolveRequestScope(new Headers({ authorization: "Bearer unknown-token" }), tokenMapConfig))).toMatchObject({ statusCode: 401, code: "unauthorized" });
  });

  it("keeps non-pj domain unknown unless an explicit domain is stored", async () => {
    const backend = new FakeBackend();
    backend.dayRows.set("non-pj", [
      dayRow("explicit", "non-pj", "2026-10-09T15:00:00.000Z", null, { metadata: { domain: "work", status: "planned" } }),
      dayRow("inferred", "non-pj", "2026-10-09T16:00:00.000Z"),
      dayRow("explicit-private", "non-pj", "2026-10-09T17:00:00.000Z", null, { metadata: { domain: "private" } }),
    ]);
    const allowed = new Set([...config.allowedProjects, "non-pj"]);
    const result = await new ScopedMemoryService(backend, allowed).day({ project: "non-pj", agent: "codex", readableProjects: new Set(["non-pj"]) }, { start_date: "2026-10-10" });
    expect(result.results).toEqual([
      expect.objectContaining({ id: "explicit", domain: "work", status: "planned" }),
      expect.objectContaining({ id: "inferred", domain: "unknown", status: "unconfirmed" }),
      expect.objectContaining({ id: "explicit-private", domain: "private", status: "unconfirmed" }),
    ]);
  });

  it("uses JST half-open days and distinguishes save time from explicit event time", async () => {
    const backend = new FakeBackend();
    backend.dayRows.set("agent-hub", [
      dayRow("start", "agent-hub", "2026-10-09T15:00:00.000Z", "2026-10-09T15:00:00.000Z"),
      dayRow("end", "agent-hub", "2026-10-10T15:00:00.000Z", "2026-10-10T15:00:00.000Z"),
      dayRow("saved-only", "agent-hub", "2026-10-09T16:00:00.000Z"),
      { ...dayRow("metadata-event", "agent-hub", "2026-10-11T00:00:00.000Z", null, { metadata: { event_at: "2026-10-09T17:00:00.000Z" } }), event_at: "2026-10-09T17:00:00.000Z" },
    ]);
    const service = new ScopedMemoryService(backend, config.allowedProjects);
    const scope = { project: "agent-hub", agent: "codex" };
    const saved = await service.day(scope, { start_date: "2026-10-10" });
    expect((saved.results as Array<{id: string; event_at: string | null}>).map((row) => row.id)).toEqual(["start", "saved-only"]);
    expect((saved.results as Array<{event_at: string | null}>)[1]?.event_at).toBeNull();
    const event = await service.day(scope, { start_date: "2026-10-10", time_basis: "event_at" });
    expect((event.results as Array<{id: string}>).map((row) => row.id)).toEqual(["start", "metadata-event"]);
    expect(event.partial).toBe(true);
    expect(event.unknown_event_count).toBe(1);
  });

  it("sanitizes failed project details and turns project mismatches into partial failures", async () => {
    const backend = new FakeBackend();
    backend.dayRows.set("agent-hub", [dayRow("ok", "agent-hub", "2026-10-09T15:00:00.000Z")]);
    backend.dayFailures.add("jtt-cms");
    const partial = await new ScopedMemoryService(backend, config.allowedProjects).day({ project: "agent-hub", agent: "codex", readableProjects: new Set(["agent-hub", "jtt-cms"]) }, { start_date: "2026-10-10" });
    expect(partial).toMatchObject({ partial: true, failed_projects: [{ project: "jtt-cms", code: "backend_error" }], results: [expect.objectContaining({ id: "ok" })] });
    expect(JSON.stringify(partial)).not.toContain("private backend detail");
    backend.dayFailures.clear();
    backend.dayMemories = async () => ({ memories: [dayRow("wrong", "jtt-cms", "2026-10-09T15:00:00.000Z")], total: 1, unknownEventCount: 0 });
    const mismatch = await new ScopedMemoryService(backend, config.allowedProjects).day({ project: "agent-hub", agent: "codex", readableProjects: new Set(["agent-hub"]) }, { start_date: "2026-10-10" });
    expect(mismatch).toMatchObject({ partial: true, failed_projects: [{ project: "agent-hub", code: "backend_error" }], results: [] });
  });

  it("keeps incomplete or changing backend pages partial and refuses malformed envelopes", async () => {
    const backend = new FakeBackend();
    const scope = { project: "agent-hub", agent: "codex", readableProjects: new Set(["agent-hub"]) };
    backend.dayMemories = async () => ({ memories: [], total: 1, unknownEventCount: 0 });
    const incomplete = await new ScopedMemoryService(backend, config.allowedProjects).day(scope, { start_date: "2026-10-10" });
    expect(incomplete).toMatchObject({ partial: true, failed_projects: [{ project: "agent-hub", code: "backend_error" }], total: 0 });

    backend.dayMemories = async (input) => input.offset === 0
      ? { memories: [dayRow("first", "agent-hub", "2026-10-09T15:00:00.000Z")], total: 2, unknownEventCount: 0 }
      : { memories: [dayRow("second", "agent-hub", "2026-10-09T16:00:00.000Z")], total: 3, unknownEventCount: 0 };
    const changed = await new ScopedMemoryService(backend, config.allowedProjects).day(scope, { start_date: "2026-10-10" });
    expect(changed).toMatchObject({ partial: true, failed_projects: [{ project: "agent-hub", code: "backend_error" }], total: 0 });

    backend.dayMemories = async () => ({ memories: [{ ...dayRow("malformed", "agent-hub", "2026-10-09T15:00:00.000Z"), content: "not an envelope" }], total: 1, unknownEventCount: 0 });
    const malformed = await new ScopedMemoryService(backend, config.allowedProjects).day(scope, { start_date: "2026-10-10" });
    expect(malformed).toMatchObject({ partial: true, failed_projects: [{ project: "agent-hub", code: "backend_error" }], total: 0 });
  });

  it("rejects an older backend that ignores day filters and project mismatches", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ memories: [], total: 0 })));
    vi.stubGlobal("fetch", fetchMock);
    const backend = new RestAgentMemoryBackend(config);
    const query = { project: "agent-hub", startAt: "2026-10-09T15:00:00.000Z", endAt: "2026-10-10T15:00:00.000Z", timeBasis: "saved_at" as const, limit: 5000, offset: 0 };
    await expect(backend.dayMemories(query)).rejects.toThrow(/invalid/);
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ dayProject: "jtt-cms", startAt: query.startAt, endAt: query.endAt, timeBasis: query.timeBasis, memories: [], total: 0, unknownEventCount: 0 })));
    await expect(backend.dayMemories(query)).rejects.toThrow(/invalid/);
  });
});
