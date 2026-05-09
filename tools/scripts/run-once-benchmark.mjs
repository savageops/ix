import { runOneBenchmark } from "./lib/benchmark-runner.mjs";
import { argValue } from "./lib/script-helpers.mjs";

const args = process.argv.slice(2);
const expression = argValue(args, "--expression", undefined);
const corpus = argValue(args, "--corpus", undefined);
const profile = argValue(args, "--profile", "single");
const ixBinary = argValue(args, "--ix-binary", undefined);
const previousIxBinary = argValue(args, "--previous-ix-binary", process.env.IX_PREVIOUS_BINARY ?? undefined);
const rustIxBinary = argValue(args, "--rust-ix-binary", process.env.IX_RUST_BINARY ?? undefined);
const threadsArg = argValue(args, "--threads", undefined);
const threads = threadsArg ? Number(threadsArg) : undefined;
const warmupArg = argValue(args, "--warmup", "1");
const samplesArg = argValue(args, "--samples", "1");
const warmup = Number(warmupArg);
const samples = Number(samplesArg);
const quiet = args.includes("--quiet");

const run = runOneBenchmark({
  expression,
  corpus,
  profile,
  ixBinaryPath: ixBinary,
  previousIxBinaryPath: previousIxBinary,
  rustIxBinaryPath: rustIxBinary,
  threads,
  warmup,
  samples,
  write: true,
});

if (!quiet) {
  console.log(JSON.stringify(run, null, 2));
}
