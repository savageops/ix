---
id: pass-004-json-validity
type: qc
category: security
status: complete
date: 2026-07-13
severity: high
discovered_by: "x4 adversarial agent, x20 forensic agent"
prior: pass-002-agent-output-contract
---

# QC Pass 004 — Invalid JSON Emission (HIGH/SECURITY)

## Defect

The legacy JSON string escaper in `output.zig` does not escape control characters (0x00–0x1F), producing invalid JSON that strict parsers reject. The v3 writer is unaffected (uses `std.json.Stringify.value`).

## Evidence

**`output.zig:991-1002` — `writeJsonStringContents`:**

```zig
fn writeJsonStringContents(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),  // <-- raw emit, no C0 escape
        }
    }
}
```

RFC 8259 Section 7: "All Unicode characters may be placed within the quotation marks, except for the characters that must be escaped: quotation mark, reverse solidus, and the control characters (U+0000 through U+001F)."

**Affected output paths** (all use `writeJsonString` → `writeJsonStringContents`):
- v1 sentinel (`writeSearchReport`)
- v2 agent format (`writeSearchReportAgent`)
- `--json` full report (`writeSearchJsonReport`)
- `writeSearchHits` (text path)
- `writeInspectWindow`, `writeInspectContext`
- `writeExplain`
- `writeMatchesJsonHits`
- All telemetry sub-objects (slowest files, access error samples)

**Unaffected paths** (use `std.json.Stringify.value` directly):
- v3 (`agent_output.zig:157`)
- `similar` output (`similar.zig:594`)

## Attack Vector

The binary sniff in `search.zig` only checks the first 1024 bytes for NUL:
- `search.zig:4722`: `simd.indexOfByte(read_buffer[0..@min(1024, first_read)], 0)`

A text file that has no NUL in its first 1 KiB but contains a NUL byte (or form feed 0x0C, vertical tab 0x0B, ESC 0x1B) later passes admission. When a matching line straddles that byte, it flows into `hit.preview` and reaches `writeJsonStringContents`. The raw control byte is emitted in the JSON string, breaking the document.

## Impact

Any JSON consumer of v1/v2/inspect/explain/`--json` output will fail to parse results when a matched line contains control characters. This includes:
- `std.json.parseFromSlice` (Zig)
- `JSON.parse()` (most JavaScript runtimes)
- `jq`
- Agent harness JSON parsers

The agent receives either a parse error or silently truncated data. For a local LLM consuming `--agent` (v2) output, this is a data-integrity failure.

## Fix

Replace the body of `writeJsonString` in `output.zig:985-990` with:

```zig
fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
```

Or at minimum, add a `default` branch in `writeJsonStringContents` that escapes bytes < 0x20 as `\u00XX`:

```zig
else => {
    if (byte < 0x20) {
        try writer.print("\\u{x:0>4}", .{byte});
    } else {
        try writer.writeByte(byte);
    }
},
```

## Verification

```bash
# Create a file with a form-feed after byte 1024:
python -c "open('test_ff.txt','wb').write(b'x'*1024 + b'\x0cneedle')"
./zig-out/bin/ix-zig.exe search 'lit:needle' test_ff.txt --json | jq .
# Before fix: jq fails to parse (invalid JSON)
# After fix: jq parses successfully
```
