---
type: product-report
id: pass-025-600-item-product-achievement-challenge-breakthrough-performance
status: complete
date: 2026-07-16
scope: ix-zig
evidence_band: current-repo-plus-provenance-qualified-history
---

# IX — 600 product achievements, challenges, breakthroughs, and performance findings

This is a broad product inventory, not a line-by-line implementation changelog. “Achievement” means a capability or operating advantage evidenced in the current product. “Breakthrough” means a decision or mechanism that materially changed the product’s ceiling. “Challenge” means a limitation, correction, or proof boundary that remains relevant. Historical performance figures are labeled as retained benchmark evidence; fresh figures are from the installed `ix 2.0.0` binary on 2026-07-16.

## 1–30 — Product identity and strategic positioning

1. [Achievement] IX has matured from a language port into an original native search product with its own architecture.
2. [Achievement] The product has a clear promise: find relevant source evidence while avoiding unnecessary work and context.
3. [Achievement] IX treats repository search as an execution engine rather than a thin wrapper over generic libraries.
4. [Achievement] The product’s technical identity is grounded in CPU, memory-hierarchy, and filesystem behavior.
5. [Achievement] IX now spans search, exact inspection, context selection, semantic ranking, compaction, explanation, and process operations.
6. [Achievement] The product addresses both human terminal use and machine/agent consumption from one native binary.
7. [Achievement] IX has a distinctive evidence-first identity instead of presenting search results as unqualified truth.
8. [Achievement] The architecture distinguishes exact verification from lossy presentation, which reduces false confidence.
9. [Achievement] IX presents itself as a repository-understanding substrate rather than only a text matcher.
10. [Achievement] The product has moved beyond raw matching into admission, routing, ranking, proof, and bounded reading.
11. [Achievement] IX’s scope is coherent: each command owns a different repository-retrieval job instead of duplicating one generic search mode.
12. [Achievement] The product has a strong offline-first core with no package-manager requirement at runtime.
13. [Achievement] Native execution keeps the core search path independent of hosted services and API credentials.
14. [Achievement] Optional semantic capability is separated from mandatory exact-search capability.
15. [Achievement] IX’s product voice now explains value in terms of ignored work, retained evidence, and agent context.
16. [Achievement] The README has evolved into a serious product surface rather than a feature dump.
17. [Achievement] The root skill gives agents an operational path from query to exact verification.
18. [Achievement] The product has an explicit architecture pipeline from arguments through output rather than an opaque command blob.
19. [Achievement] IX’s positioning reflects both speed and epistemic reliability, not speed alone.
20. [Achievement] The product has a measurable context-economy story for AI-assisted engineering.
21. [Achievement] IX has developed a recognizable vocabulary around cold, warm, exact, lossy, canonical, partial, and truncated states.
22. [Achievement] Product capability is represented across executable help, README, skill instructions, tests, and reports.
23. [Achievement] The project has a sustained history of converting experimental mechanisms into named product lanes.
24. [Achievement] IX is designed to scale from one-file inspection to multi-gigabyte repository search.
25. [Achievement] The product treats resource restraint as a user-facing policy rather than an afterthought.
26. [Achievement] IX’s roadmap connects immediate usability with advanced indexing, I/O, and algorithmic research.
27. [Achievement] The project has resisted becoming a collection of disconnected optimization demos.
28. [Achievement] Product decisions increasingly preserve one canonical owner for each class of behavior.
29. [Breakthrough] The project recognized that agent retrieval needs different output and continuation contracts than human grep output.
30. [Breakthrough] IX’s strongest strategic shift was from “scan everything faster” to “prove what can be skipped safely.”

## 31–60 — Consumer and operator experience

31. [Achievement] The command set gives users an obvious starting point for exact search.
32. [Achievement] Human-readable help now names the main retrieval lanes and their intended jobs.
33. [Achievement] The product supports compact machine-readable output without forcing humans to read JSON.
34. [Achievement] Errors use stable codes and recovery hints instead of unstructured failure prose.
35. [Achievement] Zero-match searches are represented as valid completed requests rather than operational failures.
36. [Achievement] Partial filesystem access is distinguished from a complete no-match result.
37. [Achievement] Output truncation is represented separately from scan completeness.
38. [Achievement] Users can request bounded results without accepting broken records or silently cut payloads.
39. [Achievement] Continuation tokens provide a stable next step when a result does not fit one response.
40. [Achievement] Exact inspection keeps users from treating search previews as source truth.
41. [Achievement] Search context can be added without requiring a second unrelated tool.
42. [Achievement] The product provides sensible command defaults while retaining explicit controls for advanced users.
43. [Achievement] IX supports one obvious path for common literal searches and richer syntax only when needed.
44. [Achievement] The product’s `--version` behavior is consistent enough to function as an installation handshake.
45. [Achievement] Help text now separates global concepts from command-specific controls.
46. [Achievement] Agent-oriented examples show the intended search-to-inspect workflow directly.
47. [Achievement] The product gives operators typed process-status and cleanup surfaces.
48. [Achievement] Installation promotion preserves rollback evidence rather than overwriting the prior binary blindly.
49. [Achievement] The Windows install owner is a single predictable path under the user profile.
50. [Achievement] The current installed binary reports `ix 2.0.0` successfully.
51. [Achievement] The installed binary and repository ReleaseFast binary currently share the same SHA-256.
52. [Achievement] Configuration supports persistent defaults and per-process overrides.
53. [Achievement] Memory and thread controls can be tuned independently.
54. [Achievement] The product exposes lossy behavior explicitly instead of burying it in preview formatting.
55. [Achievement] Long minified lines no longer consume an entire agent context by default.
56. [Achievement] Exact match text remains visible even when surrounding previews contract.
57. [Achievement] UTF-8 boundaries are respected in user-facing preview contraction.
58. [Achievement] The product includes clear recovery guidance when semantic ranking lacks credentials.
59. [Challenge] The breadth of commands raises onboarding pressure and makes command-role clarity continuously important.
60. [Challenge] Advanced telemetry remains powerful but can overwhelm users unless progressive disclosure stays disciplined.

## 61–90 — Command portfolio and workflow coverage

