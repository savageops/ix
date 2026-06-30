import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { runOneBenchmark } from "./lib/benchmark-runner.mjs";
import { argValue, sleep } from "./lib/script-helpers.mjs";

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/bench-loop-suite.mjs [options]

Runs the benchmark profile suite once by default. Use --loops 0 only for an
intentional continuous monitor.

Options:
  --loops <n>                 Suite loops to run. Default: 1. Use 0 for forever.
  --delay-ms <n>              Delay between profiles. Default: 0.
  --ix-binary <path>          IX binary to measure.
  --previous-ix-binary <path> Optional previous IX comparator.
  --rust-ix-binary <path>     Optional Rust IX comparator.
  --threads <n>               IX/ripgrep thread count.
  --warmup <n>                Warmup samples per profile. Default: 1.
  --samples <n>               Measured samples per profile. Default: 1.
  --help, -h                  Print this help and exit without measuring.
`);
  process.exit(0);
}
const loops = Number(argValue(args, "--loops", "1"));
const delayMs = Number(argValue(args, "--delay-ms", "0"));
const ixBinary = argValue(args, "--ix-binary", undefined);
const previousIxBinary = argValue(args, "--previous-ix-binary", process.env.IX_PREVIOUS_BINARY ?? undefined);
const rustIxBinary = argValue(args, "--rust-ix-binary", process.env.IX_RUST_BINARY ?? undefined);
const threadsArg = argValue(args, "--threads", undefined);
const threads = threadsArg ? Number(threadsArg) : undefined;
const warmup = Number(argValue(args, "--warmup", "1"));
const samples = Number(argValue(args, "--samples", "1"));

const ROOT = process.cwd();
const SUITE_DIR = process.env.IX_BENCHSUITE_DIR ?? path.join(ROOT, ".refs", "ripgrep", "benchsuite");
const EN_SAMPLE = path.join(SUITE_DIR, "subtitles", "en.sample.txt");
const RU_FILE = path.join(SUITE_DIR, "subtitles", "ru.txt");
const LINUX_DIR = path.join(SUITE_DIR, "linux");
const LINUX_BUILT = path.join(LINUX_DIR, "vmlinux");

function buildProfiles() {
  const profiles = [];

  if (existsSync(EN_SAMPLE)) {
    profiles.push(
      { name: "suite-en-literal", expression: "lit:Sherlock Holmes", corpus: EN_SAMPLE },
      { name: "suite-en-literal-casei", expression: "re:(?i)Sherlock Holmes", corpus: EN_SAMPLE },
      { name: "suite-en-word", expression: "re:\\bSherlock Holmes\\b", corpus: EN_SAMPLE },
      {
        name: "suite-en-alternates",
        expression: "re:(Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty)",
        corpus: EN_SAMPLE,
      },
      { name: "suite-en-surrounding-words", expression: "re:\\w+\\s+Holmes\\s+\\w+", corpus: EN_SAMPLE },
      { name: "suite-en-no-literal", expression: "re:\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}", corpus: EN_SAMPLE },
    );
  }

  if (existsSync(RU_FILE)) {
    const ruName = "\u0428\u0435\u0440\u043b\u043e\u043a \u0425\u043e\u043b\u043c\u0441";
    profiles.push(
      { name: "suite-ru-literal", expression: `lit:${ruName}`, corpus: RU_FILE },
      { name: "suite-ru-literal-casei", expression: `re:(?i)${ruName}`, corpus: RU_FILE },
    );
  }

  if (existsSync(LINUX_BUILT)) {
    profiles.push(
      { name: "suite-linux-literal", expression: "lit:PM_RESUME", corpus: LINUX_DIR },
      { name: "suite-linux-word", expression: "re:\\bPM_RESUME\\b", corpus: LINUX_DIR },
      { name: "suite-linux-alternates", expression: "re:(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)", corpus: LINUX_DIR },
      { name: "suite-linux-no-literal", expression: "re:\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}", corpus: LINUX_DIR },
    );
  }

  return profiles;
}

async function main() {
  mkdirSync(path.join(ROOT, "tools", "reports"), { recursive: true });

  const profiles = buildProfiles();
  if (profiles.length === 0) {
    console.error(
      `No ripgrep benchsuite corpora detected.\n` +
      `Set IX_BENCHSUITE_DIR or ensure .refs/ripgrep/benchsuite/subtitles/en.sample.txt exists.\n` +
      `Suite dir checked: ${SUITE_DIR}`,
    );
    process.exitCode = 1;
    return;
  }

  console.log(`IX-Zig bench suite: ${profiles.length} profiles, suite dir: ${SUITE_DIR}`);
  if (previousIxBinary) {
    console.log(`Previous IX binary: ${previousIxBinary}`);
  }
  if (rustIxBinary) {
    console.log(`Rust IX binary: ${rustIxBinary}`);
  }

  let rounds = 0;
  while (rounds < loops || loops === 0) {
    for (const profile of profiles) {
      const run = runOneBenchmark({
        profile: profile.name,
        expression: profile.expression,
        corpus: profile.corpus,
        ixBinaryPath: ixBinary,
        previousIxBinaryPath: previousIxBinary,
        rustIxBinaryPath: rustIxBinary,
        threads,
        warmup,
        samples,
        write: true,
      });
      const goalState = run.speedupPct >= 50 ? "goal-hit" : "goal-miss";
      const ratio = run.iexToRgRatio ?? (run.rgMs > 0 ? run.iexMs / run.rgMs : 0);
      const previous = run?.competitors?.iex_previous;
      const previousText =
        previous?.available && Number.isFinite(previous?.durationMs)
          ? ` prev=${previous.durationMs.toFixed(2)}ms prevRatio=${(run?.iexToPreviousRatio ?? 0).toFixed(3)}${previous?.comparatorAuthority === "timing_only" ? " prevAuthority=timing-only" : ""}`
          : "";
      const rust = run?.competitors?.iex_rust;
      const rustText =
        rust?.available && Number.isFinite(rust?.durationMs)
          ? ` rust=${rust.durationMs.toFixed(2)}ms rustRatio=${(run.iexMs / rust.durationMs).toFixed(3)}`
          : "";
      console.log(
        `[suite-loop ${rounds + 1}] ${profile.name} ratio=${ratio.toFixed(3)} ix=${run.iexMs.toFixed(2)}ms rg=${run.rgMs.toFixed(2)}ms${previousText}${rustText} speedup=${run.speedupPct.toFixed(2)}% hotspot=${run.hotspot} ${goalState}`,
      );
      await sleep(delayMs);
    }
    rounds += 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
