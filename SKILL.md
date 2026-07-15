---
name: ix
description: Agent-native repository search, exact bounded inspection, expression explanation, and bounded semantic similarity.
---

# IX

IX searches repository content and returns evidence that can be inspected exactly. Search and inspect are read-only. Use a separate editing tool for mutations.

## Operating order

1. Compose one expression with `lit:`, `re:`, `prefix:`, `suffix:`, `&&`, or `||`.
2. Search the narrowest useful roots.
3. Use `--format agent-v3` when the result needs explicit coverage, exact spans, byte budgets, or continuation.
4. Continue only with the returned opaque `--cursor`; restart without it if IX reports a stale or mismatched cursor.
5. Use `inspect` for exact source windows before changing code.
6. Use `explain` when the selected matcher route matters.

## Search

```sh
ix search 'lit:SearchConfig && re:validate|parse' src -j 8 --format agent-v3 --max-hits 80
ix search 're:token_[0-9]+' src --format agent-v3 --max-bytes 8192
ix search 'lit:owner' src --context 2 --format json-compact
```

`--agent` preserves the compact `ix.result.v2` compatibility format. `--format agent-v3` emits one `ix.result.v3` envelope with separate verification, scan, and projection facts. `--format json-compact` emits the same v3 object without sentinel framing. `--json` remains the full compatible telemetry format.

Fisheye contraction applies only to search previews. The exact match remains visible and v3 records the represented source window. `inspect` windows and `search --context` lines are exact and are never fisheye-contracted.

## Exact inspection

```sh
ix inspect src/main.zig --range 40:80
ix inspect --expr 'lit:SearchConfig' src --context 2 --json
```

Honor `ix.next.v1` continuation hints for bounded file windows. Do not infer omitted lines from a preview.

## Semantic similarity

```sh
ix similar 'cancellation ownership' src --format agent-v3 --candidate-budget 128
```

The versioned semantic contract reports eligible/read files, embedded ranges, provider bytes, policy skips, omissions, and continuation. Lexical path evidence prioritizes the bounded union frontier but never excludes semantically eligible files. Whole-file ranges remain the default until a labeled recall, latency, and cost benchmark proves a chunk policy.

## Warm and cold lanes

Cold discovery and warm-index frontiers must preserve match and route parity. Versioned output may impose deterministic ordering, but it must not disable the warm frontier. Performance claims require same-query, same-corpus measurements for both lanes and a valid predecessor.

Set `"warm": true` in `~/.ix/config.json` for persistent activation. `IX_INDEX=1` or `IX_INDEX=0` overrides config for a process. A warm measurement is valid only when telemetry reports the warm route; a repeated cold process scan is not a warm sample.