61. [Achievement] `search` owns exact repository matching and terminal result truth.
62. [Achievement] `inspect` owns exact bounded source reading.
63. [Achievement] `xo` owns query-guided context selection for agents.
64. [Achievement] `min` owns query-free bounded compaction of one oversized file.
65. [Achievement] `similar` owns semantic and anti-similarity ranking when a provider is configured.
66. [Achievement] `explain` exposes the execution plan behind a query.
67. [Achievement] `why` provides a product direction for explaining indexed lineage.
68. [Achievement] `watch` provides a product direction for streaming repository changes.
69. [Achievement] `replace` provides an indexed rewrite surface with dry-run expectations.
70. [Achievement] `diff-matches` frames change comparison around result sets instead of raw text alone.
71. [Achievement] `process` makes runtime state inspectable and cleanable.
72. [Achievement] Search and inspection can be composed without losing source coordinates.
73. [Achievement] Search and explanation share the same expression vocabulary.
74. [Achievement] Agent output can be requested directly instead of post-processing human output.
75. [Achievement] Statistics-only modes support performance and coverage diagnosis without returning hit payloads.
76. [Achievement] Record modes let users reason above individual line granularity.
77. [Achievement] AST-aware records provide a structural path for supported source languages.
78. [Achievement] Search context remains exact even though ordinary previews may be lossy.
79. [Achievement] Similarity results can be bounded by candidate and output budgets.
80. [Achievement] Anti-similarity turns the semantic lane into a drift-detection tool.
81. [Achievement] File-anchor similarity supports related-file discovery.
82. [Achievement] Query-text similarity supports concept-led repository exploration.
83. [Achievement] Compaction profiles give users conservative, balanced, and emergency choices.
84. [Achievement] The low compaction profile refuses to hide unique content when the budget is insufficient.
85. [Achievement] Medium and high compaction identify themselves as lossy when unique units are omitted.
86. [Achievement] Command outputs are designed to remain pipe-safe and machine-parseable.
87. [Achievement] The command portfolio supports both interactive discovery and deterministic automation.
88. [Challenge] Some advanced commands are advertised more broadly than their latest end-to-end proof depth.
89. [Challenge] MCP remains intentionally unchanged for compaction until a bounded tool contract is implemented and tested.
90. [Breakthrough] Separating exact, semantic, contextual, and compacted reading into distinct commands resolved a major ownership ambiguity.

## 91–120 — Query language, planning, and route selection

91. [Achievement] IX supports explicit literal, regex, prefix, and suffix query forms.
92. [Achievement] Boolean `AND` and `OR` composition lets one query replace chains of shell searches.
93. [Achievement] Bare text remains a convenient literal path for simple use.
94. [Achievement] Regex requires explicit intent, reducing accidental interpretation changes.
95. [Achievement] Query classification happens before file I/O.
96. [Achievement] The planner chooses a narrow execution strategy from query shape.
97. [Achievement] Literal queries can use specialized vectorized search instead of a generic regex engine.
98. [Achievement] Prefix and suffix queries use boundary-aware verification.
99. [Achievement] Word-boundary literals have a dedicated route rather than paying full regex cost.
100. [Achievement] Alternating literals can use multi-pattern machinery rather than repeated independent scans.
101. [Achievement] Boolean literal plans can use evidence admission before exact verification.
102. [Achievement] Regex routes can use PCRE2 JIT where appropriate.
103. [Achievement] Native regex fallback keeps the product operable without delegating every pattern externally.
104. [Achievement] The plan is available as product evidence through `explain`.
105. [Achievement] Strategy telemetry makes route behavior auditable after execution.
106. [Achievement] Query fingerprints support stable continuation and cache identity.
107. [Achievement] Route selection is separated from output formatting.
108. [Achievement] Admission mechanisms reject candidates but never manufacture matches.
109. [Achievement] Exact verification remains the final authority after an index or evidence gate admits a file.
110. [Achievement] The query grammar supports agent composition without requiring shell quoting tricks for every operation.
111. [Achievement] Ripgrep-compatible lowering eases migration from familiar command habits.
112. [Achievement] Ambiguous output and query combinations fail explicitly.
113. [Achievement] The planner exposes matcher support instead of pretending every strategy has identical acceleration.
114. [Achievement] Query-specific warm activation can avoid foreground discovery and scan work.
115. [Achievement] The same expression can be evaluated cold or through indexed admission.
116. [Challenge] Rich query composition increases the need for exhaustive parser and compatibility testing.
117. [Challenge] Route labels cannot be trusted without checking files scanned, fallback reason, and parity.
118. [Challenge] Warm-route eligibility depends on generation freshness, corpus identity, and binary compatibility.
119. [Breakthrough] Treating query shape as an ahead-of-I/O compilation problem removed branching pressure from the hot loop.
120. [Breakthrough] Treating indexes as rejection evidence rather than match authority preserved exact-search semantics.

## 121–150 — Core search architecture

121. [Achievement] IX has a clear pipeline: parse, classify, discover, admit, shard, scan, merge, and render.
122. [Achievement] Search work is partitioned before the hot scan phase.
123. [Achievement] Worker reports are thread-local, avoiding mutex contention in the scan loop.
124. [Achievement] Results merge after workers complete rather than contending on shared hit structures.
125. [Achievement] Arena allocation removes per-object lifetime management from short-lived commands.
126. [Achievement] Hot-path allocation is treated as a defect rather than routine behavior.
127. [Achievement] Stack-size pressure is tracked because Windows page probes can dominate tight loops.
128. [Achievement] Small-file I/O is optimized around avoiding unnecessary syscalls.
129. [Achievement] Large-file processing uses bounded buffers rather than whole-file assumptions.
130. [Achievement] Discovery, admission, scan, and aggregation have separate timing identities.
131. [Achievement] Root deduplication prevents redundant traversal work.
132. [Achievement] Contained roots can be pruned before discovery expands.
133. [Achievement] Dynamic work claiming reduces tail imbalance on uneven corpora.
134. [Achievement] Thread scaling adapts to corpus size instead of always using every core.
135. [Achievement] Binary and text policy decisions occur before expensive matching work.
136. [Achievement] Protected Windows paths receive special handling to avoid pathological cold opens.
137. [Achievement] Recoverable access failures are counted instead of crashing the entire request.
138. [Achievement] The product tracks slow-file evidence to make dominant latency visible.
139. [Achievement] Exact match parity is kept independent of preview contraction.
140. [Achievement] Search totals derive from canonical scan truth rather than rendered-hit counts.
141. [Achievement] Truncation applies to the projection, not to underlying match accounting.
142. [Achievement] The architecture can host multiple kernel strategies without changing the public command grammar.
143. [Achievement] Native and vendored components are linked into one build graph.
144. [Achievement] The build remains network-free when required references are present.
145. [Achievement] The project has reduced parallel implementation paths around output and context ownership.
146. [Challenge] The breadth of experimental kernels creates continuing pressure to distinguish wired production paths from prototypes.
147. [Challenge] Platform-specific I/O mechanisms cannot support cross-platform claims without separate evidence.
148. [Challenge] Very large repository histories and generated artifacts can still dominate cold discovery and scan cost.
149. [Breakthrough] The zero-mutex shard model established a durable concurrency foundation for the engine.
150. [Breakthrough] Separating canonical scan truth from bounded output projections prevented output limits from corrupting correctness.

## 151–180 — Agent-native output, truth, and provenance

