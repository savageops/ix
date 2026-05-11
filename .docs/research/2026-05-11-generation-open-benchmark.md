# Generation Open Benchmark Gate

Generated: 2026-05-11

## Scope

This gate measures the current warm-generation open boundary introduced by chain `140`.

Measured target:

```text
.ix/index/current.ixgen
  -> small stable current-generation manifest pointer
  -> foreground search will later open + validate before warm candidate pruning
```

This is not a foreground-acceleration claim. Search adoption is still disabled until candidate selection opens catalog/postings segments and proves verifier-equivalent results.

## Commands

Release build:

```powershell
C:\Users\Savage\.local\zig\zig-x86_64-windows-0.16.0\zig.exe build -Doptimize=ReleaseFast --summary all
```

Output:

```text
Build Summary: 3/3 steps succeeded
install success
+- install ix-zig success
   +- compile exe ix-zig ReleaseFast native success 13s MaxRSS:351M
```

Current-manifest read microbenchmark:

```powershell
[System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$benchRoot = '.zig-cache\ix-generation-open-benchmark'
New-Item -ItemType Directory -Force -Path $benchRoot | Out-Null
$path = [System.IO.Path]::GetFullPath((Join-Path $benchRoot 'current.ixgen'))
$bytes = [byte[]](0..127)
[System.IO.File]::WriteAllBytes($path, $bytes)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i=0; $i -lt 10000; $i++) {
  $data = [System.IO.File]::ReadAllBytes($path)
  if ($data.Length -ne 128) { throw 'bad read' }
}
$sw.Stop()
```

Output:

```text
current_manifest_read_10000_total_ms=345.586; avg_us=34.559
```

Release public search comparator:

```powershell
[System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$results = @()
for ($i=0; $i -lt 5; $i++) {
  $elapsed = (Measure-Command {
    .\zig-out\bin\ix-zig.exe search 'lit:tryPinCurrentGeneration' src --json > $null
  }).TotalMilliseconds
  $results += [math]::Round($elapsed, 3)
}
'release_search_ms=' + ($results -join ', ')
```

Output:

```text
release_search_ms=10.787, 7.533, 6.615, 6.327, 6.705
```

## Interpretation

The measured stable-manifest open/read cost is approximately `34.559 us` per 128-byte pointer file on this Windows host using a .NET read proxy. The release search comparator runs in approximately `6.3-10.8 ms` for the measured `src` query after the first release execution settles.

The benchmark supports the architecture boundary: opening a tiny current-generation manifest is small relative to a foreground search. It does not yet measure full Zig manifest validation, mmap segment opening, postings lookup, or end-to-end warm pruning. Those belong to the later foreground-adoption chains.

## Gate Result

Pass for chain `140n`.

The current-manifest pointer is cheap enough to keep on the foreground admission path, provided it remains fail-closed and no synchronous index construction is introduced.
