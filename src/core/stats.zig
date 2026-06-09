const std = @import("std");

pub const PhaseTimings = struct {
    discover_ms: f64 = 0,
    scan_ms: f64 = 0,
    aggregate_ms: f64 = 0,
    total_ms: f64 = 0,
    scan_work_ms_total: f64 = 0,
    aggregate_merge_ms: f64 = 0,
    aggregate_finalize_ms: f64 = 0,
};

pub const SlowFileStat = struct {
    path: []const u8 = "",
    duration_ms: f64 = 0,
    bytes: usize = 0,
    linux_dominant_target: bool = false,
};

pub const ConcurrencyStats = struct {
    available_threads: usize = 1,
    outer_scan_threads: usize = 1,
    execution_mode: []const u8 = "materialized",
    sharding_enabled: bool = false,
    sharded_files: usize = 0,
    max_shard_threads: usize = 0,
    max_shard_ranges: usize = 0,
    max_shard_chunk_bytes: usize = 0,
};

pub const LinuxDominantFileStats = struct {
    target_class: []const u8 = "linux_amd_asic_reg_giant_header",
    min_bytes: usize = 1024 * 1024,
    targeted_files_scanned: usize = 0,
    targeted_bytes_scanned: usize = 0,
    targeted_slowest_files: usize = 0,
    targeted_slowest_bytes: usize = 0,
    eligible_files: usize = 0,
    activated_files: usize = 0,
    bailout_files: usize = 0,
    max_shard_threads: usize = 0,
    max_range_count: usize = 0,
    max_chunk_bytes: usize = 0,
};

pub const LinuxStrategyStats = struct {
    selector_eligible: bool = false,
    current_strategy: []const u8 = "materialized",
    matcher_strategy_supported: bool = false,
    effective_roots: usize = 0,
    directory_roots: usize = 0,
    root_entry_count: usize = 0,
    files_discovered: usize = 0,
    collect_hits: bool = false,
    outer_parallel_shard_safe: bool = false,
};

pub const RegexDecompositionStats = struct {
    eligible_files: usize = 0,
    counted_files: usize = 0,
    bailout_files: usize = 0,
    candidate_lines_checked: usize = 0,
    duplicate_candidate_hits_skipped: usize = 0,
    candidate_lines_matched: usize = 0,
};

pub const UnicodeCaseFoldPrefilterStats = struct {
    full_scan_calls: usize = 0,
    range_scan_calls: usize = 0,
    candidate_prefix_hits: usize = 0,
    candidate_windows_verified: usize = 0,
    confirmed_matches: usize = 0,
    rejected_candidates: usize = 0,
    candidate_gap_bytes_total: usize = 0,
    candidate_gap_samples: usize = 0,
    max_prefix_variant_count: usize = 0,
    max_prefix_len: usize = 0,
    max_match_len: usize = 0,
};

pub const FastCountDensityStats = struct {
    literal_reject_fast_calls: usize = 0,
    literal_reject_fast_bytes: usize = 0,
    literal_range_calls: usize = 0,
    literal_range_bytes: usize = 0,
    literal_matches: usize = 0,
    alternate_reject_fast_calls: usize = 0,
    alternate_reject_fast_bytes: usize = 0,
    alternate_full_scan_calls: usize = 0,
    alternate_full_scan_bytes: usize = 0,
    alternate_full_scan_matches: usize = 0,
    alternate_range_calls: usize = 0,
    alternate_range_bytes: usize = 0,
    alternate_matches: usize = 0,
    shard_merge_calls: usize = 0,
    shard_merge_ranges: usize = 0,
    shard_merge_matches: usize = 0,
};