151. [Achievement] IX emits a terminal result state rather than leaving agents to infer whether a command finished correctly.
152. [Achievement] Agent output groups hits by file to avoid repeated path tokens.
153. [Achievement] The compact format removes derived fields that an agent can reconstruct.
154. [Achievement] Compact telemetry avoids spending context on mostly empty counters.
155. [Achievement] Full telemetry remains available when diagnosis requires it.
156. [Achievement] Machine output uses schema identifiers for contract stability.
157. [Achievement] Verification state is represented independently from scan state.
158. [Achievement] Scan completeness is represented independently from projection completeness.
159. [Achievement] Access-error counts remain visible even when useful results are returned.
160. [Achievement] Continuation cursors are bound to the request and corpus state.
161. [Achievement] Stale cursors are rejected rather than applied to changed source.
162. [Achievement] Byte budgets fit complete records instead of truncating JSON arbitrarily.
163. [Achievement] Exact source coordinates survive agent-oriented output reduction.
164. [Achievement] Context lines requested through exact search remain uncontracted.
165. [Achievement] Fisheye previews declare elision visibly.
166. [Achievement] Match substrings remain complete inside contracted previews.
167. [Achievement] Agent consumers can branch on typed failure modes instead of parsing prose.
168. [Achievement] Statistics can be requested without hit records for low-noise operational checks.
169. [Achievement] Output digests support repeatability and comparison.
170. [Achievement] Compact JSON supports downstream automation without terminal decoration.
171. [Achievement] Human and machine formats share the same canonical report owner.
172. [Achievement] Similarity output exposes candidate coverage and continuation rather than implying exhaustiveness.
173. [Achievement] Compaction output includes source SHA-256 and omission ranges.
174. [Achievement] The product explicitly labels lossy transformations.
175. [Achievement] Exact inspect remains the prescribed follow-up after a lossy lens.
176. [Performance] The grouped agent format reduced a measured 72-hit result from 26,671 bytes to 6,370 bytes.
177. [Performance] That agent projection achieved a measured 4.2× reduction against standard JSON.
178. [Performance] Fisheye contraction can reduce a 10 KiB minified line by roughly 143× while retaining the match.
179. [Challenge] More schemas increase compatibility obligations across help, clients, tests, and downstream consumers.
180. [Breakthrough] Making truth dimensions explicit turned output format from decoration into a core product capability.

## 181–210 — Inspection, context selection, and oversized-file reading

181. [Achievement] Exact inspection provides bounded line ranges for targeted source reading.
182. [Achievement] Inspection supports match-centered context without surrendering byte fidelity.
183. [Achievement] Inspection emits continuation hints for large files.
184. [Achievement] Inspection remains read-only and separate from rewrite operations.
185. [Achievement] `xo` converts natural-language intent into a bounded evidence view.
186. [Achievement] `xo` removes low-value conversational glue before ranking source terms.
187. [Achievement] BM25 supplies a transparent lexical relevance baseline for context selection.
188. [Achievement] Structural and path priors break ties without overriding strong lexical evidence.
189. [Achievement] Anti-clustering prevents one dense region from consuming the entire context projection.
190. [Achievement] Context expansion uses degree-of-interest rather than a fixed arbitrary window.
191. [Achievement] `xo` reports coverage so agents can see whether the projection is partial.
192. [Achievement] `min` gives agents a query-free first read of oversized files.
193. [Achievement] `min` streams source evidence without materializing the entire file in memory.
194. [Achievement] Compaction retains complete source units rather than slicing arbitrary substrings.
195. [Achievement] Retained compaction blocks preserve exact bytes and source order.
196. [Achievement] Omitted compaction ranges remain addressable through line and byte coordinates.
197. [Achievement] Byte-verified duplicate removal avoids treating hash equality as content equality.
198. [Achievement] Lexical rarity helps distributed evidence compete with repetitive boilerplate.
199. [Achievement] Obligation, path, command, metric, error, and declaration signals influence retention transparently.
200. [Achievement] First and last document regions receive explicit boundary protection.
201. [Achievement] The complete serialized output, including metadata, obeys the requested byte cap.
202. [Achievement] An undersized conservative request fails with empty stdout instead of a misleading fragment.
203. [Achievement] Invalid UTF-8 and binary input have typed compaction failures.
204. [Achievement] Multi-megabyte single lines remain whole-or-fail units.
205. [Achievement] Compaction is deterministic for identical input and settings.
206. [Performance] Medium compaction beat equal-byte prefix fact recall on seven of eight measured corpus shapes.
207. [Performance] Structured JSONL and benchmark-journal cases retained all labeled facts within 8 KiB projections.
208. [Challenge] A small front-loaded doctrine document favored prefix reading, defining an honest product boundary.
209. [Challenge] Compaction is evidence selection, not semantic completeness or source replacement.
210. [Breakthrough] The three-lens workflow—search, contextualize, then inspect—now also has a query-free oversized-file entry point.

## 211–240 — Warm index, persistence, and freshness

211. [Achievement] IX has a persistent index architecture rather than relying exclusively on foreground scans.
212. [Achievement] Index generations are published atomically under explicit ownership.
213. [Achievement] Readers can pin generations so compaction and cleanup do not invalidate active queries.
214. [Achievement] Catalog and postings artifacts have named binary identities.
215. [Achievement] Warm admission can eliminate foreground file scanning for eligible queries.
216. [Achievement] Query caches are tied to corpus and generation evidence.
217. [Achievement] Warm activation can be controlled persistently through configuration.
218. [Achievement] A process-level override can force or disable index use for proof and diagnosis.
219. [Achievement] Index mismatch falls back rather than silently returning invented matches.
220. [Achievement] Warm paths preserve exact verification as the final match authority.
221. [Achievement] Compaction planning protects current, retained, and reader-pinned generations.
222. [Achievement] Tombstone folding removes stale catalog identities during compaction.
223. [Achievement] Generation cleanup is separated from foreground query execution.
224. [Achievement] Repair state is exposed through explicit diagnostics.
225. [Achievement] Windows journal modeling provides a path toward incremental freshness.
226. [Achievement] Journal continuity failures are classified rather than ignored.
227. [Achievement] Rename storms and duplicate deltas can be coalesced before application.
228. [Achievement] Lost cursors and journal wrap trigger reconciliation rather than partial trust.
229. [Achievement] The daemon lifecycle was repaired to republish after mutations instead of stopping after one cycle.
230. [Achievement] Benchmark readiness was changed to avoid starving index publication with repeated cold scans.
231. [Achievement] Historical installed proof demonstrated cold-to-warm transition with zero files scanned.
232. [Achievement] Historical mutation-convergence and cursor-parity gates passed on the promoted owner path.
233. [Challenge] Warm correctness depends on generation freshness after every source and binary change.
234. [Challenge] Today’s installed warm generation is stale relative to the current source tree.
235. [Challenge] Fresh `src` proof returned 887 cold matches across 52 files but 874 warm-enabled matches across 50 files.
236. [Challenge] Fresh full-root proof discovered 7,201 files cold but only 1,615 through the current warm generation.
237. [Challenge] Historical warm benchmark success cannot be projected onto the current generation without regeneration and parity proof.
238. [Challenge] Small-corpus warm routing can cost more end-to-end than a direct cold scan.
239. [Breakthrough] The project learned to define “warm” through route telemetry and zero scanned files, not labels.
240. [Breakthrough] The benchmark repair exposed index freshness as a product correctness contract, not only a speed concern.

