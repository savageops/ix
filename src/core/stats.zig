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
    min_bytes: usize = 8 * 1024 * 1024,
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
    files_profiled: usize = 0,
    range_calls: usize = 0,
    logical_range_bytes: usize = 0,
    widened_range_bytes: usize = 0,
    overlap_bytes: usize = 0,
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
    fallback_line_scan: ?FallbackLineScanStats = null,
    timings: PhaseTimings = .{},
    concurrency: ConcurrencyStats = .{},
    slowest_files: [5]SlowFileStat = [_]SlowFileStat{.{}} ** 5,
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

test "search stats owns rust-compatible top-level schema defaults" {
    var snapshot = SearchStats{};
    snapshot.recordSlowFile("fixture.txt", 1.25, 42, false);
    try std.testing.expectEqual(@as(usize, 1), snapshot.concurrency.available_threads);
    try std.testing.expectEqualStrings("materialized", snapshot.concurrency.execution_mode);
    try std.testing.expectEqualStrings("linux_amd_asic_reg_giant_header", snapshot.linux_dominant_file.target_class);
    try std.testing.expectEqual(@as(usize, 1), snapshot.slowest_file_count);
}
