import { identityControlFailures } from "./speed-compare-utils.mjs";

export function benchmarkEvidenceFailures({
  samples,
  minRetainableSamples,
  host,
  processScan,
  identityControl,
  identityControlEnabled = true,
  requiredIdentitySamples,
} = {}) {
  const failures = [];
  if (Number.isFinite(samples) && Number.isFinite(minRetainableSamples) && samples < minRetainableSamples) {
    failures.push(`underpowered_samples:${samples}<${minRetainableSamples}`);
  }
  const hostIssues = [
    ...(host?.before?.benchmarkEnvironment?.issues ?? []),
    ...(host?.after?.benchmarkEnvironment?.issues ?? []),
  ].filter((issue) => issue?.severity === "warning");
  for (const issue of hostIssues) {
    failures.push(`host:${issue.id}:${issue.detail}`);
  }
  if (processScan?.before?.ok === false) failures.push("process_scan_before_failed");
  if (processScan?.after?.ok === false) failures.push("process_scan_after_failed");
  for (const failure of processScan?.before?.failures ?? []) failures.push(`process_scan_before:${failure}`);
  for (const failure of processScan?.after?.failures ?? []) failures.push(`process_scan_after:${failure}`);
  if ((processScan?.before?.matched?.length ?? 0) > 0) failures.push(`stale_processes_before:${processScan.before.matched.length}`);
  if ((processScan?.after?.matched?.length ?? 0) > 0) failures.push(`stale_processes_after:${processScan.after.matched.length}`);
  failures.push(...identityControlFailures({
    identityControl,
    enabled: identityControlEnabled,
    requiredSamples: requiredIdentitySamples,
  }));
  return failures;
}

export function evidenceQualityFromFailures(failures = []) {
  const all = Array.isArray(failures) ? failures.map(String) : [];
  const hostFailures = all.filter((failure) => failure.startsWith("host:"));
  const identityFailures = all.filter((failure) => failure.startsWith("identity_control"));
  const processFailures = all.filter((failure) =>
    failure.startsWith("process_scan") ||
    failure.startsWith("stale_processes"),
  );
  const sampleFailures = all.filter((failure) => failure.startsWith("underpowered_samples"));
  const comparisonFailures = all.filter((failure) =>
    !hostFailures.includes(failure) &&
    !identityFailures.includes(failure) &&
    !processFailures.includes(failure) &&
    !sampleFailures.includes(failure),
  );
  return {
    usableForRuntimeMove: hostFailures.length === 0 && identityFailures.length === 0 && processFailures.length === 0,
    hostFailures,
    identityFailures,
    processFailures,
    sampleFailures,
    comparisonFailures,
    failures: all,
  };
}
