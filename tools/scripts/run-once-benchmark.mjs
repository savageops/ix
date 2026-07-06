import { runOneBenchmark } from "./lib/benchmark-runner.mjs";
import { argValue } from "./lib/script-helpers.mjs";

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/run-once-benchmark.mjs [options]

Runs one IX/ripgrep benchmark scenario and writes the standard benchmark report.

Options:
  --expression <expr>             IX expression to search.
  --corpus <path>                 Corpus path.
  --profile <name>                Scenario/profile label. Default: single.
  --ix-binary <path>              IX binary to measure.
  --previous-ix-binary <path>     Optional previous IX comparator.
  --rust-ix-binary <path>         Optional Rust IX comparator.
  --paired-interleave             Interleave current and previous IX samples.
  --threads <n>                   IX/ripgrep thread count.
  --warmup <n>                    Warmup samples. Default: 1.
  --samples <n>                   Measured samples. Default: 1.
  --warm-index <0|1>              Enable IX warm index (IX_INDEX env). Default: 0.
  --nexus <0|1>                   Enable IX evidence frontier (IX_NEXUS env). Default: 0.
  --clear-warm-cache              Clear warm-index query cache before each sample (measures MISS path).
  --quiet                         Write reports without printing JSON.
  --help, -h                      Print this help and exit without measuring.
`);
  process.exit(0);
}
const expression = argValue(args, "--expression", undefined);
const corpus = argValue(args, "--corpus", undefined);
const profile = argValue(args, "--profile", "single");
const ixBinary = argValue(args, "--ix-binary", undefined);
const previousIxBinary = argValue(args, "--previous-ix-binary", process.env.IX_PREVIOUS_BINARY ?? undefined);
const rustIxBinary = argValue(args, "--rust-ix-binary", process.env.IX_RUST_BINARY ?? undefined);
const pairedPreviousInterleave = args.includes("--paired-interleave");
const threadsArg = argValue(args, "--threads", undefined);
const threads = threadsArg ? Number(threadsArg) : undefined;
const warmupArg = argValue(args, "--warmup", "1");
const samplesArg = argValue(args, "--samples", "1");
const warmup = Number(warmupArg);
const samples = Number(samplesArg);
const warmIndex = argValue(args, "--warm-index", "0");
const nexus = argValue(args, "--nexus", "0");
const clearWarmCache = args.includes("--clear-warm-cache");
const quiet = args.includes("--quiet");

const run = runOneBenchmark({
  expression,
  corpus,
  profile,
  ixBinaryPath: ixBinary,
  previousIxBinaryPath: previousIxBinary,
  pairedPreviousInterleave,
  rustIxBinaryPath: rustIxBinary,
  threads,
  warmup,
  samples,
  warmIndex,
  nexus,
  clearWarmCache,
  write: true,
});

if (!quiet) {
  console.log(JSON.stringify(run, null, 2));
}