pub const ByteShardKernelStats = struct {
    enabled: bool = false,
    strategy: []const u8 = "none",
    files_profiled: usize = 0,
    range_calls: usize = 0,
    line_aligned_ranges: usize = 0,
    logical_range_bytes: usize = 0,
    widened_range_bytes: usize = 0,
    overlap_bytes: usize = 0,
    boundary_verified_candidates: usize = 0,
    boundary_rejected_candidates: usize = 0,
    range_elapsed_ns_total: u64 = 0,
    max_range_elapsed_ns: u64 = 0,
    reduce_elapsed_ns_total: u64 = 0,
    max_reduce_elapsed_ns: u64 = 0,
    matches: usize = 0,
};

pub const TrigramAccelerationStats = struct {
    eligible: bool = false,
    mode: []const u8 = "disabled",
    mandatory_groups: usize = 0,
    mandatory_trigrams: usize = 0,
    candidate_files_checked: usize = 0,
    pruned_files: usize = 0,
    verified_files: usize = 0,
    ineligible_files: usize = 0,
};

pub const CatalogIndexStats = struct {
    enabled: bool = false,
    available: bool = false,
    generation: ?u64 = null,
    path_count: usize = 0,
    meta_count: usize = 0,
    fallback_reason: []const u8 = "not_wired",
};

pub const PostingsIndexStats = struct {
    enabled: bool = false,
    available: bool = false,
    generation: ?u64 = null,
    trigram_count: usize = 0,
    postings_count: usize = 0,
    file_count: usize = 0,
    candidate_files: usize = 0,
    pruned_files: usize = 0,
    verified_files: usize = 0,
    fallback_reason: []const u8 = "not_wired",
};

pub const GenerationRefreshStats = struct {
    enabled: bool = false,
    available: bool = false,
    epoch: ?u64 = null,
    parent_epoch: ?u64 = null,
    delta_entries: usize = 0,
    delta_tombstones: usize = 0,
    base_candidate_files: usize = 0,
    delta_candidate_files: usize = 0,
    delta_overlay_pruned: usize = 0,
    delta_tombstone_pruned: usize = 0,
    overlay_route: []const u8 = "fallback",
    refresh_status: []const u8 = "not_wired",
    fallback_reason: []const u8 = "not_wired",
};

pub const WarmBenchmarkMode = enum {
    cold,
    index_hot,
    mutation_hot,
    fallback,
};

pub const WarmBenchmarkSample = struct {
    mode: WarmBenchmarkMode,
    elapsed_ns: u64,
    files_scanned: usize = 0,
    matches_found: usize = 0,
};

pub const WarmPerformanceGate = struct {
    max_index_hot_to_cold_per_mille: u16 = 800,
    max_mutation_hot_to_cold_per_mille: u16 = 1000,
    min_fallback_to_index_hot_per_mille: u16 = 1000,
};

pub const WarmPerformanceResult = struct {
    cold_ns: u64,
    index_hot_ns: u64,
    mutation_hot_ns: u64,
    fallback_ns: u64,
    index_hot_to_cold_per_mille: u64,
    mutation_hot_to_cold_per_mille: u64,
    fallback_to_index_hot_per_mille: u64,
};

pub fn evaluateWarmPerformanceGates(samples: []const WarmBenchmarkSample, gate: WarmPerformanceGate) !WarmPerformanceResult {
    const cold = findWarmBenchmarkSample(samples, .cold) orelse return error.MissingColdBenchmark;
    const index_hot = findWarmBenchmarkSample(samples, .index_hot) orelse return error.MissingIndexHotBenchmark;
    const mutation_hot = findWarmBenchmarkSample(samples, .mutation_hot) orelse return error.MissingMutationHotBenchmark;
    const fallback = findWarmBenchmarkSample(samples, .fallback) orelse return error.MissingFallbackBenchmark;
    if (cold.elapsed_ns == 0 or index_hot.elapsed_ns == 0 or mutation_hot.elapsed_ns == 0 or fallback.elapsed_ns == 0) return error.InvalidBenchmarkDuration;

    const result = WarmPerformanceResult{
        .cold_ns = cold.elapsed_ns,
        .index_hot_ns = index_hot.elapsed_ns,
        .mutation_hot_ns = mutation_hot.elapsed_ns,
        .fallback_ns = fallback.elapsed_ns,
        .index_hot_to_cold_per_mille = ratioPerMille(index_hot.elapsed_ns, cold.elapsed_ns),
        .mutation_hot_to_cold_per_mille = ratioPerMille(mutation_hot.elapsed_ns, cold.elapsed_ns),
        .fallback_to_index_hot_per_mille = ratioPerMille(fallback.elapsed_ns, index_hot.elapsed_ns),
    };
    if (result.index_hot_to_cold_per_mille > gate.max_index_hot_to_cold_per_mille) return error.IndexHotBenchmarkRegression;
    if (result.mutation_hot_to_cold_per_mille > gate.max_mutation_hot_to_cold_per_mille) return error.MutationHotBenchmarkRegression;
    if (result.fallback_to_index_hot_per_mille < gate.min_fallback_to_index_hot_per_mille) return error.FallbackBenchmarkInversion;
    return result;
}

