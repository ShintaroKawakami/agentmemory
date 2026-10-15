#!/usr/bin/env node

import { STORED_SCHEMA, encodeEnvelope, decodeEnvelope, type StoredEnvelope, type MemoryCategory } from "./stored-envelope.js";

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer as createHttpServer, type IncomingMessage, type ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";

const GLOBAL_REFERENCE_PROJECT = "global/reference";
const PROJECT_PATTERN = /^[a-z0-9][a-z0-9._/-]{0,127}$/;
const AGENT_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const MAX_BODY_BYTES = 256 * 1024;
const DEFAULT_TIMEOUT_MS = 4_000;


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
  readableProjects?: ReadonlySet<string>;
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
  latestHandoff(input: { project: string }): Promise<SearchHit | null>;
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
  dayMemories(input: {
    project: string;
    startAt: string;
    endAt: string;
    timeBasis: "saved_at" | "event_at";
    limit: number;
    offset: number;
  }): Promise<{ memories: Array<{ id: string; project: string; content: string; saved_at: string; event_at: string | null; category: string; domain?: unknown; status?: unknown }>; total: number; unknownEventCount: number }>;
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
    return { project, agent: resolveAgent(headers, "unknown-agent"), readableProjects: new Set(config.allowedProjects) };
  }
  if (!mappedProject) {
    throw new GatewayError("Unauthorized", 401, "unauthorized");
  }
  const rawProject = headers.get("x-agentmemory-project");
  if (rawProject && canonicalProject(rawProject) !== mappedProject) {
    throw new GatewayError("Project is not enabled for this gateway", 403, "project_not_allowed");
  }
  return { project: mappedProject, agent: resolveAgent(headers, "claude-ai"), readableProjects: new Set([mappedProject]) };
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

  async latestHandoff(input: { project: string }): Promise<SearchHit | null> {
    const query = new URLSearchParams({ handoffProject: input.project });
    const response = await fetch(`${this.config.upstreamUrl}/agentmemory/memories?${query}`, {
      headers: this.config.upstreamSecret
        ? { authorization: `Bearer ${this.config.upstreamSecret}` } : {},
      signal: AbortSignal.timeout(this.config.requestTimeoutMs),
    });
    if (!response.ok) throw new GatewayError("AgentMemory backend is unavailable", 502, "backend_error");
    const result = await response.json() as { handoff?: { id?: string; project?: string; content?: string } | null };
    // An old backend returning its unscoped list must fail closed, never look empty.
    if (!result || typeof result !== "object" || Array.isArray(result) || !("handoff" in result)) {
      throw new GatewayError("AgentMemory handoff lookup is unavailable", 502, "backend_error");
    }
    if (result.handoff === null) return null;
    const row = result.handoff;
    if (!row || row.project !== input.project || typeof row.id !== "string" || typeof row.content !== "string") {
      throw new GatewayError("AgentMemory handoff response is invalid", 502, "backend_error");
    }
    return { observation: { id: row.id, project: row.project, narrative: row.content }, score: 0 };
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

  async dayMemories(input: Parameters<AgentMemoryBackend["dayMemories"]>[0]): Promise<Awaited<ReturnType<AgentMemoryBackend["dayMemories"]>>> {
    const query = new URLSearchParams({
      dayProject: input.project,
      startAt: input.startAt,
      endAt: input.endAt,
      timeBasis: input.timeBasis,
      limit: String(input.limit),
      offset: String(input.offset),
    });
    const response = await fetch(`${this.config.upstreamUrl}/agentmemory/memories?${query}`, {
      headers: this.config.upstreamSecret ? { authorization: `Bearer ${this.config.upstreamSecret}` } : {},
      signal: AbortSignal.timeout(this.config.requestTimeoutMs),
    });
    if (!response.ok) throw new GatewayError("AgentMemory backend is unavailable", 502, "backend_error");
    const result = await response.json() as Record<string, unknown>;
    if (!result || result.dayProject !== input.project || result.startAt !== input.startAt || result.endAt !== input.endAt || result.timeBasis !== input.timeBasis || result.offset !== input.offset || result.limit !== input.limit || !Array.isArray(result.memories) || !Number.isInteger(result.total) || (result.total as number) < 0 || !Number.isInteger(result.unknownEventCount) || (result.unknownEventCount as number) < 0 || result.memories.length > input.limit) {
      throw new GatewayError("AgentMemory day lookup response is invalid", 502, "backend_error");
    }
    const memories = result.memories as Array<Record<string, unknown>>;
    for (const row of memories) {
      if (!row || row.project !== input.project || typeof row.id !== "string" || typeof row.content !== "string" || typeof row.saved_at !== "string" || !(row.event_at === null || (typeof row.event_at === "string" && Number.isFinite(Date.parse(row.event_at)))) || typeof row.category !== "string") {
        throw new GatewayError("AgentMemory day lookup response is invalid", 502, "backend_error");
      }
    }
    return { memories: memories as Awaited<ReturnType<AgentMemoryBackend["dayMemories"]>>["memories"], total: result.total as number, unknownEventCount: result.unknownEventCount as number };
  }
}


