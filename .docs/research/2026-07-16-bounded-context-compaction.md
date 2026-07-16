---
type: research
status: complete
date: 2026-07-16
subject: deterministic bounded compaction of oversized text
question: "Which proven mechanisms can shorten an oversized text file while preserving attributable structural evidence under fixed memory and output budgets?"
method: "Primary-paper review, pinned source-code autopsy, and adversarial transfer analysis"
source_classes:
  - primary papers
  - pinned reference implementations
  - current tool behavior
raw_search_evidence: raw/context-compaction/
---

# Deterministic Bounded Context Compaction

## Research contract

This capture separates extractive evidence selection from source truth. A useful compactor emits complete source units with coordinates and visible omission records; it does not rewrite retained text, imply completeness after partial traversal, or treat a smaller byte count as semantic proof. Every source below records the decision it changes, the capability it enables, the alternative it defeats, and the observation that would falsify its value.

## Primary sources

### 1. Submodular coverage and diversity

- Citation: Hui Lin and Jeff Bilmes, “A Class of Submodular Functions for Document Summarization,” ACL 2011, https://aclanthology.org/P11-1052/
- Mechanism: monotone submodular objectives combine representative coverage with diversity; greedy selection supplies a bounded approximation for a fixed summary budget.
- Decision changed: rank complete structural units by marginal information gain per byte instead of independent salience alone.
- Capability enabled: a selected set can cover more distinct evidence while penalizing repeated units.
- Alternative defeated: top-N scoring, which can spend the budget on near-duplicates.
- Falsifier: on labeled fixtures, marginal-gain selection retains fewer required facts than stable top-N at the same output budget.
- Transfer boundary: the objective shape transfers; learned similarity and corpus-specific tuning do not.

### 2. Local duplicate fingerprints

- Citation: Saul Schleimer, Daniel S. Wilkerson, and Alex Aiken, “Winnowing: Local Algorithms for Document Fingerprinting,” SIGMOD 2003, https://www.cs.princeton.edu/courses/archive/spr05/cos598E/bib/p76-schleimer.pdf
- Mechanism: minima selected from rolling-hash windows create local fingerprints with explicit substring-detection guarantees.
- Decision changed: treat content-defined fingerprints as duplicate-candidate evidence, never as equality proof.
- Capability enabled: repeated templates can be detected without storing every byte sequence as a key.
- Alternative defeated: unbounded tables containing every shingle.
- Falsifier: hash-collision fixtures cause distinct units to merge, or bounded tables miss enough repeated templates to erase the byte-saving advantage.
- Transfer boundary: local candidate generation transfers; exact byte comparison remains mandatory before omission.

### 3. Bounded streaming frequency estimates

- Citation: Graham Cormode and S. Muthukrishnan, “An Improved Data Stream Summary: The Count-Min Sketch and its Applications,” Journal of Algorithms 2005, https://dimacs.rutgers.edu/~graham/pubs/html/CormodeMuthukrishnan04CMJalg.html
- Mechanism: fixed-width, fixed-depth counters estimate item frequency in a stream with one-sided overestimation.
- Decision changed: a fixed sketch may support rarity scoring when exact vocabulary cardinality would violate the memory ceiling.
- Capability enabled: deterministic, bounded token-frequency evidence in a two-pass reader.
- Alternative defeated: a vocabulary-sized hash map with input-dependent memory growth.
- Falsifier: collision-heavy fixtures depress unique-token scores enough to omit protected or labeled-critical units.
- Transfer boundary: bounded counters transfer; estimates may only lower soft rarity and must never override hard preservation.

### 4. Graph-based centrality

- Citation: Rada Mihalcea and Paul Tarau, “TextRank: Bringing Order into Text,” EMNLP 2004, https://aclanthology.org/W04-3252/
- Mechanism: graph centrality ranks textual units by similarity-linked endorsement without supervised labels.
- Decision changed: reject a full pairwise graph in the native baseline because its memory and quadratic similarity surface conflict with oversized-file bounds.
- Capability enabled: provides a comparator for whether cheaper coverage scoring sacrifices central evidence.
- Alternative defeated: adopting PageRank merely because it is unsupervised.
- Falsifier: a bounded sparse graph materially improves required-fact retention at equal memory, runtime, and output budgets.
- Transfer boundary: centrality is evaluation knowledge; the graph runtime is not selected for the initial core.

### 5. Frequency-based sentence significance