## 241–270 — Semantic retrieval and higher-level intelligence

241. [Achievement] IX includes a semantic similarity lane alongside exact search.
242. [Achievement] Embedding and reranking responsibilities are exposed through explicit configuration.
243. [Achievement] The semantic lane uses an OpenAI-compatible provider boundary.
244. [Achievement] Provider credentials are optional for the exact-search product core.
245. [Achievement] Missing credentials produce a clean refusal instead of degraded fake similarity.
246. [Achievement] Similarity thresholds differ for text queries and file anchors.
247. [Achievement] Maximum similarity can be bounded to exclude near-duplicates when exploring alternatives.
248. [Achievement] Anti-similarity supports identifying architectural drift and disconnected files.
249. [Achievement] Candidate budgets bound external provider work.
250. [Achievement] Result limits and continuation bound semantic output.
251. [Achievement] Agent-v3 similarity output exposes coverage and provenance.
252. [Achievement] File-to-file comparison remains available as a legacy-compatible workflow.
253. [Achievement] Semantic ranking is not confused with exact match verification.
254. [Achievement] `xo` provides a deterministic local alternative when lexical context is sufficient.
255. [Achievement] Trigram and structural evidence can narrow candidates before expensive downstream work.
256. [Achievement] The architecture leaves room for hybrid retrieval without making it a mandatory dependency.
257. [Achievement] Similarity configuration names model and endpoint ownership explicitly.
258. [Achievement] Semantic failures remain typed and visible to agent callers.
259. [Achievement] Calibration reports exist for semantic quality and threshold behavior.
260. [Achievement] Predecessor comparison artifacts exist for similarity promotion work.
261. [Challenge] Current semantic quality, privacy, timeout, and provider behavior remain externally gated without credentials.
262. [Challenge] Provider-backed latency cannot be generalized from local exact-search performance.
263. [Challenge] Model and tokenizer drift can change semantic behavior independently of the IX binary.
264. [Challenge] Semantic result quality needs labeled relevance sets, not only successful API responses.
265. [Challenge] Candidate reduction must not conceal provider coverage loss.
266. [Challenge] Similarity’s larger operational surface raises key-management and cost-control obligations.
267. [Breakthrough] The product kept semantic retrieval as a bounded optional socket instead of contaminating exact search with hosted dependence.
268. [Breakthrough] Anti-similarity reframed semantic search as a maintenance and parity tool, not only discovery.
269. [Breakthrough] Candidate-budget and coverage contracts made provider work visible and controllable.
270. [Strategic] The semantic lane gives IX a path from exact retrieval toward repository-level code intelligence.

## 271–300 — Performance engineering breakthroughs

271. [Achievement] StringZilla supplies a high-performance SIMD substrate for literal matching.
272. [Achievement] PCRE2 JIT supplies a mature accelerated path for complex regex.
273. [Achievement] SIMD selection is fixed at build time, avoiding hot-path dispatch tables.
274. [Achievement] ASCII case folding uses vector operations instead of per-byte branch chains.
275. [Achievement] Literal verification uses fingerprinting to reject false candidates early.
276. [Achievement] Rarity-aware fingerprints reduce collisions on common edge bytes.
277. [Achievement] Trigram evidence can reject files before full scan.
278. [Achievement] Admission bytecode evaluates combined evidence without reparsing query intent.
279. [Achievement] Aho-Corasick machinery supports one-pass literal-alternate matching.
280. [Achievement] FM-index work introduced sub-linear existence checks as an admission option.
281. [Achievement] Wavelet-tree structures reduced occurrence-table pressure in the FM-index direction.
282. [Achievement] Roaring bitmaps provide a compact postings-intersection path.
283. [Achievement] Posting metadata can be preloaded to avoid repeated random-offset reads.
284. [Achievement] Warm query reuse can bypass expensive foreground discovery.
285. [Achievement] Evidence-hot operation demonstrated that most files can be rejected before scanning.
286. [Achievement] Branchless SWAR primitives expanded the engine’s low-level byte-processing toolbox.
287. [Achievement] Non-temporal result-store work explored reducing cache pollution.
288. [Achievement] UCB1 traversal explored learning which directories yield useful results earlier.
289. [Achievement] Byte-sharded regex verification improved a difficult word-boundary lane.
290. [Achievement] Dynamic thread claiming reduced work imbalance on heterogeneous file sizes.
291. [Achievement] Small-corpus scaling avoids paying large thread-spawn overhead for tiny jobs.
292. [Achievement] Large buffers amortize syscall costs on streaming paths.
293. [Achievement] Dedicated cold-path handling protects the instruction cache from exceptional work.
294. [Challenge] Not every experimental kernel has equal production wiring or retained benchmark proof.
295. [Challenge] Microbenchmark wins must survive whole-engine discovery, output, and scheduler costs.
296. [Challenge] Host noise and binary identity drift can exceed the size of claimed improvements.
297. [Breakthrough] A 50× apparent performance gap was traced to measurement error rather than accepted as engine truth.
298. [Breakthrough] The benchmark doctrine now requires route, parity, provenance, and phase exclusivity before runtime blame.
299. [Breakthrough] Route-local wins are treated as salvageable evidence even when whole-engine results remain mixed.
300. [Breakthrough] IX established performance falsification as a first-class product-development discipline.

## 301–330 — Resource efficiency and platform engineering

301. [Achievement] IX enforces a framework-wide memory ceiling instead of observing memory only after allocation.
302. [Achievement] Memory limits are calculated from the host and remain configurable downward.
303. [Achievement] Thread ceilings prevent search from assuming exclusive ownership of the machine.
304. [Achievement] Memory and thread percentages can be controlled independently.
305. [Achievement] Resource profiles let operators choose low, medium, or high pressure intentionally.
306. [Achievement] The default resource policy leaves substantial host capacity available for the user’s other work.
307. [Achievement] Arena allocation gives the short-lived CLI a predictable lifetime model.
308. [Achievement] Fixed metadata ceilings protect oversized-file compaction from unbounded unit growth.
309. [Achievement] Streaming serializers avoid retaining complete output copies unnecessarily.
310. [Achievement] Output byte caps provide a second resource boundary for agent context consumption.
311. [Achievement] Linux has a native io_uring direction for lower-overhead asynchronous reads.
312. [Achievement] Windows has IOCP and journal-oriented research paths rather than inheriting Linux assumptions.
313. [Achievement] Standard buffered I/O remains an explicit fallback where advanced mechanisms are unavailable.
314. [Achievement] Architecture guards keep NT-specific code from breaking non-Windows builds.
315. [Achievement] x86-specific SIMD configuration is gated so non-x86 builds have a viable path.
316. [Achievement] State-directory resolution accounts for Windows and Unix environment conventions.
317. [Achievement] Vendored dependencies make clean builds independent of network availability.
318. [Achievement] Reference bootstrap separates build-critical payloads from research-only source collections.
319. [Achievement] Build-critical references carry commit, archive hash, license, and path provenance.
320. [Achievement] Research-only repositories stay outside the production build graph.
321. [Achievement] The current native executable remains compact enough for simple single-file installation at about 5.9 MB.
322. [Achievement] The repository currently contains 51 Zig source files and roughly 32,000 Zig lines, preserving a tractable native footprint.
323. [Achievement] The source currently declares about 450 named Zig tests across product areas.
324. [Challenge] Linux io_uring evidence does not establish Windows or macOS performance.
325. [Challenge] Advanced I/O paths increase cross-platform maintenance and CI obligations.
326. [Challenge] Huge-page, NUMA, and direct-I/O ambitions require privileged and hardware-specific proof.
327. [Challenge] A 5% default resource policy can make headline wall time look weaker than an uncapped competitor using all cores.
328. [Breakthrough] Per-thread throughput became the preferred efficiency signal when total thread budgets differ.
329. [Breakthrough] Resource restraint was elevated from an optimization detail to a product promise.
330. [Strategic] IX can scale its aggression without requiring separate “fast” and “polite” binaries.

