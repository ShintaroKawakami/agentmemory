import { describe, expect, it, vi } from "vitest";
import type { ISdk, ApiRequest } from "iii-sdk";
import type { StateKV } from "../src/state/kv.js";
import { registerApiTriggers } from "../src/triggers/api.js";

function record(id: string, project: string, createdAt: string) {
  return { id, project, content: `JTT_AGENTMEMORY implementation_handoff ${project}\n${JSON.stringify({
    schema: "jtt-agentmemory/v1", project, category: "implementation_handoff",
    sourceAgent: "codex", content: id, files: [], createdAt,
    handoff: {summary: id, nextStep: "continue", openQuestions: []},
  })}` };
}
function endpoint(records: ReturnType<typeof record>[]) {
  const handlers = new Map<string, (req: ApiRequest) => Promise<{status_code: number; body: unknown}>>();
  const sdk = {registerFunction: (id: string, handler: never) => handlers.set(id, handler), registerTrigger: vi.fn()};
  registerApiTriggers(sdk as unknown as ISdk, {list: async () => records} as unknown as StateKV, "test-boundary");
  return (query: Record<string, string>, authorized = true) => handlers.get("api::memories")!({
    headers: authorized ? {authorization: "Bearer test-boundary"} : {}, query_params: query,
  } as ApiRequest);
}
describe("REST handoff storage boundary", () => {
  it("finds the newest beyond 60 rows before pagination without returning other project data", async () => {
    const rows = Array.from({length: 80}, (_, i) => record(`old-${i}`, "agent-hub", "2026-09-01T00:00:00Z"));
    const latest = record("latest", "agent-hub", "2026-09-05T00:00:00Z");
    rows.push(record("secret-other", "jtt-cms", "2026-09-06T00:00:00Z"), latest);
    const response = await endpoint(rows)({handoffProject: "agent-hub", limit: "1", offset: "100"});
    expect(response).toEqual({status_code: 200, body: {handoff: latest}});
    expect(JSON.stringify(response)).not.toContain("secret-other");
  });
  it("preserves authentication, validates exact project, and returns null for empty", async () => {
    const call = endpoint([]);
    expect((await call({handoffProject: "agent-hub"}, false)).status_code).toBe(401);
    expect((await call({handoffProject: "global/reference"})).status_code).toBe(400);
    expect(await call({handoffProject: "agent-hub"})).toEqual({status_code: 200, body: {handoff: null}});
  });
});

describe("REST day storage boundary", () => {
  function savedMemory(id: string, project: string, savedAt: string, eventAt?: string, eventInMetadata = false) {
    const content = `JTT_AGENTMEMORY fact ${project}\n${JSON.stringify({
      schema: "jtt-agentmemory/v1", project, category: "fact", sourceAgent: "codex", content: id,
      files: [], createdAt: "2020-01-01T00:00:00Z",
      ...(eventAt ? eventInMetadata ? { metadata: { event_at: eventAt } } : { event_at: eventAt } : {}),
    })}`;
    return { id, createdAt: savedAt, updatedAt: savedAt, content, project, isLatest: true };
  }
  function memoriesEndpoint(records: unknown[]) {
    const handlers = new Map<string, (req: ApiRequest) => Promise<{status_code: number; body: unknown}>>();
    const sdk = {registerFunction: (id: string, handler: never) => handlers.set(id, handler), registerTrigger: vi.fn()};
    registerApiTriggers(sdk as unknown as ISdk, {list: async () => records} as unknown as StateKV, "test-boundary");
    return (query: Record<string, string>, authorized = true) => handlers.get("api::memories")!({
      headers: authorized ? {authorization: "Bearer test-boundary"} : {}, query_params: query,
    } as ApiRequest);
  }
  const query = {dayProject: "agent-hub", startAt: "2026-10-09T15:00:00.000Z", endAt: "2026-10-10T15:00:00.000Z", timeBasis: "saved_at", limit: "1", offset: "0"};

  it("filters project and half-open saved time before pagination, preserving auth", async () => {
    const call = memoriesEndpoint([
      savedMemory("start", "agent-hub", "2026-10-09T15:00:00.000Z", "2024-01-01T00:00:00Z"),
      savedMemory("end", "agent-hub", "2026-10-10T15:00:00.000Z"),
      savedMemory("other", "jtt-cms", "2026-10-09T16:00:00.000Z"),
    ]);
    expect((await call(query, false)).status_code).toBe(401);
    expect(await call(query)).toEqual({status_code: 200, body: expect.objectContaining({
      dayProject: "agent-hub", total: 1, memories: [expect.objectContaining({id: "start", project: "agent-hub", saved_at: "2026-10-09T15:00:00.000Z", event_at: "2024-01-01T00:00:00.000Z"})],
    })});
  });

  it("filters explicit event dates and reports unknown event dates without returning other projects", async () => {
    const call = memoriesEndpoint([
      savedMemory("event", "agent-hub", "2026-10-11T00:00:00.000Z", "2026-10-09T16:00:00Z"),
      savedMemory("metadata-event", "agent-hub", "2026-10-11T00:00:00.000Z", "2026-10-09T18:00:00Z", true),
      savedMemory("unknown", "agent-hub", "2026-10-09T17:00:00Z"),
      savedMemory("other", "jtt-cms", "2026-10-09T16:00:00Z", "2026-10-09T16:00:00Z"),
    ]);
    expect(await call({...query, timeBasis: "event_at", limit: "2"})).toEqual({status_code: 200, body: expect.objectContaining({total: 2, unknownEventCount: 1, memories: [expect.objectContaining({id: "event"}), expect.objectContaining({id: "metadata-event", event_at: "2026-10-09T18:00:00.000Z"})]})});
  });

  it("requires memory.project and envelope.project to match, and rejects malformed matching rows", async () => {
    const conflictingEnvelope = savedMemory("conflict", "jtt-cms", "2026-10-09T16:00:00Z");
    conflictingEnvelope.project = "agent-hub";
    const call = memoriesEndpoint([conflictingEnvelope]);
    await expect(call(query)).rejects.toThrow(/invalid day memory envelope/);
    const mismatchedMemory = savedMemory("other-project-row", "agent-hub", "2026-10-09T16:00:00Z");
    mismatchedMemory.project = "jtt-cms";
    expect(await memoriesEndpoint([mismatchedMemory])(query)).toEqual({status_code: 200, body: expect.objectContaining({total: 0, memories: []})});
  });
});
