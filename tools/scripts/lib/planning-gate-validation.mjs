import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";

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

  return { planningLane };
}
