---
type: qc-pass
id: pass-024-min-shipped-artifact
status: complete
date: 2026-07-16
scope: ix-min
quality_band: 4/4
---

# QC 4/4 — native bounded compaction

Reviewed the shipped command spine, native scanner/selector/serializer, tests, benchmark harness, README, SKILL, and executable help against the goal doctrine and implementation spec.

The first blocking defect was an overbroad hard-preservation rule. Treating every declaration, heading, path, command, metric, error, or obligation-bearing block as mandatory made ordinary code and documentation impossible to compact. The repaired owner keeps first/last source units as the absolute floor and treats meaning-bearing forms as strong, transparent score evidence with labeled retention tests.

The second blocking defect was provenance instability inside equal duplicate groups. Digest-and-length sorting did not explicitly break ties by source index, and boundary units could be omitted when byte-identical content existed elsewhere. The repair orders equal candidates by source index, proves equality with positional byte comparison, and keeps both source boundaries represented.

The third blocking defect was output-metadata pressure. Per-reason omission fragmentation could consume the requested budget before useful source material. The serializer now coalesces every contiguous omitted run while choosing `budget` whenever any unique unit occurs in that run. It never conceals coordinates or counts.

The fourth finding was a weak profile-order test that proved enum ordinal values rather than behavior. It was replaced with parser-level assertions for the actual 32,768 / 16,384 / 8,192 default budgets. Explicit budgets remain authoritative; medium and high share the same evidence selector and differ by admissible output pressure.

Proof: focused ReleaseFast tests pass 48/48; ReleaseSmall and ReleaseFast builds pass; exact serializer length, SHA-256, retained ranges, source ordering, deterministic output, empty-stdout failure, and eight-class retention evidence are recorded. The widened repository test command exceeded 300 seconds without output and is preserved as an explicit existing-suite boundary, not a success claim.

Decision: ship `ix min` as a narrow query-free projection. Do not fold it into exact `inspect`, query-guided `xo`, semantic `similar`, or MCP until a separately tested protocol owner exists.

Installed-path closure: canonical promotion archived the predecessor, installed SHA-256 `373EF49DDB2A810BEA0240F65967D89DBA2A64F4EB3900603EAAF39199C2AF23`, and the installed JSON smoke returned `ix.min.v1` with `16238` actual and declared bytes under a `16384` cap.
