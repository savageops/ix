"""IX Search Engine — Python Type Stubs
Generated from ix.result.v3 schema (Frozen Schema Invariant, P24)
Version: 2.0.0
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Optional, TypedDict

# ── Enums ────────────────────────────────────────────────────────────

Verification = Literal["canonical"]
ScanCompletion = Literal["complete", "partial_access"]
ProjectionCompletion = Literal["complete", "truncated"]
TruncationReason = Literal["max_hits", "byte_budget", "retention_limit", "similar_candidate_budget"]
StatsVisibility = Literal["agent", "standard", "debug"]
RecordGranularity = Literal["line", "block", "section", "paragraph", "ast"]
OutputFormat = Literal["text", "agent", "agent-v3", "json", "json-compact", "files", "count", "stats", "ndjson"]
RouteLane = Literal["cold", "warm"]

# ── ix.result.v3 ─────────────────────────────────────────────────────


class FisheyeWindow(TypedDict):
    """Fisheye preview window metadata."""
    s: int  # source byte offset where preview starts
    e: int  # source byte offset where preview ends
    l: bool  # left elision marker present
    r: bool  # right elision marker present


class SearchHit(TypedDict, total=False):
    """A single search hit with fisheye preview and scope tracking."""
    l: int  # line number (1-based)
    c: int  # column number (1-based)
    n: int  # match length in bytes
    p: str  # fisheye-contracted preview text
    w: FisheyeWindow  # fisheye window metadata
    fn: str  # enclosing function/scope name (P22)
    fnl: int  # declaration line of enclosing scope


class ScanState(TypedDict):
    """Scan coverage block."""
    state: ScanCompletion
    access_errors: int
    files_discovered: int
    files_scanned: int
    policy_skipped: int


class ProjectionState(TypedDict, total=False):
    """Projection completeness block."""
    state: ProjectionCompletion
    returned: int
    eligible: int
    remaining: int
    reason: TruncationReason
    byte_budget: int
    next_cursor: str


class RouteInfo(TypedDict, total=False):
    """Warm index route information."""
    lane: RouteLane
    index_enabled: bool
    generation: int
    refresh: str
    fallback_reason: str


class AgentStats(TypedDict):
    """Agent stats (visibility: agent)."""
    files_discovered: int
    files_scanned: int
    matches_found: int
    bytes_scanned: int
    access_errors: int
    total_ms: float


class ContextLine(TypedDict):
    """A context line from inspect/xo."""
    l: int  # line number
    r: str  # role: "match" or "context"
    t: str  # line text


class ContextReport(TypedDict):
    """A context report for one file."""
    path: str
    lines: list[ContextLine]


class SearchResultV3(TypedDict, total=False):
    """ix.result.v3 — the bounded, cursorable agent output contract."""
    schema: Literal["ix.result.v3"]
    verification: Verification
    scan: ScanState
    projection: ProjectionState
    expr: str
    cwd: str
    stats: AgentStats
    route: RouteInfo
    hits: dict[str, list[SearchHit]]
    context: list[ContextReport]


# ── ix.result.v2 ─────────────────────────────────────────────────────


class V2Hit(TypedDict, total=False):
    """A hit in the v2 compact format."""
    l: int
    c: int
    p: str
    fn: str
    fnl: int


class SearchResultV2(TypedDict, total=False):
    """ix.result.v2 — the compact grouped agent format."""
    expr: str
    status: Literal["ok", "partial"]
    matches: int
    files: int
    ms: float
    cwd: str
    truncated: bool
    skipped: int
    errors: int
    hits: dict[str, list[V2Hit]]


# ── ix.result.v1 ─────────────────────────────────────────────────────


class V1Files(TypedDict):
    discovered: int
    scanned: int
    skipped: int


class V1Timings(TypedDict):
    aggregate: float
    discover: float
    scan: float
    total: float


class V1Slowest(TypedDict):
    bytes: int
    ms: float
    path: str


class SearchResultV1(TypedDict, total=False):
    """ix.result.v1 — the terminal sentinel."""
    bytes: int
    cmd: str
    expr: str
    status: Literal["ok", "partial"]
    matches: int
    files: V1Files
    ms: V1Timings
    slowest: V1Slowest
    access_errors: dict[str, int]


# ── ix.error.v1 ──────────────────────────────────────────────────────


class ErrorResult(TypedDict, total=False):
    """ix.error.v1 — error sentinel."""
    schema: str
    code: str
    message: str
    hint: Optional[str]
    severity: str
    status: Literal["error"]


# ── ix.xo.v1 ─────────────────────────────────────────────────────────


class XoRetrieval(TypedDict):
    candidate: Literal["bm25_line"]
    structural_prior: bool
    semantic: bool
    assembly: Literal["degree_of_interest"]


class XoCoverage(TypedDict):
    state: Literal["complete", "partial"]
    files_discovered: int
    files_read: int
    lines_read: int
    bytes_read: int
    candidate_lines: int
    skipped_hidden: int
    skipped_generated: int
    skipped_binary: int
    skipped_oversize: int
    skipped_budget: int
    errors: int
    candidate_limit_reached: bool


class XoProjection(TypedDict):
    max_bytes: int
    max_spans: int
    returned_spans: int


class XoLine(TypedDict):
    line: int
    text: str


class XoSpan(TypedDict):
    start_line: int
    end_line: int
    focus_line: int
    score: float
    omitted_before: int
    lines: list[XoLine]


class XoFile(TypedDict):
    path: str
    omitted_after: int
    spans: list[XoSpan]


class XoResult(TypedDict):
    """ix.xo.v1 — BM25 degree-of-interest context spans."""
    schema: Literal["ix.xo.v1"]
    query: str
    retrieval: XoRetrieval
    coverage: XoCoverage
    projection: XoProjection
    files: list[XoFile]


# ── MCP ──────────────────────────────────────────────────────────────


class McpTool(TypedDict):
    name: str
    description: str
    inputSchema: dict


class McpInitializeResult(TypedDict):
    protocolVersion: str
    capabilities: dict
    serverInfo: dict


class McpContent(TypedDict):
    type: Literal["text"]
    text: str


class McpToolCallResult(TypedDict):
    content: list[McpContent]


# ── Parser ────────────────────────────────────────────────────────────


def parse_result(line: str) -> SearchResultV2 | SearchResultV3 | ErrorResult:
    """Parse an IX result line and return the appropriate typed result."""
    import json

    if line.startswith("-- ix.result.v2"):
        json_str = line.replace("-- ix.result.v2 ", "").rstrip(" --")
        return json.loads(json_str)
    if line.startswith("-- ix.result.v3"):
        json_str = line.replace("-- ix.result.v3 ", "").rstrip(" --")
        return json.loads(json_str)
    if line.startswith("-- ix.error.v1"):
        json_str = line.replace("-- ix.error.v1 ", "").rstrip(" --")
        return json.loads(json_str)
    raise ValueError("Unknown result format")
