#!/usr/bin/env node

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer as createHttpServer, type IncomingMessage, type ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";

const STORED_SCHEMA = "jtt-agentmemory/v1" as const;
const GLOBAL_REFERENCE_PROJECT = "global/reference";
const PROJECT_PATTERN = /^[a-z0-9][a-z0-9._/-]{0,127}$/;
const AGENT_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const MAX_BODY_BYTES = 256 * 1024;
const DEFAULT_TIMEOUT_MS = 4_000;
const HANDOFF_LOOKUP_LIMIT = 60;

type MemoryCategory = "reference" | "decision" | "fact" | "implementation_handoff";

export interface GatewayConfig {
  host: string;
  port: number;
  gatewaySecret: string;
  upstreamUrl: string;
  upstreamSecret?: string;
  allowedProjects: ReadonlySet<string>;
  tokenProjects: Map<string, string>;
  requestTimeoutMs: number;
}

export interface RequestScope {
  project: string;
  agent: string;
}

interface StoredEnvelope {
  schema: typeof STORED_SCHEMA;
  project: string;
  category: MemoryCategory;
  sourceAgent: string;
  content: string;
  files: string[];
  createdAt: string;
  handoff?: {
    summary: string;
    nextStep: string;
    openQuestions: string[];
    gitRef?: string;
  };
}

interface SearchHit {
  observation?: {
    id?: string;
    timestamp?: string;
    narrative?: string;
    project?: string;
  };
  score?: number;
}

interface SearchResponse {
  results?: SearchHit[];
}

export interface AgentMemoryBackend {
  remember(input: {
    content: string;
    type: "workflow" | "architecture" | "fact";
    concepts: string[];
    files: string[];
    project: string;
  }): Promise<unknown>;
  search(input: {
    query: string;
    limit: number;
    project: string;
  }): Promise<SearchResponse>;
}

export class GatewayError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly code: string,
  ) {
    super(message);
  }
}

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function canonicalProject(value: string): string {
  const project = value.trim().toLowerCase();
  if (!PROJECT_PATTERN.test(project) || project.includes("..") || project.includes("//")) {
    throw new GatewayError("Invalid project identifier", 400, "invalid_project");
  }
  return project;
}

// [2026-08-31][feat] Claude.ai コネクタ向け token→project マップ経路
// 背景:
//   - ユーザー依頼意図: Claude.ai カスタムコネクタは authorization ヘッダしか送れない
//     （未承認カスタムヘッダ名 x-agentmemory-project は登録時に拒否・2026-08-31 実測）ため、
//     専用 Bearer トークン自体に project を紐づけて X-AgentMemory-Project 無しでも scope を解決する。
//   - 守るべき業務ルール: 既存の共有 secret + ヘッダ経路は無変更で残す。トークン実値を
//     例外メッセージ・ログへ出さない。project は AGENTMEMORY_ALLOWED_PROJECTS の範囲内に限る。
//   - 他案不採用理由: クエリ鍵→Bearer 変換プロキシの新設は Claude.ai がヘッダ入力欄を持つため不要。
//     MCP ツール引数で project を渡す案は書込み先スコープを呼び出し側が自由化できてしまうため不採用。
function parseTokenProjectMap(value: string | undefined, allowedProjects: ReadonlySet<string>): Map<string, string> {
  const tokenProjects = new Map<string, string>();
  const raw = value?.trim();
  if (!raw) return tokenProjects;
  for (const entry of raw.split(",")) {
    const item = entry.trim();
    const separator = item.indexOf(":");
    const token = (separator >= 0 ? item.slice(0, separator) : item).trim();
    if (!token) {
      throw new Error("AGENTMEMORY_TOKEN_PROJECT_MAP entries must be formatted as token:project");
    }
    const project = canonicalProject(separator >= 0 ? item.slice(separator + 1) : "");
    if (!allowedProjects.has(project)) {
      throw new Error(`AGENTMEMORY_TOKEN_PROJECT_MAP project ${project} is not in AGENTMEMORY_ALLOWED_PROJECTS`);
    }
    if (tokenProjects.has(token)) {
      // トークン実値をメッセージへ含めない（起動時エラーがログへ出ても Bearer が漏れないように）。
      throw new Error("AGENTMEMORY_TOKEN_PROJECT_MAP contains a duplicate token");
    }
    tokenProjects.set(token, project);
  }
  return tokenProjects;
}

