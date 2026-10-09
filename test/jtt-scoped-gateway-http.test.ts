import { createServer } from "node:http";
import { once } from "node:events";
import { afterEach, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startScopedGateway, type GatewayConfig } from "../src/jtt/scoped-gateway.js";

const openServers: Array<ReturnType<typeof createServer>> = [];

afterEach(async () => {
  await Promise.all(
    openServers.splice(0).map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
});

function portOf(server: ReturnType<typeof createServer>): number {
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("server has no TCP port");
  return address.port;
}

describe("JTT scoped gateway over Streamable HTTP", () => {
  it("completes initialize, tools/list, and a project-bound save", async () => {
    const remembered: Array<Record<string, unknown>> = [];
    const dayCalls: Array<{ url: string; authorization: string | undefined }> = [];
    const upstream = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      req.on("end", () => {
        const body = chunks.length ? (JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>) : {};
        if (req.url === "/agentmemory/remember") {
          remembered.push(body);
          res.writeHead(201, { "content-type": "application/json" });
          res.end(JSON.stringify({ success: true, memory: { id: "mem-http-1" } }));
          return;
        }
        if (req.url === "/agentmemory/search") {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ results: [] }));
          return;
        }
        if (req.url?.startsWith("/agentmemory/memories?")) {
          dayCalls.push({ url: req.url, authorization: req.headers.authorization });
          const url = new URL(req.url, "http://localhost");
          const project = url.searchParams.get("dayProject");
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({
            dayProject: project,
            startAt: url.searchParams.get("startAt"),
            endAt: url.searchParams.get("endAt"),
            timeBasis: url.searchParams.get("timeBasis"),
            offset: Number(url.searchParams.get("offset")),
            limit: Number(url.searchParams.get("limit")),
            memories: project === "agent-hub" ? [{
              id: "mem-http-day",
              project: "agent-hub",
              content: `JTT_AGENTMEMORY fact agent-hub\n${JSON.stringify({ schema: "jtt-agentmemory/v1", project: "agent-hub", category: "fact", sourceAgent: "codex", content: "day read", files: [], createdAt: "2026-10-10T00:00:00.000Z" })}`,
              saved_at: "2026-10-10T00:00:00.000Z",
              event_at: null,
              category: "fact",
            }] : [],
            total: project === "agent-hub" ? 1 : 0,
            unknownEventCount: 0,
          }));
          return;
        }
        res.writeHead(404).end();
      });
    });
    openServers.push(upstream);
    upstream.listen(0, "127.0.0.1");
    await once(upstream, "listening");

    const config: GatewayConfig = {
      host: "127.0.0.1",
      port: 0,
      gatewaySecret: "http-test-secret",
      upstreamUrl: `http://127.0.0.1:${portOf(upstream)}`,
      upstreamSecret: "upstream-test-secret",
      allowedProjects: new Set(["agent-hub", "global/reference"]),
      tokenProjects: new Map(),
      requestTimeoutMs: 1_000,
    };
    const gateway = startScopedGateway(config);
    openServers.push(gateway);
    await once(gateway, "listening");

    const headers = {
      authorization: "Bearer http-test-secret",
      "x-agentmemory-project": "agent-hub",
      "x-agentmemory-agent": "warp",
    };
    const client = new Client({ name: "http-test", version: "1.0.0" });
    const transport = new StreamableHTTPClientTransport(
      new URL(`http://127.0.0.1:${portOf(gateway)}/mcp`),
      { requestInit: { headers } },
    );
    await client.connect(transport);
    try {
      const tools = await client.listTools();
      expect(tools.tools).toHaveLength(5);
      expect(tools.tools.find((tool) => tool.name === "agentmemory_day")?.annotations?.readOnlyHint).toBe(true);
      const response = await client.callTool({
        name: "agentmemory_save",
        arguments: { content: "Warp can save scoped memory", category: "reference" },
      });
      expect(response.isError).not.toBe(true);
      expect(remembered).toHaveLength(1);
      expect(remembered[0]?.project).toBe("agent-hub");
      expect(remembered[0]?.content).toContain('"sourceAgent":"warp"');
      const day = await client.callTool({ name: "agentmemory_day", arguments: { start_date: "2026-10-10" } });
      expect(day.isError).not.toBe(true);
      expect(day.structuredContent).toMatchObject({ results: [expect.objectContaining({ id: "mem-http-day" })], partial: false });
      expect(dayCalls).toHaveLength(2);
      expect(dayCalls.some((call) => call.url.includes("dayProject=agent-hub") && call.url.includes("timeBasis=saved_at"))).toBe(true);
      expect(dayCalls.every((call) => call.authorization === "Bearer upstream-test-secret")).toBe(true);
    } finally {
      await client.close();
    }
  });

  it("rejects unauthenticated MCP discovery", async () => {
    const config: GatewayConfig = {
      host: "127.0.0.1",
      port: 0,
      gatewaySecret: "http-test-secret",
      upstreamUrl: "http://127.0.0.1:9",
      allowedProjects: new Set(["agent-hub"]),
      tokenProjects: new Map(),
      requestTimeoutMs: 50,
    };
    const gateway = startScopedGateway(config);
    openServers.push(gateway);
    await once(gateway, "listening");
    const response = await fetch(`http://127.0.0.1:${portOf(gateway)}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-agentmemory-project": "agent-hub" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
    });
    expect(response.status).toBe(401);
  });
});