## 331–360 — Reliability, errors, and observability

331. [Achievement] IX distinguishes invalid arguments from runtime search failures.
332. [Achievement] Error responses use stable machine-readable schemas.
333. [Achievement] Recovery hints tell users how to correct malformed requests.
334. [Achievement] Access-denied files contribute structured partial-state evidence.
335. [Achievement] Protected-root skips are counted instead of disappearing silently.
336. [Achievement] Binary-input rejection is explicit where text semantics are required.
337. [Achievement] Invalid UTF-8 has a dedicated failure path for provenance-sensitive compaction.
338. [Achievement] Resource exhaustion maps to product-level error contracts.
339. [Achievement] Too-small output budgets fail rather than emitting malformed JSON.
340. [Achievement] Process status distinguishes live and stale state records.
341. [Achievement] Warm diagnostics expose manifest, generation, journal, and lock state.
342. [Achievement] Slowest-file telemetry helps locate filesystem outliers.
343. [Achievement] Phase timings separate discovery, scanning, aggregation, and total work.
344. [Achievement] Match, file, byte, skip, and access counters expose the request’s coverage.
345. [Achievement] Route telemetry reveals whether an index actually reduced work.
346. [Achievement] Fallback reasons expose why acceleration was not used.
347. [Achievement] Refresh status exposes whether indexed evidence is live, stale, or unavailable.
348. [Achievement] Search output can remain useful while still declaring partial access.
349. [Achievement] Mutation convergence is treated as a correctness test for persistent state.
350. [Achievement] Repair markers provide durable evidence that reconciliation was requested.
351. [Achievement] Installation promotion verifies hashes before and after replacement.
352. [Achievement] Failed promotion has a rollback path to the predecessor binary.
353. [Challenge] Observability volume can become output bloat when every counter is emitted by default.
354. [Challenge] Timing fields must be proven phase-exclusive before they drive optimization decisions.
355. [Challenge] Stale state markers can confuse operators unless live status is interpreted correctly.
356. [Challenge] A successful compile cannot substitute for runtime health, route correctness, or corpus coverage.
357. [Breakthrough] Canonical verification, scan state, and projection state became independent truth axes.
358. [Breakthrough] Typed partial success replaced the false binary choice between total success and total failure.
359. [Breakthrough] Warm-route telemetry exposed mislabeled benchmark rows that prose labels had concealed.
360. [Strategic] IX’s observability model is becoming a competitive advantage for agent trust and benchmark integrity.

## 361–390 — Research, reference reuse, and architectural discipline

361. [Achievement] IX maintains a dedicated `.refs` surface for inspected upstream implementations.
362. [Achievement] The reference manifest currently records roughly 30 build and research entries.
363. [Achievement] Build references include StringZilla and PCRE2 source rather than opaque binary packages.
364. [Achievement] Tree-sitter and the Zig grammar are represented as explicit build-critical references.
365. [Achievement] Research references span search engines, indexing structures, I/O systems, and compaction tools.
366. [Achievement] The repository currently contains hundreds of research artifacts and raw evidence captures.
367. [Achievement] Research decisions record what mechanism transfers and what remains out of scope.
368. [Achievement] Competitor anatomy work separates algorithm, index shape, traversal, ignore handling, and weaknesses.
369. [Achievement] Research sources are expected to change decisions rather than decorate documentation.
370. [Achievement] Licenses and pinned commits are treated as part of reuse readiness.
371. [Achievement] The project harvests proven tests and benchmark methods alongside algorithms.
372. [Achievement] Reference code informs architecture without forcing vendor-specific product language.
373. [Achievement] Research artifacts remain inspectable by future agents without reconstructing chat history.
374. [Achievement] Primary papers support fisheye viewing, ranking, deduplication, and compaction decisions.
375. [Achievement] Elite repositories provide concrete patterns for merging, caching, queues, and binary search.
376. [Achievement] Historical alternatives are retained when they clarify why a mechanism was rejected.
377. [Achievement] The project distinguishes frontier ideas from currently wired product behavior.
378. [Achievement] Research and runtime proof are linked through specs, QC passes, and reports.
379. [Achievement] The compaction command was researched against six pinned comparator repositories before implementation.
380. [Achievement] Compaction research covered classical summarization, diversity ranking, frequency sketches, and chunking.
381. [Challenge] The large research corpus can create retrieval noise and duplicated conclusions.
382. [Challenge] A pinned reference can still become stale relative to upstream fixes and hardware evolution.
383. [Challenge] Strong ideas do not automatically fit IX’s deterministic, native, bounded contract.
384. [Challenge] Research breadth must not outrun production integration and proof capacity.
385. [Breakthrough] “Harvest before originating” shifted original work toward integration and adaptation rather than re-deriving known engines.
386. [Breakthrough] Competitor autopsy replaced shallow feature comparison with measurable mechanism comparison.
387. [Breakthrough] The project learned to preserve negative research results as architecture boundaries.
388. [Breakthrough] Research provenance became part of the planning acceptance gate.
389. [Strategic] IX now has a reusable knowledge base capable of supporting continued systems research without starting from zero.
390. [Strategic] The reference discipline gives the project a credible path to absorb frontier work while preserving one coherent product.

## 391–420 — Testing, QC, and benchmark discipline