function memoryType(category: MemoryCategory): "workflow" | "architecture" | "fact" {
  if (category === "implementation_handoff") return "workflow";
  if (category === "decision") return "architecture";
  return "fact";
}

/**
 * Save project memory with category=implementation_handoff is the documented path for
 * Cloud / Claude.ai / ChatGPT. Prefer explicit nextStep; otherwise parse labeled lines;
 * never downgrade to reference/decision/fact.
 */
export function parseHandoffSaveInput(input: {
  content: string;
  files?: string[];
  nextStep?: string;
  openQuestions?: string[];
  gitRef?: string;
}): {
  summary: string;
  nextStep: string;
  openQuestions?: string[];
  files?: string[];
  gitRef?: string;
} {
  const content = input.content.trim();
  const labeledNext = content.match(
    /(?:^|\n)\s*(?:nextStep|next_step|次の一手|次)\s*[:：]\s*(.+?)(?:\n|$)/i,
  );
  const labeledSummary = content.match(
    /(?:^|\n)\s*(?:summary|要約)\s*[:：]\s*(.+?)(?:\n(?=\s*(?:nextStep|next_step|次の一手|次|openQuestions|files|gitRef)\s*[:：])|\n*$)/is,
  );
  const summary = (labeledSummary?.[1]?.trim() || content).slice(0, 12_000);
  const nextStep = (
    input.nextStep?.trim() ||
    labeledNext?.[1]?.trim() ||
    "終了報告を確認して続きから再開する"
  ).slice(0, 4_000);
  return {
    summary: summary.length > 0 ? summary : content.slice(0, 12_000),
    nextStep,
    ...(input.openQuestions ? { openQuestions: input.openQuestions } : {}),
    ...(input.files ? { files: input.files } : {}),
    ...(input.gitRef?.trim() ? { gitRef: input.gitRef.trim() } : {}),
  };
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
    input: {
      content: string;
      category: MemoryCategory;
      files?: string[];
      nextStep?: string;
      openQuestions?: string[];
      gitRef?: string;
    },
  ): Promise<Record<string, unknown>> {
    // Cloud / Claude.ai / ChatGPT の終了手順は Save project memory に
    // category=implementation_handoff を渡す。別カテゴリへ迂回せず handoff へ正規化する。
    if (input.category === "implementation_handoff") {
      const handoff = parseHandoffSaveInput(input);
      return this.saveHandoff(scope, handoff);
    }
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
    const hit = await this.backend.latestHandoff({ project: scope.project });
    const envelope = decodeEnvelope(hit?.observation?.narrative);
    if (hit && (!envelope || envelope.project !== scope.project ||
        hit.observation?.project !== scope.project || envelope.category !== "implementation_handoff" ||
        !Number.isFinite(Date.parse(envelope.createdAt)) || !envelope.handoff)) {
      throw new GatewayError("AgentMemory handoff response is invalid", 502, "backend_error");
    }
    return {
      project: scope.project,
      handoff: envelope ? {
        id: hit?.observation?.id, project: scope.project, source: "current_project",
        category: envelope.category, content: envelope.content, files: envelope.files,
        sourceAgent: envelope.sourceAgent, createdAt: envelope.createdAt, score: 0,
        handoff: envelope.handoff,
      } : null,
      fallbackUsed: false,
    };
  }

  async day(scope: RequestScope, input: { start_date: string; end_date?: string; time_basis?: "saved_at" | "event_at"; limit?: number; offset?: number }): Promise<Record<string, unknown>> {
    const start = parseJstDate(input.start_date);
    const endDate = input.end_date ?? nextDate(input.start_date);
    const end = parseJstDate(endDate);
    if (start >= end) throw new GatewayError("Invalid date range", 400, "invalid_date_range");
    const timeBasis = input.time_basis ?? "saved_at";
    const limit = input.limit ?? 100;
    const offset = input.offset ?? 0;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isInteger(offset) || offset < 0) {
      throw new GatewayError("Invalid pagination", 400, "invalid_pagination");
    }

    const scopeProjects = scope.readableProjects ?? new Set([scope.project]);
    const projects = [...scopeProjects].filter((project) => this.allowedProjects.has(project)).sort();
    const consistencyUnverified = new Set<string>();
    const byProject = await Promise.allSettled(projects.map(async (project) => {
      const records: Awaited<ReturnType<AgentMemoryBackend["dayMemories"]>>["memories"] = [];
      let total = 0;
      let unknownEventCount = 0;
      let backendOffset = 0;
      let pageRequests = 0;
      do {
        if (pageRequests > 0) consistencyUnverified.add(project);
        pageRequests += 1;
        const page = await this.backend.dayMemories({ project, startAt: start, endAt: end, timeBasis, limit: 5000, offset: backendOffset });
        if (backendOffset === 0) {
          total = page.total;
          unknownEventCount = page.unknownEventCount;
        } else if (page.total !== total || page.unknownEventCount !== unknownEventCount) {
          throw new GatewayError("AgentMemory day lookup changed during pagination", 502, "backend_error");
        }
        const startMs = Date.parse(start);
        const endMs = Date.parse(end);
        if (page.memories.some((row) => {
          if (row.project !== project) return true;
          const envelope = decodeEnvelope(row.content);
          if (!envelope || envelope.project !== project) return true;
          const value = timeBasis === "saved_at" ? row.saved_at : row.event_at;
          const timestamp = typeof value === "string" ? Date.parse(value) : Number.NaN;
          return !Number.isFinite(timestamp) || timestamp < startMs || timestamp >= endMs;
        })) throw new GatewayError("AgentMemory day lookup response is invalid", 502, "backend_error");
        records.push(...page.memories);
        backendOffset += page.memories.length;
        if (page.memories.length === 0) {
          if (backendOffset < total) throw new GatewayError("AgentMemory day lookup response is incomplete", 502, "backend_error");
          break;
        }
        if (backendOffset >= total) break;
      } while (true);
      return { project, records, total, unknownEventCount };
    }));

    const succeeded: Array<{ project: string; records: Awaited<ReturnType<AgentMemoryBackend["dayMemories"]>>["memories"]; total: number; unknownEventCount: number }> = [];
    const failedProjects: Array<{ project: string; code: string }> = [];
    byProject.forEach((result, index) => {
      if (result.status === "fulfilled") succeeded.push(result.value);
      else failedProjects.push({ project: projects[index]!, code: "backend_error" });
    });

    const mapped = succeeded.flatMap(({ project, records }) => records.map((row) => {
      const envelope = decodeEnvelope(row.content)!;
      const rawEnvelope = envelope as unknown as Record<string, unknown>;
      const metadata = rawEnvelope.metadata && typeof rawEnvelope.metadata === "object" ? rawEnvelope.metadata as Record<string, unknown> : {};
      const eventAt = row.event_at === null ? null : new Date(row.event_at).toISOString();
      const rawDomain = metadata.domain ?? rawEnvelope.domain;
      const domain = rawDomain === "work" || rawDomain === "private" ? rawDomain : "unknown";
      const rawStatus = metadata.status ?? rawEnvelope.status;
      const status = rawStatus === "completed" || rawStatus === "planned" ? rawStatus : "unconfirmed";
      return {
        id: row.id,
        project,
        source: "agentmemory",
        content: envelope.content,
        event_at: eventAt,
        saved_at: row.saved_at,
        time_basis: timeBasis,
        category: envelope.category,
        domain,
        status,
      };
    }));

    const timeOf = (row: typeof mapped[number]) => Date.parse(timeBasis === "saved_at" ? row.saved_at : row.event_at ?? "");
    mapped.sort((a, b) => timeOf(a) - timeOf(b) || a.project.localeCompare(b.project) || a.id.localeCompare(b.id));
    const unknownEventCount = succeeded.reduce((sum, project) => sum + project.unknownEventCount, 0);
    const total = succeeded.reduce((sum, project) => sum + project.total, 0);
    const results = mapped.slice(offset, offset + limit);
    const hasMore = offset + results.length < total;
    return {
      results,
      total,
      offset,
      limit,
      has_more: hasMore,
      next_offset: hasMore ? offset + results.length : null,
      target_project_count: projects.length,
      searched_projects: succeeded.map((project) => project.project),
      failed_projects: failedProjects,
      unsearched_projects: [],
      consistency_unverified_projects: projects.filter((project) => consistencyUnverified.has(project)),
      partial: failedProjects.length > 0 || consistencyUnverified.size > 0 || (timeBasis === "event_at" && unknownEventCount > 0),
      ...(timeBasis === "event_at" ? { unknown_event_count: unknownEventCount } : {}),
      range: { start: input.start_date, end: endDate, timezone: "Asia/Tokyo" },
    };
  }
}

