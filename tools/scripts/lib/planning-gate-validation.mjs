import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const TODO_PENDING_ROOT = ".docs/todo/pending";
const TODO_CHANGELOG_ROOT = ".docs/todo/changelog";

function parseCsvArg(value) {
  return String(value)
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function discoverPlanningPhases(root, chainRoot, prefix, suffix) {
  const absoluteRoot = path.join(root, chainRoot);
  if (!existsSync(absoluteRoot)) return [];
  const pattern = new RegExp(`^${prefix}([a-z]+)-${escapeRegExp(suffix)}\\.md$`);
  return readdirSync(absoluteRoot)
    .map((name) => name.match(pattern)?.[1])
    .filter(Boolean)
    .sort();
}

function listMarkdownFiles(root, relativeRoot) {
  const absoluteRoot = path.join(root, relativeRoot);
  if (!existsSync(absoluteRoot)) return [];
  return readdirSync(absoluteRoot)
    .filter((name) => name.endsWith(".md"))
    .map((name) => `${relativeRoot}/${name}`)
    .sort();
}

function parsePlanningFileName(file) {
  const name = path.basename(file);
  const match = name.match(/^(\d+)([a-z]+)?-(.+)\.md$/);
  if (!match) return null;
  return {
    prefix: match[1],
    phase: match[2] ?? null,
    suffix: match[3],
    chainSlug: `${match[1]}-${match[3]}`,
  };
}

function planningStatusFor(root, file) {
  const absolute = path.join(root, file);
  if (!existsSync(absolute)) return null;
  const body = readFileSync(absolute, "utf8");
  const status = body.match(/^status:\s*(\S+)/m)?.[1] ?? null;
  return {
    status,
    placeholderEvidence: /^evidence:.*PLACEHOLDER/m.test(body),
  };
}

export function createPlanningGateValidation({
  root,
  lane,
  planningChainSlug,
  planningChainPhasesArg,
  planningChainState,
}) {
  function planningLane() {
    const match = planningChainSlug.match(/^(\d+)-(.+)$/);
    const chainConfigFailures = [];
    if (!match) chainConfigFailures.push(`planning chain slug must start with a numeric prefix: ${planningChainSlug}`);
    if (!["archived", "pending"].includes(planningChainState)) {
      chainConfigFailures.push(`planning state must be archived or pending: ${planningChainState}`);
    }
    const prefix = match?.[1] ?? "";
    const suffix = match?.[2] ?? planningChainSlug;
    const chainRoot = planningChainState === "pending" ? ".docs/todo/pending" : ".docs/todo/changelog";
    const oppositeRoot = planningChainState === "pending" ? ".docs/todo/changelog" : ".docs/todo/pending";
    const planningChainPhases =
      planningChainPhasesArg === "auto" ? discoverPlanningPhases(root, chainRoot, prefix, suffix) : parseCsvArg(planningChainPhasesArg);
    if (planningChainPhases.length === 0) chainConfigFailures.push("planning chain phases must not be empty");
    const required = match
      ? [
          `${chainRoot}/${planningChainSlug}.md`,
          ...planningChainPhases.map((phase) => `${chainRoot}/${prefix}${phase}-${suffix}.md`),
        ]
      : [];
    const staleOpposite = required
      .map((file) => file.replace(chainRoot, oppositeRoot))
      .filter((file) => existsSync(path.join(root, file)));
    const stalePending = planningChainState === "archived" ? staleOpposite : [];
    const missing = required.filter((file) => !existsSync(path.join(root, file)));
    const incomplete = [];
    for (const file of required) {
      const absolute = path.join(root, file);
      if (!existsSync(absolute)) continue;
      const body = readFileSync(absolute, "utf8");
      if (planningChainState === "archived") {
        if (!body.includes("status: done")) incomplete.push(`${file}: status is not done`);
        if (/^evidence:.*PLACEHOLDER/m.test(body)) incomplete.push(`${file}: evidence still contains PLACEHOLDER`);
      } else if (!body.includes("status: pending")) {
        incomplete.push(`${file}: status is not pending`);
      }
    }
    const failures = [
      ...chainConfigFailures,
      ...missing.map((file) => `${file}: missing`),
      ...staleOpposite.map((file) => `${file}: duplicate ${planningChainState === "pending" ? "changelog" : "pending"} file remains`),
      ...incomplete,
    ];
    return lane("planning_chain", failures.length === 0 ? "ok" : "failed", {
      chain: planningChainSlug,
      state: planningChainState,
      phases: planningChainPhases,
      required,
      missing,
      staleOpposite,
      stalePending,
      incomplete,
      failures,
    });
  }

  function planningQueueLane() {
    const pendingFiles = listMarkdownFiles(root, TODO_PENDING_ROOT);
    const changelogFiles = listMarkdownFiles(root, TODO_CHANGELOG_ROOT);
    const allFiles = [
      ...pendingFiles.map((file) => ({ file, location: "pending", parsed: parsePlanningFileName(file) })),
      ...changelogFiles.map((file) => ({ file, location: "changelog", parsed: parsePlanningFileName(file) })),
    ].filter((entry) => entry.parsed !== null);

    const byChain = new Map();
    for (const entry of allFiles) {
      const key = entry.parsed.chainSlug;
      const current = byChain.get(key) ?? { chain: key, pending: [], changelog: [], phases: new Map() };
      current[entry.location].push(entry.file);
      if (entry.parsed.phase !== null) {
        const phase = current.phases.get(entry.parsed.phase) ?? { pending: [], changelog: [] };
        phase[entry.location].push(entry.file);
        current.phases.set(entry.parsed.phase, phase);
      }
      byChain.set(key, current);
    }

    const failures = [];
    const archivedDebt = [];
    const chains = [];
    for (const chain of [...byChain.values()].sort((left, right) => left.chain.localeCompare(right.chain))) {
      const rootPending = chain.pending.includes(`${TODO_PENDING_ROOT}/${chain.chain}.md`);
      const rootChangelog = chain.changelog.includes(`${TODO_CHANGELOG_ROOT}/${chain.chain}.md`);
      const pendingPhases = [...chain.phases.values()].flatMap((phase) => phase.pending);
      const changelogPhases = [...chain.phases.values()].flatMap((phase) => phase.changelog);
      const phaseDuplicates = [];
      for (const [phaseName, phase] of chain.phases.entries()) {
        if (phase.pending.length > 0 && phase.changelog.length > 0) {
          phaseDuplicates.push(phaseName);
          failures.push(`${chain.chain}: phase ${phaseName} exists in both pending and changelog`);
        }
      }
      if (rootPending && rootChangelog) failures.push(`${chain.chain}: parent exists in both pending and changelog`);
      if (rootPending && changelogPhases.length > 0 && pendingPhases.length === 0) {
        failures.push(`${chain.chain}: pending parent has no pending phases but has archived phases`);
      }
      if (rootChangelog && pendingPhases.length > 0) {
        failures.push(`${chain.chain}: archived parent has pending phases`);
      }
      for (const file of [...chain.pending, ...chain.changelog]) {
        const state = planningStatusFor(root, file);
        if (file.startsWith(TODO_PENDING_ROOT) && state?.status === "done") {
          failures.push(`${file}: done file remains in pending`);
        }
        if (file.startsWith(TODO_CHANGELOG_ROOT)) {
          if (state?.placeholderEvidence) archivedDebt.push(`${file}: evidence still contains PLACEHOLDER`);
          if (state?.status === "pending") archivedDebt.push(`${file}: pending file remains in changelog`);
        }
      }
      chains.push({
        chain: chain.chain,
        rootPending,
        rootChangelog,
        pendingFiles: chain.pending.length,
        changelogFiles: chain.changelog.length,
        pendingPhases: pendingPhases.length,
        changelogPhases: changelogPhases.length,
        phaseDuplicates,
      });
    }

    return lane("planning_queue", failures.length === 0 ? "ok" : "failed", {
      pendingRoot: TODO_PENDING_ROOT,
      changelogRoot: TODO_CHANGELOG_ROOT,
      chains,
      archivedDebt,
      failures,
    });
  }

  return { planningLane, planningQueueLane };
}