391. [Achievement] IX uses targeted test lanes for high-risk product slices.
392. [Achievement] The new compaction lane passes 48 focused tests.
393. [Achievement] Compaction tests cover parsing, budgets, duplicate proof, UTF-8, binary input, long lines, and determinism.
394. [Achievement] Output tests verify actual serialized byte counts against declared counts.
395. [Achievement] Hash-collision tests prove that fingerprints alone cannot remove content.
396. [Achievement] Source-range tests reproduce retained bytes independently.
397. [Achievement] Command metadata tests keep help and completion vocabulary aligned.
398. [Achievement] Warm/cold parity has dedicated harness coverage.
399. [Achievement] Mutation convergence has dedicated persistent-state coverage.
400. [Achievement] Promotion scripts verify candidate freshness before installation.
401. [Achievement] Benchmark reports record binary hashes and executable paths.
402. [Achievement] Performance gates require match parity before comparing speed.
403. [Achievement] Route failures and parity failures are counted separately.
404. [Achievement] Cold and warm definitions are written into benchmark artifacts.
405. [Achievement] Historical reports can be marked superseded when their labels are disproven.
406. [Achievement] QC passes preserve findings, repairs, proof commands, and residual risk.
407. [Achievement] The repository currently retains dozens of report and QC artifacts as an audit trail.
408. [Achievement] Benchmark methodology distinguishes internal engine time from process wall time.
409. [Achievement] Median, range, and repeated-run evidence are preferred over one favorable sample.
410. [Achievement] Predecessor comparisons rotate through multiple binary identities.
411. [Achievement] Installed-path tests prevent repository-only proof from masquerading as shipped behavior.
412. [Achievement] Formatting and diff checks are treated as independent quality gates.
413. [Challenge] The full repository test suite is not currently green.
414. [Challenge] The latest broad test attempt remained CPU-bound and silent beyond 300 seconds.
415. [Challenge] Earlier retained evidence ended at 539/549 tests with warm-cache and Thompson-NFA failures.
416. [Challenge] Focused green tests do not prove unrelated product areas.
417. [Challenge] Benchmark hosts can introduce scheduler, antivirus, filesystem-filter, and identity drift.
418. [Breakthrough] IX adopted the rule that benchmark failure first challenges the measurement lane, not automatically the engine.
419. [Breakthrough] Existing tests remain contracts; implementation is repaired instead of weakening assertions for green output.
420. [Strategic] The QC chain has become a durable product memory rather than a temporary review ritual.

## 421–450 — Distribution, installation, and operator readiness

421. [Achievement] IX builds as one native executable.
422. [Achievement] The current ReleaseFast executable is installed at the canonical Windows owner path.
423. [Achievement] The installed and repository binaries currently share SHA-256 `373EF49D…2AF23`.
424. [Achievement] The promotion flow stages a candidate before replacing the live binary.
425. [Achievement] Prior installed binaries are retained under a dedicated backup directory.
426. [Achievement] Promotion verifies source freshness against runtime inputs.
427. [Achievement] Candidate verification exercises cold and warm behavior before install.
428. [Achievement] Installed verification reruns after atomic replacement.
429. [Achievement] User PATH migration converges on one canonical install directory.
430. [Achievement] Legacy install locations are treated as migration sources rather than active owners.
431. [Achievement] State storage is separated from executable installation.
432. [Achievement] Configuration persists under the user state root instead of beside the binary.
433. [Achievement] Package manifests exist for multiple ecosystem directions.
434. [Achievement] CI has cross-platform build intent and explicit vendored dependencies.
435. [Achievement] ReleaseSmall and ReleaseFast builds have both been exercised for the current compaction feature.
436. [Achievement] The current installed binary passes a machine-readable search smoke probe.
437. [Achievement] The current installed binary passes a bounded compaction JSON smoke probe.
438. [Achievement] The installed `min` probe produced exact actual and declared output byte counts.
439. [Achievement] Rollback evidence includes predecessor hashes and byte sizes.
440. [Achievement] The installation workflow avoids requiring a package manager for direct use.
441. [Challenge] Existing package manifests do not by themselves prove publication, installation, or upgrade readiness.
442. [Challenge] A rebuilt binary may no longer carry an older signing proof.
443. [Challenge] Current Authenticode/signature status should be revalidated before a public signed-release claim.
444. [Challenge] Linux and macOS install paths need the same real-owner promotion evidence as Windows.
445. [Challenge] Full release readiness remains separate from local installed-path success.
446. [Challenge] Persistent index generations need refresh handling across binary and source upgrades.
447. [Breakthrough] Atomic promotion with backup and hash proof replaced ad hoc executable copying.
448. [Breakthrough] Canonical installation reduced confusion among repo, installed, legacy, and backup binaries.
449. [Strategic] The product now has the operational substrate for repeatable native dogfooding.
450. [Strategic] A clean single-binary path lowers adoption friction for both people and coding agents.

## 451–480 — Major challenges overcome

451. [Breakthrough] The original Rust-port framing was abandoned when Zig enabled a more specialized architecture.
452. [Breakthrough] The search path was rebuilt around cache-aware buffers instead of preserving line-by-line translation.
453. [Breakthrough] Runtime strategy branching moved toward parse-time classification.
454. [Breakthrough] Shared scan mutation was replaced by thread-local accumulation.
455. [Breakthrough] Output truth was separated from the number of records that fit one response.
456. [Breakthrough] Exact inspection was separated from lossy preview behavior.
457. [Breakthrough] Agent output removed repeated paths and low-value telemetry.
458. [Breakthrough] Fisheye preview solved the minified-line context explosion without hiding the match.
459. [Breakthrough] BM25 context selection solved the “find the concept before knowing the range” problem.
460. [Breakthrough] Query-free compaction solved the “file is too large and there is no query yet” problem.
461. [Breakthrough] Byte-verified duplicate proof removed the risk of hash-only data loss.
462. [Breakthrough] Exact complete-output sizing removed malformed budget-bound responses.
463. [Breakthrough] Protected-root policy reduced pathological Windows cold-path behavior.
464. [Breakthrough] Adaptive threading corrected oversubscription on small corpora.
465. [Breakthrough] Dynamic work claiming reduced long-tail shard imbalance.
466. [Breakthrough] The warm lifecycle was repaired to survive corpus mutations.
467. [Breakthrough] Benchmark readiness stopped interfering with the system it was measuring.
468. [Breakthrough] Config-driven warm activation was proven on a real installed path historically.
469. [Breakthrough] Misleading warm reports were explicitly superseded rather than quietly forgotten.
470. [Breakthrough] Native promotion blockers around references and source exhaustiveness were closed.
471. [Breakthrough] Build-critical references gained deterministic bootstrap and verification.
472. [Breakthrough] The product’s README was rewritten around shipped differentiators and operator value.
473. [Breakthrough] CLI help became a maintained capability contract.
474. [Breakthrough] The `--version` handshake became stable across invocation surfaces.
475. [Breakthrough] The project established a canonical Windows installation and rollback chain.
476. [Breakthrough] Similarity capability gained bounded provider-work and coverage contracts.
477. [Breakthrough] Performance reports gained binary identity and route evidence.
478. [Breakthrough] Large-file doctrine turned compaction from a generic summary idea into a provenance-preserving IX feature.
479. [Breakthrough] Product documentation, runtime, tests, and installed proof were reconciled in the latest feature arc.
480. [Strategic] The accumulated breakthroughs transformed IX from an optimization experiment into an operable retrieval product.

## 481–510 — Current challenges and residual risks