function parseJstDate(value: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new GatewayError("Invalid date", 400, "invalid_date");
  const [year, month, day] = value.split("-").map(Number);
  const instant = Date.UTC(year!, month! - 1, day!) - 9 * 60 * 60 * 1000;
  const roundTrip = new Date(instant + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
  if (roundTrip !== value) throw new GatewayError("Invalid date", 400, "invalid_date");
  return new Date(instant).toISOString();
}

function nextDate(value: string): string {
  const [year, month, day] = value.split("-").map(Number);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || !year || !month || !day) throw new GatewayError("Invalid date", 400, "invalid_date");
  return new Date(Date.UTC(year, month - 1, day + 1)).toISOString().slice(0, 10);
}

export function createScopedMcpServer(service: ScopedMemoryService, scope: RequestScope): McpServer {
  const server = new McpServer({ name: "jtt-agentmemory", version: "0.1.0" });

  server.registerTool(
    "agentmemory_save",
    {
      title: "Save project memory",
      description:
        "Save a concise project-bound reference, decision, fact, or implementation_handoff. " +
        "When category is implementation_handoff, content is stored as a handoff (optional nextStep/openQuestions/gitRef). " +
        "Do not downgrade a handoff to another category. The project is fixed by the MCP connection.",
      inputSchema: {
        content: z.string().min(1).max(20_000),
        category: z.enum(["reference", "decision", "fact", "implementation_handoff"]).default("reference"),
        files: z.array(z.string().min(1).max(500)).max(50).optional(),
        nextStep: z.string().min(1).max(4_000).optional(),
        openQuestions: z.array(z.string().min(1).max(2_000)).max(20).optional(),
        gitRef: z.string().min(1).max(200).optional(),
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

  server.registerTool(
    "agentmemory_day",
    {
      title: "Read memories for a day",
      description: "Read project memories in an exclusive JST date range. The readable project set is fixed by gateway authentication.",
      inputSchema: {
        start_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        end_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
        time_basis: z.enum(["saved_at", "event_at"]).default("saved_at"),
        limit: z.number().int().min(1).max(100).default(100),
        offset: z.number().int().min(0).default(0),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
    },
    async (input) => {
      try {
        return textResult(await service.day(scope, input));
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
