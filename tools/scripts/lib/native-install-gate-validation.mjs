import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex").toUpperCase();
}

export function createNativeInstallGateValidation({
  latestTeddyDecisionPath,
  nativeInstallDir,
  nativeInstallIx,
  findBuiltIx,
  lane,
}) {
  function latestTeddyDecisionForRepoHash(repoHash) {
    if (!existsSync(latestTeddyDecisionPath)) return null;
    try {
      const parsed = JSON.parse(readFileSync(latestTeddyDecisionPath, "utf8"));
      if (parsed?.currentIxSha256 !== repoHash) return null;
      if (parsed?.evidenceFresh !== true) return null;
      return {
        path: latestTeddyDecisionPath,
        runId: parsed.runId ?? null,
        evaluatedHistoricalRunId: parsed.evaluatedHistoricalRunId ?? null,
        currentIxSha256: parsed.currentIxSha256 ?? null,
        promotionAllowed: parsed.promotionAllowed === true,
        noRuntimePromotionReason: parsed.noRuntimePromotionReason ?? null,
        scorecard: parsed.scorecard ?? null,
        summary: parsed.summary ?? null,
        nextAllowedMove: parsed.nextAllowedMove ?? null,
      };
    } catch {
      return null;
    }
  }

  function nativeInstallIdentityLane() {
    if (process.platform !== "win32") {
      return lane("native_install_identity", "skipped", { reason: "native installed IX identity is currently Windows-only" });
    }
    const repoIx = findBuiltIx();
    if (!repoIx) return lane("native_install_identity", "skipped", { reason: "zig-out binary missing; run build first" });
    if (!existsSync(nativeInstallIx)) {
      return lane("native_install_identity", "skipped", {
        reason: "native installed IX executable missing",
        missing: [nativeInstallIx],
      });
    }
    const repoHash = sha256File(repoIx);
    const installed = [{ path: nativeInstallIx, sha256: sha256File(nativeInstallIx) }];
    const mismatched = installed.filter((entry) => entry.sha256 !== repoHash);
    if (mismatched.length > 0) {
      const decision = latestTeddyDecisionForRepoHash(repoHash);
      if (decision?.promotionAllowed === false) {
        return lane("native_install_identity", "skipped", {
          reason: "repo binary promotion blocked by fresh Teddy kernel decision; native install intentionally remains on the last promoted binary",
          repo: {
            path: repoIx,
            sha256: repoHash,
          },
          installed,
          mismatched,
          decision,
        });
      }
    }
    return lane("native_install_identity", mismatched.length === 0 ? "ok" : "failed", {
      failures: mismatched.map((entry) => `${entry.path}: hash does not match repo ix-zig.exe`),
      repo: {
        path: repoIx,
        sha256: repoHash,
      },
      installed,
    });
  }

  function latestDistinctNativeBackup(repoHash) {
    if (!existsSync(nativeInstallDir)) return null;
    const backupDir = path.join(nativeInstallDir, "backups");
    if (!existsSync(backupDir)) return null;
    return readdirSync(backupDir)
      .filter((name) => /^ix(?:\.exe)?[.-]/.test(name))
      .map((name) => {
        const fullPath = path.join(backupDir, name);
        return { path: fullPath, label: name.replace(/^ix\.exe\./, ""), mtimeMs: statSync(fullPath).mtimeMs };
      })
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .find((candidate) => sha256File(candidate.path) !== repoHash) ?? null;
  }

  return {
    latestDistinctNativeBackup,
    nativeInstallIdentityLane,
    sha256File,
  };
}
