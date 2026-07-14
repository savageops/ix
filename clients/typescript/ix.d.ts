// IX Search Engine — TypeScript Type Definitions
// Generated from ix.result.v3 schema (Frozen Schema Invariant, P24)
// Version: 2.0.0

/** Verification truth: the exact matcher confirmed every hit. */
export type Verification = "canonical";

/** Scan coverage: were access errors present? */
export type ScanCompletion = "complete" | "partial_access";

/** Projection completeness: are there more eligible hits? */
export type ProjectionCompletion = "complete" | "truncated";

/** Why the projection was truncated. */
export type TruncationReason =
  | "max_hits"
  | "byte_budget"
  | "retention_limit"
  | "similar_candidate_budget";

/** Stats visibility tier. */
export type StatsVisibility = "agent" | "standard" | "debug";

/** Record granularity for --record flag (P22). */
export type RecordGranularity = "line" | "block" | "section";

/** Output format selector. */
export type OutputFormat =
  | "text"
  | "agent"
  | "agent-v3"
  | "json"
  | "json-compact"
  | "files"
  | "count"
  | "stats";

/** Warm index route lane. */
export type RouteLane = "cold" | "warm";

/** A single search hit with fisheye preview metadata and scope tracking. */
export interface SearchHit {
  /** Line number (1-based). */
  l: number;
  /** Column number (1-based). */
  c: number;
  /** Match length in bytes. */
  n: number;
  /** Fisheye-contracted preview text. */
  p: string;
  /** Fisheye window metadata. */
  w: {
    /** Source byte offset where preview starts. */
    s: number;
    /** Source byte offset where preview ends. */
    e: number;
    /** Left elision marker present. */
    l: boolean;
    /** Right elision marker present. */
    r: boolean;
  };
  /** Enclosing function/scope name (P22 scope tracking). */
  fn?: string;
  /** Declaration line of the enclosing scope. */
  fnl?: number;
}

/** Scan coverage block. */
export interface ScanState {
  state: ScanCompletion;
  access_errors: number;
  files_discovered: number;
  files_scanned: number;
  policy_skipped: number;
}

/** Projection completeness block. */
export interface ProjectionState {
  state: ProjectionCompletion;
  returned: number;
  eligible: number;
  remaining: number;
  reason?: TruncationReason;
  byte_budget?: number;
  next_cursor?: string;
}

/** Warm index route information. */
export interface RouteInfo {
  lane: RouteLane;
  index_enabled: boolean;
  generation?: number;
  refresh?: string;
  fallback_reason?: string;
}

/** Agent stats (visibility: agent). */
export interface AgentStats {
  files_discovered: number;
  files_scanned: number;
  matches_found: number;
  bytes_scanned: number;
  access_errors: number;
  total_ms: number;
}

/** A context line from inspect/xo. */
export interface ContextLine {
  /** Line number. */
  l: number;
  /** Role: "match" or "context". */
  r: string;
  /** Line text. */
  t: string;
}

/** A context report for one file. */
export interface ContextReport {
  path: string;
  lines: ContextLine[];
}

/** ix.result.v3 — the bounded, cursorable agent output contract. */
export interface SearchResultV3 {
  schema: "ix.result.v3";
  verification: Verification;
  scan: ScanState;
  projection: ProjectionState;
  expr: string;
  cwd: string;
  stats: AgentStats;
  route: RouteInfo;
  hits: Record<string, SearchHit[]>;
  context?: ContextReport[];
}

/** ix.result.v2 — the compact grouped agent format. */
export interface SearchResultV2 {
  expr: string;
  status: "ok" | "partial";
  matches: number;
  files: number;
  ms: number;
  cwd: string;
  truncated?: boolean;
  skipped?: number;
  errors?: number;
  hits: Record<string, Array<{
    l: number;
    c: number;
    p: string;
    fn?: string;
    fnl?: number;
  }>>;
}

/** ix.result.v1 — the terminal sentinel. */
export interface SearchResultV1 {
  bytes: number;
  cmd: string;
  expr: string;
  status: "ok" | "partial";
  matches: number;
  files: {
    discovered: number;
    scanned: number;
    skipped: number;
  };
  ms: {
    aggregate: number;
    discover: number;
    scan: number;
    total: number;
  };
  slowest?: {
    bytes: number;
    ms: number;
    path: string;
  };
  access_errors?: {
    total: number;
    access_denied: number;
  };
}

/** ix.error.v1 — error sentinel. */
export interface ErrorResult {
  schema?: string;
  code: string;
  message: string;
  hint?: string | null;
  severity?: string;
  status: "error";
}

/** ix.xo.v1 — BM25 degree-of-interest context spans. */
export interface XoResult {
  schema: "ix.xo.v1";
  query: string;
  retrieval: {
    candidate: "bm25_line";
    structural_prior: boolean;
    semantic: boolean;
    assembly: "degree_of_interest";
  };
  coverage: {
    state: "complete" | "partial";
    files_discovered: number;
    files_read: number;
    lines_read: number;
    bytes_read: number;
    candidate_lines: number;
    skipped_hidden: number;
    skipped_generated: number;
    skipped_binary: number;
    skipped_oversize: number;
    skipped_budget: number;
    errors: number;
    candidate_limit_reached: boolean;
  };
  projection: {
    max_bytes: number;
    max_spans: number;
    returned_spans: number;
  };
  files: Array<{
    path: string;
    omitted_after: number;
    spans: Array<{
      start_line: number;
      end_line: number;
      focus_line: number;
      score: number;
      omitted_before: number;
      lines: Array<{
        line: number;
        text: string;
      }>;
    }>;
  }>;
}

/** MCP tool definition. */
export interface McpTool {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, unknown>;
    required: string[];
  };
}

/** MCP initialize response. */
export interface McpInitializeResult {
  protocolVersion: string;
  capabilities: { tools: Record<string, never> };
  serverInfo: { name: string; version: string };
}

/** MCP tools/call response. */
export interface McpToolCallResult {
  content: Array<{
    type: "text";
    text: string;
  }>;
}

/** Parse an IX result line. Returns the appropriate typed result. */
export function parseResult(line: string): SearchResultV2 | SearchResultV3 | ErrorResult {
  if (line.startsWith("-- ix.result.v2")) {
    const json = line.replace(/^-- ix\.result\.v2\s+/, "").replace(/\s+--$/, "");
    return JSON.parse(json) as SearchResultV2;
  }
  if (line.startsWith("-- ix.result.v3")) {
    const json = line.replace(/^-- ix\.result\.v3\s+/, "").replace(/\s+--$/, "");
    return JSON.parse(json) as SearchResultV3;
  }
  if (line.startsWith("-- ix.error.v1")) {
    const json = line.replace(/^-- ix\.error\.v1\s+/, "").replace(/\s+--$/, "");
    return JSON.parse(json) as ErrorResult;
  }
  throw new Error("Unknown result format");
}