export function loadGatewayConfig(env: NodeJS.ProcessEnv = process.env): GatewayConfig {
  const gatewaySecret = env["AGENTMEMORY_GATEWAY_SECRET"]?.trim();
  if (!gatewaySecret) {
    throw new Error("AGENTMEMORY_GATEWAY_SECRET is required");
  }
  const rawProjects = env["AGENTMEMORY_ALLOWED_PROJECTS"] ?? "";
  const allowedProjects = new Set(
    rawProjects
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
      .map(canonicalProject),
  );
  if (allowedProjects.size === 0) {
    throw new Error("AGENTMEMORY_ALLOWED_PROJECTS must contain at least one canonical project id");
  }
  return {
    host: env["AGENTMEMORY_GATEWAY_HOST"]?.trim() || "127.0.0.1",
    port: positiveInt(env["AGENTMEMORY_GATEWAY_PORT"], 3121),
    gatewaySecret,
    upstreamUrl: (env["AGENTMEMORY_UPSTREAM_URL"]?.trim() || "http://127.0.0.1:3111").replace(/\/+$/, ""),
    upstreamSecret: env["AGENTMEMORY_SECRET"]?.trim() || undefined,
    allowedProjects,
    tokenProjects: parseTokenProjectMap(env["AGENTMEMORY_TOKEN_PROJECT_MAP"], allowedProjects),
    requestTimeoutMs: positiveInt(env["AGENTMEMORY_GATEWAY_TIMEOUT_MS"], DEFAULT_TIMEOUT_MS),
  };
}

function sameSecret(actual: string, expected: string): boolean {
  const actualDigest = createHash("sha256").update(actual).digest();
  const expectedDigest = createHash("sha256").update(expected).digest();
  return timingSafeEqual(actualDigest, expectedDigest);
}

function resolveAgent(headers: Headers, fallback: string): string {
  const rawAgent = (headers.get("x-agentmemory-agent") || fallback).trim().toLowerCase();
  if (!AGENT_PATTERN.test(rawAgent)) {
    throw new GatewayError("Invalid agent identifier", 400, "invalid_agent");
  }
  return rawAgent;
}

export function resolveRequestScope(headers: Headers, config: GatewayConfig): RequestScope {
  const authorization = headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const sharedSecretMatch = sameSecret(token, config.gatewaySecret);
  let mappedProject: string | undefined;
  if (!sharedSecretMatch) {
    // Compare every entry so token length or entry count never leaks through timing.
    for (const [candidate, project] of config.tokenProjects) {
      if (sameSecret(token, candidate)) mappedProject = project;
    }
  }
  if (sharedSecretMatch) {
    const rawProject = headers.get("x-agentmemory-project");
    if (!rawProject) {
      throw new GatewayError("X-AgentMemory-Project is required", 400, "project_required");
    }
    const project = canonicalProject(rawProject);
    if (!config.allowedProjects.has(project)) {
      throw new GatewayError("Project is not enabled for this gateway", 403, "project_not_allowed");
    }
    return { project, agent: resolveAgent(headers, "unknown-agent") };
  }
  if (!mappedProject) {
    throw new GatewayError("Unauthorized", 401, "unauthorized");
  }
  const rawProject = headers.get("x-agentmemory-project");
  if (rawProject && canonicalProject(rawProject) !== mappedProject) {
    throw new GatewayError("Project is not enabled for this gateway", 403, "project_not_allowed");
  }
  return { project: mappedProject, agent: resolveAgent(headers, "claude-ai") };
}

export class RestAgentMemoryBackend implements AgentMemoryBackend {
  constructor(private readonly config: GatewayConfig) {}

