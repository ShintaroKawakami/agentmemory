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
      expect(tools.tools).toHaveLength(4);
      const response = await client.callTool({
        name: "agentmemory_save",
        arguments: { content: "Warp can save scoped memory", category: "reference" },
      });
      expect(response.isError).not.toBe(true);
      expect(remembered).toHaveLength(1);
      expect(remembered[0]?.project).toBe("agent-hub");
      expect(remembered[0]?.content).toContain('"sourceAgent":"warp"');
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
