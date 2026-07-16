---
type: goal
date: 2026-07-15
branch: develop-subzero
status: active
owner: agent-context
epic: ix-min-context-compaction
completion_model: evidence_backed_capability
source_request:
  - "ix inherited a feature from the dupe audit skill called ix similar."
  - "im thinking of a ix minify (min) command for use when files are too big"
  - "start a goal with at least 12 paragraphs of doctrine"
  - "mention for research, source proof (citation), proving knowledge is valuable, and aligned with what the arch expects"
---

# Goal 002 — Native Large-File Context Compaction

Build and prove a native `ix min` command for bounded, information-dense reading of oversized text and source files. The capability exists to let an agent understand a file that is too large for direct ingestion while preserving a deterministic path back to exact source. This goal covers research, architecture, implementation, output contracts, adversarial validation, benchmarks, documentation, and installed-path proof. It does not authorize a Python runtime dependency, an opaque model summary, or a second inspection system beside IX’s existing owners.

Doctrine 1 — Source truth precedes design. Begin with the current checkout, active worktree, `AGENTS.md`, `.docs/log.txt`, command registry in `src/cli/args.zig`, dispatch in `src/main.zig`, output ownership in `src/cli/output.zig`, exact inspection in `src/core/inspect.zig`, query-guided context in `src/core/xo.zig`, semantic ranking in `src/core/similar.zig`, and shared limits in `src/core/resource_profile.zig`. Treat remembered behavior, prior chat, and inherited skill descriptions as starting signals only; current source and executable probes decide what IX supports.

Doctrine 2 — Research is a blocking architectural input. Before executable logic changes, study primary papers, original algorithms, high-quality systems articles, and maintainer-grade implementations covering extractive compression, structural deduplication, maximal repeated sequences, document segmentation, evidence scoring, succinct text representation, bounded context assembly, and reconstruction-preserving summarization. Research belongs in the repository’s canonical `.docs/research/` ledger so a cold-starting maintainer can inspect it without recovering this conversation.

Doctrine 3 — Every adopted mechanism carries source proof. Each architectural decision must cite a primary paper, official specification, or exact reference implementation with a stable URL, repository path or commit identifier, license, and the precise mechanism reused. A source citation is not decorative authority: it must let the next maintainer recover the source, inspect the original evidence, distinguish copied mechanism from local adaptation, and challenge the conclusion when stronger evidence appears.

Doctrine 4 — Research must prove that the knowledge is valuable. Every harvested source must state what decision it changes, what capability it enables, which competing hypothesis it weakens or defeats, and what benchmark or adversarial test could falsify its value. A reference that produces no measurable improvement in preservation, compression, determinism, resource use, provenance, or maintainability does not earn a place in the design. Source count is not knowledge value; decision-changing evidence is.

Doctrine 5 — IX architecture is the acceptance frame. The command must align with IX’s native Zig command grammar, canonical command registry, read-only inspection boundary, shared allocator and thread ceilings, deterministic output posture, typed failures, agent-facing projections, and exact-versus-lossy distinction. `ix min` must not invoke the local intelligent-compactor skill by path, shell out to Python, require an ambient Codex installation, silently contact a provider, or create an independent discovery and admission pipeline.

Doctrine 6 — Compaction is not truncation and not summarization theater. The command must retain complete structural units, expose omissions, and never substring-cut unique retained material merely to satisfy an output budget. It must identify itself as a lossy projection whenever unique content can be omitted. Generated prose, heuristic retention, or a high compression ratio never becomes source truth, and the command must not return a success-shaped envelope that conceals incomplete traversal or budget failure.

Doctrine 7 — Exact source remains addressable. Every retained block must carry exact source line ranges or another deterministic reference into the original file, allowing an agent to move directly from compacted evidence to `ix inspect` for verification. Compact output that flattens code, removes source coordinates, or makes the original location unrecoverable fails the IX reading contract even if it saves many tokens. The compaction lane selects evidence; exact inspection remains the truth owner.

Doctrine 8 — `low`, `med`, and `high` are typed policies rather than subjective labels. `low` emphasizes exact and proven-template deduplication plus conservative whitespace reduction while retaining unique units. `med` may perform evidence-weighted structural retention while protecting reconstruction-critical material. `high` is emergency compression with visible loss accounting, stronger proof requirements, and no implication of standalone fidelity. Thresholds, preservation floors, and profile names live in one canonical owner and receive independent regression tests.