  private async post(path: string, body: unknown): Promise<unknown> {
    const response = await fetch(`${this.config.upstreamUrl}/agentmemory/${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(this.config.upstreamSecret
          ? { authorization: `Bearer ${this.config.upstreamSecret}` }
          : {}),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.config.requestTimeoutMs),
    });
    if (!response.ok) {
      throw new GatewayError("AgentMemory backend is unavailable", 502, "backend_error");
    }
    return response.json();
  }

  remember(input: Parameters<AgentMemoryBackend["remember"]>[0]): Promise<unknown> {
    return this.post("remember", input);
  }

  async search(input: Parameters<AgentMemoryBackend["search"]>[0]): Promise<SearchResponse> {
    const result = await this.post("search", {
      query: input.query,
      limit: input.limit,
      project: input.project,
      format: "full",
    });
    return result && typeof result === "object" ? (result as SearchResponse) : {};
  }
}

function encodeEnvelope(envelope: StoredEnvelope): string {
  return `JTT_AGENTMEMORY ${envelope.category} ${envelope.project}\n${JSON.stringify(envelope)}`;
}

function decodeEnvelope(value: string | undefined): StoredEnvelope | null {
  if (!value?.startsWith("JTT_AGENTMEMORY ")) return null;
  const separator = value.indexOf("\n");
  if (separator < 0) return null;
  try {
    const parsed = JSON.parse(value.slice(separator + 1)) as Partial<StoredEnvelope>;
    if (
      parsed.schema !== STORED_SCHEMA ||
      typeof parsed.project !== "string" ||
      typeof parsed.category !== "string" ||
      typeof parsed.sourceAgent !== "string" ||
      typeof parsed.content !== "string" ||
      !Array.isArray(parsed.files) ||
      typeof parsed.createdAt !== "string"
    ) {
      return null;
    }
    return parsed as StoredEnvelope;
  } catch {
    return null;
  }
}

function memoryType(category: MemoryCategory): "workflow" | "architecture" | "fact" {
  if (category === "implementation_handoff") return "workflow";
  if (category === "decision") return "architecture";
  return "fact";
}

function textResult(value: unknown, isError = false) {
  return {
    isError,
    content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value as Record<string, unknown>,
  };
}

export class ScopedMemoryService {
  constructor(
    private readonly backend: AgentMemoryBackend,
    private readonly allowedProjects: ReadonlySet<string>,
  ) {}

  async save(
    scope: RequestScope,
    input: { content: string; category: Exclude<MemoryCategory, "implementation_handoff">; files?: string[] },
  ): Promise<Record<string, unknown>> {
    const envelope: StoredEnvelope = {
      schema: STORED_SCHEMA,
      project: scope.project,
      category: input.category,
      sourceAgent: scope.agent,
      content: input.content.trim(),
      files: input.files ?? [],
      createdAt: new Date().toISOString(),
    };
    const saved = await this.backend.remember({
      content: encodeEnvelope(envelope),
      type: memoryType(envelope.category),
      concepts: ["jtt-agentmemory", envelope.category, scope.project],
      files: envelope.files,
      project: scope.project,
    });
    return { success: true, project: scope.project, category: envelope.category, saved };
  }

  async saveHandoff(
    scope: RequestScope,
    input: {
      summary: string;
      nextStep: string;
      openQuestions?: string[];
      files?: string[];
      gitRef?: string;
    },
  ): Promise<Record<string, unknown>> {
    if (scope.project === GLOBAL_REFERENCE_PROJECT) {
      throw new GatewayError(
        "An implementation handoff requires an exact project binding",
        400,
        "handoff_project_required",
      );
    }
    const envelope: StoredEnvelope = {
      schema: STORED_SCHEMA,
      project: scope.project,
      category: "implementation_handoff",
      sourceAgent: scope.agent,
      content: input.summary.trim(),
      files: input.files ?? [],
      createdAt: new Date().toISOString(),
      handoff: {
        summary: input.summary.trim(),
        nextStep: input.nextStep.trim(),
        openQuestions: input.openQuestions ?? [],
        ...(input.gitRef?.trim() ? { gitRef: input.gitRef.trim() } : {}),
      },
    };
    const saved = await this.backend.remember({
      content: encodeEnvelope(envelope),
      type: "workflow",
      concepts: ["jtt-agentmemory", "implementation_handoff", scope.project],
      files: envelope.files,
      project: scope.project,
    });
    return { success: true, project: scope.project, handoff: envelope.handoff, saved };
  }

  async search(
    scope: RequestScope,
    input: {
      query: string;
      limit: number;
      includeGlobalReference?: boolean;
      referenceProjects?: string[];
    },
  ): Promise<Record<string, unknown>> {
    const projects = new Set<string>([scope.project]);
    if (input.includeGlobalReference && scope.project !== GLOBAL_REFERENCE_PROJECT) {
      projects.add(GLOBAL_REFERENCE_PROJECT);
    }
    for (const requested of input.referenceProjects ?? []) {
      const project = canonicalProject(requested);
      if (!this.allowedProjects.has(project)) {
        throw new GatewayError("Referenced project is not enabled", 403, "reference_project_not_allowed");
      }
      projects.add(project);
    }
    const perProjectLimit = Math.min(Math.max(input.limit * 3, 10), 60);
    const responses = await Promise.all(
      [...projects].map(async (project) => ({
        project,
        response: await this.backend.search({ query: input.query, limit: perProjectLimit, project }),
      })),
    );
    const results = responses
      .flatMap(({ project, response }) =>
        (response.results ?? []).flatMap((hit) => {
          const envelope = decodeEnvelope(hit.observation?.narrative);
          if (!envelope || envelope.project !== project) return [];
          return [{
            id: hit.observation?.id,
            project,
            source: project === scope.project ? "current_project" : "explicit_reference",
            category: envelope.category,
            content: envelope.content,
            files: envelope.files,
            sourceAgent: envelope.sourceAgent,
            createdAt: envelope.createdAt,
            score: typeof hit.score === "number" ? hit.score : 0,
            ...(envelope.handoff ? { handoff: envelope.handoff } : {}),
          }];
        }),
      )
      .sort((a, b) => b.score - a.score || b.createdAt.localeCompare(a.createdAt))
      .slice(0, input.limit);
    return { query: input.query, currentProject: scope.project, searchedProjects: [...projects], results };
  }

  async getHandoff(scope: RequestScope): Promise<Record<string, unknown>> {
    if (scope.project === GLOBAL_REFERENCE_PROJECT) {
      throw new GatewayError(
        "An implementation handoff requires an exact project binding",
        400,
        "handoff_project_required",
      );
    }
    const result = await this.search(scope, {
      query: `implementation_handoff ${scope.project}`,
      // Search returns relevance-ranked results before applying this limit.
      // Handoff reads must inspect the full per-project window so a newly saved
      // low-relevance record cannot be hidden behind an older handoff.
      limit: HANDOFF_LOOKUP_LIMIT,
    });
    const handoffs = Array.isArray(result["results"])
      ? (result["results"] as Array<Record<string, unknown>>).filter(
          (item) => item["category"] === "implementation_handoff" && item["project"] === scope.project,
        ).sort((a, b) => String(b["createdAt"] ?? "").localeCompare(String(a["createdAt"] ?? "")))
      : [];
    return {
      project: scope.project,
      handoff: handoffs[0] ?? null,
      fallbackUsed: false,
    };
  }
}

export function createScopedMcpServer(service: ScopedMemoryService, scope: RequestScope): McpServer {
  const server = new McpServer({ name: "jtt-agentmemory", version: "0.1.0" });

  server.registerTool(
    "agentmemory_save",
    {
      title: "Save project memory",
      description: "Save a concise project-bound reference, decision, or fact. The project is fixed by the MCP connection.",
      inputSchema: {
        content: z.string().min(1).max(20_000),
        category: z.enum(["reference", "decision", "fact"]).default("reference"),
        files: z.array(z.string().min(1).max(500)).max(50).optional(),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    async (input) => {
      try {
        return textResult(await service.save(scope, input));
      } catch (error) {
        return textResult(toPublicError(error), true);
      }
    },
  );

  server.registerTool(
    "agentmemory_search",
    {
      title: "Search project memory",
      description: "Search the current project by default. Other projects are searched only when explicitly listed, and every result includes its source project.",
      inputSchema: {
        query: z.string().min(1).max(2_000),
        limit: z.number().int().min(1).max(20).default(8),
        includeGlobalReference: z.boolean().default(false),
        referenceProjects: z.array(z.string().min(1).max(128)).max(5).optional(),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
    },
    async (input) => {
      try {
        return textResult(await service.search(scope, input));
      } catch (error) {
        return textResult(toPublicError(error), true);
      }
    },
  );

  server.registerTool(
    "agentmemory_handoff_save",
    {
      title: "Save implementation handoff",
      description: "Save an implementation handoff for the exact current project. Global or unknown project contexts are rejected.",
      inputSchema: {
        summary: z.string().min(1).max(12_000),
        nextStep: z.string().min(1).max(4_000),
        openQuestions: z.array(z.string().min(1).max(2_000)).max(20).optional(),
        files: z.array(z.string().min(1).max(500)).max(50).optional(),
        gitRef: z.string().min(1).max(200).optional(),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    async (input) => {
      try {
        return textResult(await service.saveHandoff(scope, input));
      } catch (error) {
        return textResult(toPublicError(error), true);
      }
    },
  );

  server.registerTool(
    "agentmemory_handoff_get",
    {
      title: "Get implementation handoff",
      description: "Return only the latest handoff belonging to the exact current project. It never falls back to another project.",
      inputSchema: {},
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
    },
    async () => {
      try {
        return textResult(await service.getHandoff(scope));
      } catch (error) {
        return textResult(toPublicError(error), true);
      }
    },
  );

  return server;
}

function toPublicError(error: unknown): Record<string, unknown> {
  if (error instanceof GatewayError) return { error: error.code, message: error.message };
  return { error: "internal_error", message: "AgentMemory operation failed" };
}

async function readBody(req: IncomingMessage): Promise<Buffer> {
  const declared = Number(req.headers["content-length"] ?? 0);
  if (declared > MAX_BODY_BYTES) {
    throw new GatewayError("Request body too large", 413, "body_too_large");
  }
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += bytes.length;
    if (total > MAX_BODY_BYTES) {
      throw new GatewayError("Request body too large", 413, "body_too_large");
    }
    chunks.push(bytes);
  }
  return Buffer.concat(chunks);
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

function requestHeaders(req: IncomingMessage): Headers {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  return headers;
}

export function startScopedGateway(config: GatewayConfig = loadGatewayConfig()) {
  const backend = new RestAgentMemoryBackend(config);
  const service = new ScopedMemoryService(backend, config.allowedProjects);
  const server = createHttpServer((req, res) => {
    void (async () => {
      if (req.url === "/health" && req.method === "GET") {
        return json(res, 200, { ok: true, service: "jtt-agentmemory-gateway" });
      }
      if (req.url !== "/mcp") return json(res, 404, { error: "not_found" });
      if (req.method !== "POST") return json(res, 405, { error: "method_not_allowed" });
      const headers = requestHeaders(req);
      const scope = resolveRequestScope(headers, config);
      const payload = await readBody(req);
      const request = new Request("http://127.0.0.1/mcp", {
        method: "POST",
        headers,
        body: new Blob([Uint8Array.from(payload)]),
      });
      const mcp = createScopedMcpServer(service, scope);
      const transport = new WebStandardStreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
        enableJsonResponse: true,
      });
      try {
        await mcp.connect(transport);
        const response = await transport.handleRequest(request);
        const responseHeaders: Record<string, string> = { "cache-control": "no-store" };
        response.headers.forEach((value, name) => {
          responseHeaders[name] = value;
        });
        res.writeHead(response.status, responseHeaders);
        res.end(Buffer.from(await response.arrayBuffer()));
      } finally {
        await mcp.close();
      }
    })().catch((error: unknown) => {
      const publicError = toPublicError(error);
      const status = error instanceof GatewayError ? error.statusCode : 500;
      if (!res.headersSent) json(res, status, publicError);
      else res.end();
    });
  });
  return server.listen(config.port, config.host, () => {
    process.stderr.write(`[jtt-agentmemory] scoped gateway listening on ${config.host}:${config.port}\n`);
  });
}

const entrypoint = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === entrypoint) startScopedGateway();