481. [Challenge] Current warm-index parity is red after newer source files were added.
482. [Challenge] The installed warm generation omits at least two current `src` files in the fresh probe.
483. [Challenge] The fresh positive query differed by 13 matches between cold and warm-enabled paths.
484. [Challenge] A full-root warm probe represented far fewer files than the cold traversal.
485. [Challenge] Warm regeneration and mutation convergence must be rerun on the current binary before warm promotion claims resume.
486. [Challenge] The full suite still lacks a timely, reliable completion result.
487. [Challenge] Known regex and warm-cache failures remain part of the historical test boundary.
488. [Challenge] Semantic ranking remains unproven in the current environment without provider credentials.
489. [Challenge] Provider quality, privacy, and failure handling need separate production evidence.
490. [Challenge] Advanced commands need periodic end-to-end parity audits as their implementations evolve.
491. [Challenge] The research corpus is large enough to create duplication and retrieval overhead.
492. [Challenge] Historical benchmark figures span different binaries, corpora, thread policies, and host states.
493. [Challenge] Older README performance claims must remain tied to their dated benchmark envelopes.
494. [Challenge] Experimental algorithm names can overstate product readiness if wiring is not rechecked.
495. [Challenge] Linux-specific async I/O remains a platform boundary.
496. [Challenge] Windows journal freshness still needs complete operator-path proof under real repository churn.
497. [Challenge] Package publication and public release channels are less proven than local installation.
498. [Challenge] Current binary signing status is not established by the historical signing milestone.
499. [Challenge] Broad telemetry and command breadth can increase cognitive load for first-time users.
500. [Challenge] Typed clients and protocol mirrors must keep pace with every schema evolution.
501. [Challenge] Resource caps complicate comparisons against tools allowed to consume all cores.
502. [Challenge] Cold traversal over the full working tree still processed about 1.89 GB in the fresh probe.
503. [Challenge] Generated and temporary corpora can dominate full-root performance if scope is not intentional.
504. [Challenge] Search-result truth remains dependent on ignore, protected-path, and corpus-policy transparency.
505. [Challenge] Compaction fact retention is strong but not complete on every document shape.
506. [Challenge] The high and medium compaction selectors need continued differentiation evidence beyond default budgets.
507. [Challenge] Documentation and QC volume require stronger routing to remain useful to cold-starting maintainers.
508. [Challenge] The project’s pace of advanced feature addition risks widening proof debt.
509. [Challenge] Public readiness needs a clean-runner, packaging, signature, upgrade, rollback, and recovery gate as one release graph.
510. [Strategic] The highest-value next move is closing warm freshness and full-suite reliability before adding another major retrieval lane.

## 511–540 — Retained historical performance evidence

511. [Performance] A July 15 full-repository benchmark covered 7,107 scanned files and about 1.89 GB.
512. [Performance] That benchmark recorded a 397.6228 ms cold median wall time.
513. [Performance] The same report recorded a 380.3314 ms cold median internal total.
514. [Performance] The historical indexed-warm median internal total was 0.5574 ms.
515. [Performance] Historical warm internal samples ranged from 0.5126 to 0.6225 ms.
516. [Performance] Historical warm scan-work median was zero.
517. [Performance] Historical warm median peak resident memory was about 8.531 MiB.
518. [Performance] The historical warm benchmark had 10 valid runs and zero failed runs.
519. [Performance] The historical gate recorded zero route failures.
520. [Performance] The historical gate recorded zero parity failures.
521. [Performance] Historical installed proof recorded a cold-to-warm transition at 1.2915 ms internal total.
522. [Performance] That installed warm proof scanned zero files.
523. [Performance] A first novel warm query on the historical full repository took 4.9715 ms internal time.
524. [Performance] A historical rotated cold comparison placed candidate and predecessors around 124–128 ms internal medians on its specific lane.
525. [Performance] The historical evidence-hot lane reduced median wall time from roughly 203 ms baseline to about 164 ms.
526. [Performance] That evidence-hot lane pruned 79,041 files before scan.
527. [Performance] A Linux-corpus optimization reduced a measured Zig-versus-Rust IX gap from 9.86% to 3.37%.
528. [Performance] A difficult word-boundary lane improved from 637.615 ms to 609.966 ms median wall time.
529. [Performance] That word-boundary change represented a 4.34% measured improvement.
530. [Performance] A guard literal lane improved from 38.043 ms to 34.788 ms in the retained report.
531. [Performance] A corrected full-corpus comparison placed IX near 2.9 seconds with 2 threads versus ripgrep near 3.0 seconds with 32 threads.
532. [Performance] The corrected comparison supports strong per-thread efficiency rather than a universal absolute-speed claim.
533. [Performance] The retained Linux corpus contained roughly 79,000 files and 1.34 GB of scanned data.
534. [Performance] The grouped agent output delivered a measured 4.2× byte reduction.
535. [Performance] Fisheye preview demonstrated up to 143× reduction on a 10 KiB minified line.
536. [Performance] Compaction’s current eight-case report kept all native outputs within their declared budgets.
537. [Performance] Current compaction peak working-set samples were roughly 2.5–3.4 MiB in the verification harness.
538. [Performance] Current compaction retained all labeled facts in repetitive-log, JSONL, and benchmark-journal cases.
539. [Boundary] Every historical number above belongs to its dated binary, corpus, route, and host envelope.
540. [Boundary] Historical warm success is retained as a breakthrough but is superseded for current parity status by the fresh red probe.

## 541–570 — Fresh installed performance snapshot, 2026-07-16

541. [Performance] The current installed binary is `ix 2.0.0` and is 5,923,840 bytes.
542. [Performance] A one-file installed search found `pub` in `src/main.zig` in 0.9595 ms internal total.
543. [Performance] That one-file smoke scanned 49,137 bytes and returned a complete canonical projection.
544. [Performance] A cold absent-query scan over `src` discovered and scanned 52 files.
545. [Performance] The cold `src` probe scanned 1,560,926 bytes.
546. [Performance] The cold absent-query `src` probe completed in 3.8007 ms internal total.
547. [Performance] Its discovery phase took 0.2444 ms.
548. [Performance] Its scan phase took 3.2432 ms.
549. [Performance] A warm-enabled absent-query `src` probe reported zero files scanned.
550. [Performance] That warm-enabled probe reported only 50 files represented, exposing stale coverage.
551. [Performance] Its scan work was only 0.0086 ms.
552. [Performance] Its end-to-end internal total was 80.1083 ms, slower than the small cold scan.
553. [Performance] A cold positive `lit:pub` query over `src` returned 887 matches.
554. [Performance] The cold positive query completed in 3.7740 ms internal total.
555. [Performance] The warm-enabled positive query returned 874 matches.
556. [Performance] The warm-enabled positive query scanned 49 files and 1,512,384 bytes.
557. [Performance] The warm-enabled positive query completed in 7.2282 ms internal total.
558. [Performance] The 13-match difference makes the current warm-positive result invalid for promotion.
559. [Performance] A fresh cold full-root absent query discovered 7,201 files.
560. [Performance] That cold full-root probe scanned 7,111 files and about 1.891 GB.
561. [Performance] The cold full-root probe completed in about 10.021 seconds internal total.
562. [Performance] Discovery accounted for about 298 ms of that full-root run.
563. [Performance] Scanning accounted for about 9.722 seconds.
564. [Performance] The fresh warm full-root probe scanned zero files but represented only 1,615 files.
565. [Performance] The warm full-root probe completed in about 74.7 ms internal total.
566. [Performance] Zero warm scan work is not a valid win when corpus coverage is stale.
567. [Performance] Current `min med` on the 384,300-byte search owner emitted 16,366 bytes.
568. [Performance] That compaction retained five of six labeled facts versus two of six for an equal-byte prefix.
569. [Performance] The current installed README compaction emitted 16,238 actual and declared bytes under a 16,384-byte cap.
570. [Verdict] Current cold and compaction performance are healthy; current warm performance is fast but not correctness-admissible.

