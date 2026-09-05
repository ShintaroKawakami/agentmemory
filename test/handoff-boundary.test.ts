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