- Citation: H. P. Luhn, “The Automatic Creation of Literature Abstracts,” IBM Journal of Research and Development 2(2), 1958, https://www.ibm.com/watson/assets/pdfs/ibmrd0204H.pdf
- Mechanism: significant-word frequency and proximity identify high-information passages for extractive abstracts.
- Decision changed: retain lexical rarity and obligation density as transparent salience features rather than using opaque generated summaries.
- Capability enabled: query-free evidence scoring with explainable integer components.
- Alternative defeated: position-only retention.
- Falsifier: rarity and obligation features do not improve critical-fact recall over boundary-only baselines on mixed code, prose, and log fixtures.
- Transfer boundary: transparent frequency evidence transfers; language-specific stop-word assumptions do not.

### 6. Maximal marginal relevance

- Citation: Jaime Carbonell and Jade Goldstein, “The Use of MMR, Diversity-Based Reranking for Reordering Documents and Producing Summaries,” SIGIR 1998, https://aclanthology.org/anthology-files/pdf/X/X98/X98-1025.pdf
- Mechanism: greedy selection balances relevance against maximum similarity to already selected material.
- Decision changed: use novelty against the retained set as a tie-break/penalty, preserving original source order only after selection.
- Capability enabled: repeated high-salience boilerplate cannot crowd out distinct evidence.
- Alternative defeated: independent ranking with post-hoc exact deduplication only.
- Falsifier: novelty penalties lower labeled-fact retention or destabilize selection under equivalent units.
- Transfer boundary: the relevance-minus-redundancy form transfers; query dependence does not.

### 7. Content-defined chunking boundary evidence

- Citation: Wen Xia et al., “FastCDC: a Fast and Efficient Content-Defined Chunking Approach for Data Deduplication,” USENIX ATC 2016, https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia
- Mechanism: rolling content-defined boundaries remain stable under insertions and accelerate deduplication.
- Decision changed: reject content-defined chunks as the primary readable unit, while retaining the paper as evidence for bounded duplicate candidate windows.
- Capability enabled: a future template detector can tolerate shifted repeated blocks.
- Alternative defeated: exposing arbitrary hash-cut fragments as human-readable evidence.
- Falsifier: structural boundary detection proves unable to control pathological unit sizes while content-defined boundaries preserve readability and coordinates.
- Transfer boundary: boundary-shift resilience transfers only to duplicate admission, not presentation.

## Pinned implementation anatomies

### 8. Repomix

- Citation: `yamadashy/repomix` at `a5577d5718b1e88940b71d17fe9842ea45382a3a`, MIT; local source `src/core/treeSitter/parseFile.ts` and `src/core/treeSitter/parseStrategies/DefaultParseStrategy.ts`.
- Mechanism: whole-file Tree-sitter parsing, language queries selecting names/comments/imports, exact chunk de-duplication, adjacent capture merging, and best-effort fallback to original content.
- Decision changed: syntax captures are a valuable optional structural adapter, but unsupported or failed parsing must fall back to generic segmentation rather than silently changing fidelity.
- Capability enabled: declaration-level compaction for supported languages with complete captured ranges.
- Alternative defeated: making one parser grammar the universal text owner.
- Falsifier: generic segmentation matches structural retention on supported source files, or parser setup exceeds its preservation benefit.
- Transfer boundary: capture categories and failure honesty transfer; WASM, Node workers, whole-file strings, and content-only output do not.

### 9. Aider repository map

- Citation: `Aider-AI/aider` at `5dc9490bb35f9729ef2c95d00a19ccd30c26339c`, Apache-2.0; local source `aider/repomap.py`.
- Mechanism: Tree-sitter definitions/references form a personalized graph; rare identifiers influence weights; ranked tags are fitted to a token budget by bounded search.
- Decision changed: budget fitting and identifier rarity transfer, while repository-wide graph ranking is rejected for a generic single-file command.
- Capability enabled: predictable output-budget convergence and stronger declaration weighting.
- Alternative defeated: emit-then-byte-truncate.
- Falsifier: direct greedy byte accounting is more stable and equally budget-efficient, or identifier rarity adds no labeled preservation value.
- Transfer boundary: budget search and structural salience transfer; NetworkX, repository graph state, and query personalization do not.

### 10. LLMLingua

- Citation: `microsoft/LLMLingua` at `e0e9d99beb94098bbd924aa53c2c112eac41c758`, MIT; local source `llmlingua/prompt_compressor.py`.
- Mechanism: model/tokenizer-driven context, sentence, and token filtering with target tokens, forced contexts, keep-first/last controls, ordering, and compression accounting.
- Decision changed: adopt explicit force-preserve policy and origin/compressed accounting, but reject learned token deletion from the deterministic native core.
- Capability enabled: profile reports distinguish requested budget, achieved size, forced material, and lossy stages.
- Alternative defeated: importing a model-backed compressor or claiming exact target-token achievement.
- Falsifier: an embedded model can meet deterministic, offline, dependency, memory, provenance, and exact-coordinate contracts better than extractive selection.
- Transfer boundary: preservation controls and accounting transfer; Python, model weights, tokenizer dependence, and token-level rewriting do not.