## 571–600 — Strategic product impact and next frontier

571. [Strategic] IX now serves as a real dogfooded retrieval tool inside its own repository.
572. [Strategic] IX-first repository guidance has moved the product from optional experiment to daily operating substrate.
573. [Strategic] Agent-oriented output directly lowers the cost of repository understanding.
574. [Strategic] Exact follow-up contracts reduce the risk of agents editing from lossy previews.
575. [Strategic] Query-free compaction expands IX into oversized logs, reports, and research documents.
576. [Strategic] Semantic and anti-semantic lanes create a path toward architecture-drift detection.
577. [Strategic] Persistent indexing creates a path toward near-instant repeat queries when freshness is trustworthy.
578. [Strategic] Strong resource controls make IX suitable for background use alongside development workloads.
579. [Strategic] A single native binary lowers deployment and integration friction.
580. [Strategic] Typed truth states make IX well suited to automated agents and CI gates.
581. [Strategic] Provenance-rich reports make performance work reproducible rather than anecdotal.
582. [Strategic] The reference corpus gives future development a compounding research advantage.
583. [Strategic] The project’s low-level expertise differentiates it from wrapper-based search products.
584. [Strategic] The product’s strongest moat is the combination of exactness, bounded context, and explainable acceleration.
585. [Strategic] The warm-index freshness defect is high leverage because fixing it unlocks the most dramatic latency gains safely.
586. [Strategic] Full-suite reliability is the next major trust multiplier for maintainers and contributors.
587. [Strategic] Public release readiness should follow one canonical package, signature, install, upgrade, rollback, and recovery proof.
588. [Strategic] Similarity should advance through labeled quality evaluation before broader promotion.
589. [Strategic] Platform-specific I/O work should proceed only where end-to-end corpus measurements justify its complexity.
590. [Strategic] Benchmark work should continue comparing predecessor, current, and installed binaries one at a time.
591. [Strategic] Warm publication should become self-verifying against current corpus cardinality and content epoch.
592. [Strategic] The product should expose stale warm coverage as a typed refusal rather than silently falling through to partial indexed behavior.
593. [Strategic] Small-corpus routing should avoid daemon overhead when a direct scan is cheaper.
594. [Strategic] Documentation routing should condense the large QC and research estate into faster operator entry points.
595. [Strategic] Advanced kernels should graduate only with wiring, parity, phase timing, and installed-path proof.
596. [Strategic] Context efficiency should remain a first-class benchmark alongside raw search latency.
597. [Strategic] IX should continue optimizing for evidence found per byte, per core, and per unit of user attention.
598. [Strategic] The next product milestone should prioritize trusted warm convergence over another headline feature.
599. [Strategic] Once freshness and full-suite gates close, IX will have a credible foundation for broader public adoption.
600. [Verdict] IX has achieved a rare combination of native speed, agent-oriented evidence, architectural ambition, and honest proof boundaries; its next phase is consolidation into consistently trustworthy warm and release behavior.

## Performance verdict

The product’s cold exact-search engine, bounded outputs, and new compaction lane are currently useful and proven on the installed binary. Historical warm indexing demonstrated sub-millisecond internal repeat-query performance with parity, but the current warm generation is stale and must not be promoted as correct until regeneration restores file and match parity. The broad product conclusion is positive: IX has crossed from experimental search engine into a capable retrieval platform, while its highest-value remaining work is correctness consolidation rather than surface expansion.

## Composition and evidence

The 600 records comprise 355 achievements, 60 breakthroughs, 80 challenges, 62 performance findings, 39 strategic findings, two boundaries, and two verdicts. Numbering is contiguous from 1 through 600 with no duplicate numbers or duplicate entry text.

Evidence: `README.md`, `SKILL.md`, installed `ix --help`, and current command smoke probes.
Observation: IX exposes a coherent multi-lane product across exact search, inspection, context, compaction, semantic ranking, explanation, and operations.
Impact: The inventory can describe product outcomes without collapsing into per-function implementation detail.
Confidence: high
Action: Keep executable help and capability mirrors synchronized as commands evolve.

Evidence: `.docs/reports/warm-config-promotion-20260715.json` and `.docs/reports/promotion-speed-dogfood-full-stable-20260715.json`.
Observation: The July 15 binary achieved valid historical warm route and parity proof, including zero scanned files and sub-millisecond repeated internal totals.
Impact: Warm indexing is a demonstrated breakthrough, but the result belongs to its dated binary and generation.
Confidence: high
Action: Preserve the historical result as provenance-qualified evidence.

Evidence: fresh installed cold/warm probes on `src` with `lit:pub`, 2026-07-16.
Observation: Cold returned 887 matches across 52 files; warm-enabled returned 874 across 50 files.
Impact: The current warm generation is stale and cannot support a current parity or promotion claim.
Confidence: high
Action: Regenerate the warm generation, prove mutation convergence, and rerun full-corpus parity before promotion.

Evidence: fresh installed absent-query probes over the repository root, 2026-07-16.
Observation: Cold discovered 7,201 files and scanned about 1.891 GB; warm represented 1,615 files and scanned zero.
Impact: The warm speed figure is inadmissible while coverage differs materially.
Confidence: high
Action: Add a corpus-cardinality/content-epoch refusal when a warm generation is stale.

Evidence: `.docs/reports/min-context-compaction-20260716.json` and installed `min` smoke proof.
Observation: All eight native cases stayed within budget; medium beat prefix fact recall on seven cases, and installed README output matched its declared byte count exactly.
Impact: Query-free oversized-file reading is useful, bounded, and provenance-preserving, with a documented negative boundary.
Confidence: high
Action: Continue corpus-based preservation evaluation instead of optimizing for compression ratio alone.

Evidence: `zig build test-min -Doptimize=ReleaseFast`, ReleaseFast build proof, and the widened repository test attempt.
Observation: The focused compaction lane passes 48/48, while the full suite remains non-green and exceeded 300 seconds in the latest attempt.
Impact: The new feature is locally proven, but repository-wide release confidence remains bounded.
Confidence: high
Action: Close full-suite runtime and known warm-cache/regex failures before broad release readiness.