pub const AccessErrorSample = struct {
    phase: []const u8 = "",
    operation: []const u8 = "",
    path: []const u8 = "",
    error_name: []const u8 = "",
};

pub const AccessErrorStats = struct {
    total: usize = 0,
    access_denied: usize = 0,
    discovery: usize = 0,
    scan: usize = 0,
    directory_open: usize = 0,
    directory_iterate: usize = 0,
    file_open: usize = 0,
    file_read: usize = 0,
    sample_count: usize = 0,
    samples: [8]AccessErrorSample = @splat(.{}),

    pub fn record(self: *AccessErrorStats, phase: []const u8, operation: []const u8, path: []const u8, err: anyerror) void {
        self.total += 1;
        if (err == error.AccessDenied) self.access_denied += 1;
        if (std.mem.eql(u8, phase, "discovery")) {
            self.discovery += 1;
        } else if (std.mem.eql(u8, phase, "scan")) {
            self.scan += 1;
        }
        if (std.mem.eql(u8, operation, "open_dir")) {
            self.directory_open += 1;
        } else if (std.mem.eql(u8, operation, "iterate_dir")) {
            self.directory_iterate += 1;
        } else if (std.mem.eql(u8, operation, "open_file")) {
            self.file_open += 1;
        } else if (std.mem.eql(u8, operation, "read_file")) {
            self.file_read += 1;
        }
        if (self.sample_count < self.samples.len) {
            self.samples[self.sample_count] = .{
                .phase = phase,
                .operation = operation,
                .path = path,
                .error_name = @errorName(err),
            };
            self.sample_count += 1;
        }
    }

    pub fn merge(self: *AccessErrorStats, other: AccessErrorStats) void {
        self.total += other.total;
        self.access_denied += other.access_denied;
        self.discovery += other.discovery;
        self.scan += other.scan;
        self.directory_open += other.directory_open;
        self.directory_iterate += other.directory_iterate;
        self.file_open += other.file_open;
        self.file_read += other.file_read;
        for (other.samples[0..other.sample_count]) |sample| {
            if (self.sample_count >= self.samples.len) break;
            self.samples[self.sample_count] = sample;
            self.sample_count += 1;
        }
    }
};

pub const AdmissionStats = struct {
    enabled: bool = false,
    ignore_files_loaded: usize = 0,
    hidden_entries_skipped: usize = 0,
    hidden_file_bytes: usize = 0,
    ignored_entries_skipped: usize = 0,
    ignored_file_bytes: usize = 0,
    explicit_files_included: usize = 0,
    protected_entries_skipped: usize = 0,
    binary_entries_skipped: usize = 0,
    binary_file_bytes: usize = 0,

    pub fn merge(self: *AdmissionStats, other: AdmissionStats) void {
        self.enabled = self.enabled or other.enabled;
        self.ignore_files_loaded += other.ignore_files_loaded;
        self.hidden_entries_skipped += other.hidden_entries_skipped;
        self.hidden_file_bytes += other.hidden_file_bytes;
        self.ignored_entries_skipped += other.ignored_entries_skipped;
        self.ignored_file_bytes += other.ignored_file_bytes;
        self.explicit_files_included += other.explicit_files_included;
        self.protected_entries_skipped += other.protected_entries_skipped;
        self.binary_entries_skipped += other.binary_entries_skipped;
        self.binary_file_bytes += other.binary_file_bytes;
    }
};