### 11. Gitingest

- Citation: `cyclotruc/gitingest` at `4e259a02fe72115bee538271622f1234a81c8e1a`, MIT; local source `src/gitingest/ingestion.py` and `src/gitingest/output_formatter.py`.
- Mechanism: deterministic tree traversal with file-count, depth, per-file, and total-byte limits; concatenated full content and tokenizer-based size reporting.
- Decision changed: resource ceilings and typed skip accounting belong before formatting, but skipping oversized files is not a compaction mechanism.
- Capability enabled: explicit traversal/resource status and reproducible ordering.
- Alternative defeated: treating a packer’s max-file-size skip as successful understanding of the file.
- Falsifier: no adversarial input can make unbounded concatenation or tokenization exceed the declared process ceiling.
- Transfer boundary: preflight limits and accounting transfer; whole-corpus materialization and external tokenizer behavior do not.

### 12. Code2Prompt

- Citation: `mufeedvh/code2prompt` at `ab4fa06f6fdb9d65c6e713480ba149f8c3fca489`, MIT; local source `crates/code2prompt-core/src/session.rs` and `crates/code2prompt-core/src/file_processor/default.rs`.
- Mechanism: one session owner coordinates selection, file processing, templates, token counts, and an optional entity map; decoded content may replace invalid byte sequences.
- Decision changed: maintain one typed session/result owner, but reject lossy character replacement because source coordinates and hashes must refer to exact bytes.
- Capability enabled: coherent metadata and output projections from one result model.
- Alternative defeated: separate human and machine compaction implementations.
- Falsifier: shared result ownership prevents required streaming or forces unbounded retained content.
- Transfer boundary: orchestration and entity-map concepts transfer; encoding replacement and full prompt rendering do not.

### 13. Files-to-prompt

- Citation: `simonw/files-to-prompt` at `1b234ff6dccb2ca3e56b5c256696558fb85306dc`, Apache-2.0; local source `files_to_prompt/cli.py`.
- Mechanism: sorted traversal, ignore filters, whole-file reads, optional line numbers, and collision-safe Markdown fence selection.
- Decision changed: preserve deterministic framing and source line visibility, while rejecting whole-file reads and format-only token reduction as compaction.
- Capability enabled: readable exact-source blocks whose delimiters cannot be confused with retained content.
- Alternative defeated: raw concatenation without robust framing.
- Falsifier: structured machine output alone serves human inspection as clearly with lower overhead.
- Transfer boundary: stable ordering and delimiter safety transfer; recursive packer scope and whole-file materialization do not.

## Selected architecture

The evidence supports a deterministic two-pass extractive pipeline. Pass one streams bytes through UTF-8 validation, source hashing, line/structural-unit detection, fixed-memory lexical frequency evidence, and duplicate-candidate fingerprints. Pass two replays the file, verifies duplicate candidates by exact bytes, computes explainable integer salience and marginal novelty, and emits only complete selected units. Selection is budget-aware before rendering; retained units return to source order. A parser adapter may improve supported source files, but generic document boundaries remain the baseline and failure fallback.

Three profiles should differ by admissible loss, not adjectives. The conservative profile may remove only verified duplicate units and reducible whitespace; if unique complete units cannot fit, it returns a typed budget failure. The balanced profile may omit low-marginal-value unique units while hard-preserving obligations, identifiers, headings, paths, commands, hashes, metrics, errors, and boundary context. The emergency profile raises omission pressure but keeps the same hard-preserve floor and reports itself as lossy. No profile rewrites retained bytes.

The initial core should not include PageRank, model inference, embeddings, token deletion, content-defined presentation chunks, or approximate equality. These mechanisms either violate bounded native operation, damage exact attribution, or solve a different problem. Count-Min rarity and local fingerprints remain conditional optimizations: direct bounded tables are preferred until benchmark pressure proves the more complex mechanism valuable.

## Required falsification program

- Compare structural boundaries, fixed-size line groups, and parser-assisted units on labeled code, prose, logs, and generated files.
- Compare top-score, exact-dedup-only, marginal-coverage, and novelty-penalized selection at identical byte budgets.
- Inject hash collisions and repeated-prefix/different-suffix units; no distinct unit may be omitted as a duplicate.
- Inject negation, requirements, paths, commands, hashes, metrics, and error strings as single meaning-changing facts.
- Exercise invalid UTF-8, NUL/binary input, one-line multi-megabyte text, empty files, allocation pressure, and output budgets smaller than one protected unit.
- Prove deterministic byte-for-byte output across repeated runs and stable source coordinates against exact inspection.
- Measure peak memory, passes, bytes read, runtime, output bytes, required-fact recall, omission precision, and metadata overhead. Compression ratio alone cannot select the design.