Doctrine 9 — Core behavior is local and deterministic. Identical input bytes, configuration, IX version, and relevant platform normalization must produce identical retained units, ordering, hashes, omission records, and reports. The core command requires no embedding model, reranker, GGUF runtime, API key, network service, or probabilistic model. Any future model-assisted extension is a separately declared provider boundary and may never override hard-preserve rules without an explicit caller policy and visible provenance.

Doctrine 10 — Large-file behavior must actually be bounded. Do not import the intelligent-compactor’s whole-file Python read pattern into IX. Use streaming or bounded-memory segmentation under the framework-wide resource ceiling, and define behavior for pathological long lines, invalid UTF-8, binary input, huge repeated templates, low-redundancy prose, output budgets, and allocation pressure. Incomplete traversal returns typed coverage; it does not silently become a complete-looking summary.

Doctrine 11 — Preservation rules protect reconstruction value. Paths, commands, flags, hashes, metrics, formulas, errors, API contracts, invariants, headings, declarations, function and type names, decisions, blockers, and user requirements receive explicit protection appropriate to the document class. Negation and obligation terms such as `not`, `never`, `must`, `only`, and `without` are meaning-bearing evidence and must not disappear through generic stop-word or filler-removal policy.

Doctrine 12 — Reuse the strongest existing IX owners. Share admission, binary detection, path normalization, ignore and protected-path policy, output serialization, resource controls, source-coordinate conventions, and typed coverage where their contracts fit. `inspect` remains exact bounded windows, `xo` remains query-guided context selection, `similar` remains separately declared semantic ranking, and `min` owns query-free whole-document compaction. If an existing owner can absorb a typed option without confusing its contract, prefer that repair over adding surface.

Doctrine 13 — Measure value and damage together. Establish labeled corpora for Zig and other source code, Markdown, JSONL logs, benchmark journals, generated or minified text, pathological long lines, repeated templates, and low-redundancy prose. Measure input and output bytes, estimated tokens, runtime, peak memory, deterministic repeatability, required-fact retention, coordinate fidelity, and false omission of labeled critical knowledge. Compression ratio alone cannot select a profile or prove that the capability is useful.

Doctrine 14 — Tests protect the contract rather than the shortcut. Add parser, profile, segmentation, deduplication, preservation, budget, output-schema, determinism, malformed-input, binary, UTF-8, long-line, resource-limit, and exact-follow-up tests. Include adversarial fixtures where one negation, metric, error, path, hash, or requirement changes the meaning. Make the implementation pass the tests; do not weaken preservation assertions to accommodate a lossy mechanism.

Doctrine 15 — Capability truth spans every advertised surface. Wire top-level help, command help, shell completions, README, repository `SKILL.md`, stable machine output, and MCP only where the capability genuinely works. Unsupported surfaces remain explicitly unsupported rather than returning placeholders. The primary path stays short — `ix min PATH --level med` — while byte budgets, preserve patterns, audits, and structured formats remain progressively disclosed.

Doctrine 16 — Completion requires proof through the real owner path. Build with the declared Zig toolchain, run targeted and widened tests, compare against the intelligent-compactor on labeled corpora without inferring semantic parity from size reduction, manually inspect outputs for knowledge loss, verify typed failure behavior, and exercise the installed binary when promotion is in scope. Separate locally proven capability from experimental profiles, unverified platforms, and external blockers.

Doctrine 17 — Preserve current work and durable continuity. The checkout already contains user-owned changes; work around them without destructive Git operations, broad cleanup, or accidental normalization. Update existing research, goal, progress, changelog, README, and skill owners as truth changes. Do not create parallel ledgers, duplicate command registries, or architecture decisions that survive only in chat.

Doctrine 18 — The capability must earn its surface. Ship `ix min` only if evidence shows it gives agents a materially better query-free oversized-file reading path than bounded `inspect` and query-guided `xo`, while remaining native, deterministic, attributable, resource-bounded, and honest about loss. If the research and benchmark program shows that a separate command adds more cognitive and maintenance surface than user value, reject it with cited evidence or fold the proven mechanism into the correct existing owner.

## Completion contract

This goal closes only when the research ledger contains decision-changing cited sources, the selected architecture is explicitly reconciled with current IX owners, every profile has measurable preservation and damage evidence, the native command passes its adversarial contract, all advertised surfaces agree, and the real CLI path demonstrates useful bounded reading on representative oversized files. A command that merely compiles, emits shorter text, or mirrors the Python skill without IX provenance and resource guarantees does not satisfy the goal.
