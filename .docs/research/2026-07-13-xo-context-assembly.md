---
type: research
status: active
date: 2026-07-13
subject: query-driven exact code context assembly
---

# Query-Driven Exact Code Context Assembly

## Sources

- Sourcegraph streaming search API: https://sourcegraph.com/docs/api/stream-api
- Sourcegraph search CLI: https://sourcegraph.com/docs/cli/references/search
- Cursor working with context: https://docs.cursor.com/en/guides/working-with-context
- Continue reranking role: https://docs.continue.dev/customize/model-roles/reranking
- OpenAI vector-store file chunking: https://platform.openai.com/docs/api-reference/vector-stores-files/file-object
- ColBERT: https://arxiv.org/abs/2004.12832
- PLAID: https://arxiv.org/abs/2205.09707
- Tree-sitter: https://github.com/tree-sitter/tree-sitter
- Zoekt: https://github.com/sourcegraph/zoekt
- ripgrep: https://github.com/BurntSushi/ripgrep
- Furnas, Generalized Fisheye Views: https://courses.ischool.berkeley.edu/i247/f05/readings/Furnas_GeneralizedFisheyeViews_CHI86.pdf

## Synthesis

The strongest common architecture is staged retrieval: cheap exact candidate generation, bounded passage formation, stronger reranking, then budgeted context assembly. The context assembler is a separate consumer from the search engine. It receives attributable evidence and chooses exact spans; it does not change match truth or scan performance.

The product delta for IX is deterministic proof. Each returned byte maps to a path and line. Each gap is visible. Each score names its stage. Each budget and omission is explicit. The semantic lane improves recall across paraphrases, languages, and code vocabulary, but it remains an advisory ranking signal until task-labeled evaluation establishes calibration.