pub const FallbackLineScanStats = struct {
    enabled: bool = false,
    files_profiled: usize = 0,
    line_count: usize = 0,
    candidate_lines: usize = 0,
    matched_lines: usize = 0,
    scanned_line_bytes: usize = 0,
    max_line_bytes: usize = 0,
    newline_elapsed_ns_total: u64 = 0,
    regex_elapsed_ns_total: u64 = 0,
    max_file_elapsed_ns: u64 = 0,
    max_file_bytes: usize = 0,
    max_file_lines: usize = 0,
    max_file_matches: usize = 0,
    max_file_path: []const u8 = "",

    pub fn isInactive(self: FallbackLineScanStats) bool {
        return !self.enabled;
    }
};

pub const SearchStats = struct {
    input_roots: usize = 0,
    effective_roots: usize = 0,
    pruned_roots: usize = 0,
    overlap_pruned_roots: usize = 0,
    discovered_duplicate_paths: usize = 0,
    acceleration_bailouts: usize = 0,
    files_discovered: usize = 0,
    files_scanned: usize = 0,
    files_skipped: usize = 0,
    matches_found: usize = 0,
    bytes_scanned: usize = 0,
    linux_strategy: LinuxStrategyStats = .{},
    linux_dominant_file: LinuxDominantFileStats = .{},
    regex_decomposition: RegexDecompositionStats = .{},
    unicode_casefold_prefilter: UnicodeCaseFoldPrefilterStats = .{},
    fast_count_density: FastCountDensityStats = .{},
    byte_shard_kernel: ByteShardKernelStats = .{},
    trigram_acceleration: TrigramAccelerationStats = .{},
    catalog_index: CatalogIndexStats = .{},
    postings_index: PostingsIndexStats = .{},
    generation_refresh: GenerationRefreshStats = .{},
    access_errors: AccessErrorStats = .{},
    admission: AdmissionStats = .{},
    fallback_line_scan: ?FallbackLineScanStats = null,
    timings: PhaseTimings = .{},
    concurrency: ConcurrencyStats = .{},
    slowest_files: [5]SlowFileStat = @splat(.{}),
    slowest_file_count: usize = 0,

    pub fn recordSlowFile(self: *SearchStats, path: []const u8, duration_ms: f64, bytes: usize, linux_dominant_target: bool) void {
        self.slowest_files[0] = .{
            .path = path,
            .duration_ms = duration_ms,
            .bytes = bytes,
            .linux_dominant_target = linux_dominant_target,
        };
        self.slowest_file_count = if (path.len == 0 and bytes == 0) 0 else 1;
        if (linux_dominant_target) {
            self.linux_dominant_file.targeted_slowest_files = 1;
            self.linux_dominant_file.targeted_slowest_bytes = bytes;
        }
    }
};

fn findWarmBenchmarkSample(samples: []const WarmBenchmarkSample, mode: WarmBenchmarkMode) ?WarmBenchmarkSample {
    for (samples) |sample| {
        if (sample.mode == mode) return sample;
    }
    return null;
}

fn ratioPerMille(numerator: u64, denominator: u64) u64 {
    return numerator * 1000 / denominator;
}

