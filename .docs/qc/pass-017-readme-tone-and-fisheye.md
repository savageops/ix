# QC pass 017 — README tone and fisheye boundary

## Finding

The capability injection was accurate but too civilian in register. It also named fisheye at the product headline without restating the critical boundary: fisheye is a lossy search-preview projection, while `xo` and `search --context` preserve exact source evidence.

## Change

- Recast the headline as “BM25 degree-of-interest context” and “Furnas fisheye match lens.”
- Rewrote XO as a bounded degree-of-interest field with BM25, structural priors, omission state, and exact-verification boundaries.
- Rewrote warm block pruning as a validated negative proof over generation-pinned postings.
- Reasserted that fisheye applies to lossy `--agent` search previews, not exact `xo` or context windows.
- Preserved the existing dedicated Fisheye Preview section as the canonical explanation of tiers, match visibility, and 143× reduction.

## Evidence

- `src/core/preview.zig`: UTF-8-safe Furnas preview implementation.
- `README.md` Fisheye Preview: T0–T3 contraction, match-preservation invariant, exact-evidence boundary.
- `src/core/xo.zig`: BM25 line ranking and degree-of-interest assembly.

## Proof

- `git diff --check` passed.
- No runtime or public output contracts changed.

## Disposition

Keep the README’s systems voice: name the mechanism, its invariant, and the failure it prevents. Avoid generic “useful,” “small pieces,” or “follow-up tool” language when the implementation has a sharper term.
