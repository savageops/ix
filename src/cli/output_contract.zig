/// Output facts are split so canonical verification never implies complete scanning or projection.
pub const Verification = enum { canonical };

/// Scan coverage reports whether every admitted source was read successfully.
pub const ScanCompletion = enum { complete, partial_access };

/// Projection completion reports whether every eligible canonical hit is present in this page.
pub const ProjectionCompletion = enum { complete, truncated };

/// Typed causes let agents recover without interpreting prose.
pub const TruncationReason = enum {
    max_hits,
    byte_budget,
    retention_limit,
    similar_candidate_budget,
};

/// Telemetry policy is explicit per consumer instead of being scattered across writers.
pub const StatsVisibility = enum {
    agent,
    standard,
    debug,
};