test "warm performance gates accept cold hot mutation and fallback samples" {
    const samples = [_]WarmBenchmarkSample{
        .{ .mode = .cold, .elapsed_ns = 1_000_000, .files_scanned = 100 },
        .{ .mode = .index_hot, .elapsed_ns = 250_000, .files_scanned = 100 },
        .{ .mode = .mutation_hot, .elapsed_ns = 700_000, .files_scanned = 4 },
        .{ .mode = .fallback, .elapsed_ns = 1_050_000, .files_scanned = 100 },
    };

    const result = try evaluateWarmPerformanceGates(&samples, .{});
    try std.testing.expectEqual(@as(u64, 250), result.index_hot_to_cold_per_mille);
    try std.testing.expectEqual(@as(u64, 700), result.mutation_hot_to_cold_per_mille);
    try std.testing.expectEqual(@as(u64, 4200), result.fallback_to_index_hot_per_mille);
}

test "warm performance gates reject regressions and incomplete benchmark matrices" {
    const regressed = [_]WarmBenchmarkSample{
        .{ .mode = .cold, .elapsed_ns = 1_000_000 },
        .{ .mode = .index_hot, .elapsed_ns = 900_000 },
        .{ .mode = .mutation_hot, .elapsed_ns = 700_000 },
        .{ .mode = .fallback, .elapsed_ns = 1_050_000 },
    };
    try std.testing.expectError(error.IndexHotBenchmarkRegression, evaluateWarmPerformanceGates(&regressed, .{}));

    const incomplete = [_]WarmBenchmarkSample{
        .{ .mode = .cold, .elapsed_ns = 1_000_000 },
        .{ .mode = .index_hot, .elapsed_ns = 250_000 },
        .{ .mode = .fallback, .elapsed_ns = 1_050_000 },
    };
    try std.testing.expectError(error.MissingMutationHotBenchmark, evaluateWarmPerformanceGates(&incomplete, .{}));
}

test "search stats owns rust-compatible top-level schema defaults" {
    var snapshot = SearchStats{};
    snapshot.recordSlowFile("fixture.txt", 1.25, 42, false);
    try std.testing.expectEqual(@as(usize, 1), snapshot.concurrency.available_threads);
    try std.testing.expectEqualStrings("materialized", snapshot.concurrency.execution_mode);
    try std.testing.expectEqualStrings("linux_amd_asic_reg_giant_header", snapshot.linux_dominant_file.target_class);
    try std.testing.expect(!snapshot.catalog_index.enabled);
    try std.testing.expectEqualStrings("not_wired", snapshot.catalog_index.fallback_reason);
    try std.testing.expect(!snapshot.postings_index.enabled);
    try std.testing.expectEqualStrings("not_wired", snapshot.postings_index.fallback_reason);
    try std.testing.expect(!snapshot.generation_refresh.enabled);
    try std.testing.expectEqualStrings("not_wired", snapshot.generation_refresh.refresh_status);
    try std.testing.expectEqualStrings("not_wired", snapshot.generation_refresh.fallback_reason);
    try std.testing.expectEqual(@as(usize, 1), snapshot.slowest_file_count);
    try std.testing.expect(!snapshot.admission.enabled);
}

test "access errors record bounded partial-search diagnostics" {
    var snapshot = SearchStats{};
    snapshot.access_errors.record("discovery", "open_dir", "C:/locked", error.AccessDenied);
    snapshot.access_errors.record("scan", "open_file", "C:/locked/file.txt", error.AccessDenied);
    snapshot.access_errors.record("scan", "open_file", "C:/locked/busy.dll", error.FileBusy);
    try std.testing.expectEqual(@as(usize, 3), snapshot.access_errors.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.access_errors.access_denied);
    try std.testing.expectEqual(@as(usize, 1), snapshot.access_errors.discovery);
    try std.testing.expectEqual(@as(usize, 2), snapshot.access_errors.scan);
    try std.testing.expectEqual(@as(usize, 3), snapshot.access_errors.sample_count);
    try std.testing.expectEqualStrings("open_dir", snapshot.access_errors.samples[0].operation);
    try std.testing.expectEqualStrings("FileBusy", snapshot.access_errors.samples[2].error_name);
}
