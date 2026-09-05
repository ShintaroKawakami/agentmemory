export const STORED_SCHEMA = "jtt-agentmemory/v1" as const;
export type MemoryCategory = "reference" | "decision" | "fact" | "implementation_handoff";

export interface StoredEnvelope {
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

export function encodeEnvelope(envelope: StoredEnvelope): string {
  return `JTT_AGENTMEMORY ${envelope.category} ${envelope.project}\n${JSON.stringify(envelope)}`;
}

export function decodeEnvelope(value: string | undefined): StoredEnvelope | null {
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

// [2026-09-05][fix] Project latest is chronological over the stored corpus,
// not a relevance window. Filter at the REST boundary before returning any row.
// Equal instants use ID descending so concurrent saves have a stable winner.
export function selectLatestProjectHandoff<T extends { id: string; project?: string; content: string }>(
  memories: readonly T[], project: string,
): T | null {
  let newest: { memory: T; timestamp: number } | undefined;
  for (const memory of memories) {
    if (memory.project !== project) continue;
    const envelope = decodeEnvelope(memory.content);
    if (!envelope || envelope.project !== project || envelope.category !== "implementation_handoff" || !envelope.handoff) continue;
    const timestamp = Date.parse(envelope.createdAt);
    if (!Number.isFinite(timestamp)) continue;
    if (!newest || timestamp > newest.timestamp ||
        (timestamp === newest.timestamp && memory.id > newest.memory.id)) newest = { memory, timestamp };
  }
  return newest?.memory ?? null;
}

