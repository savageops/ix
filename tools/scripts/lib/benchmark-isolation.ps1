param(
  [string]$Exe,
  [string]$ArgsLine,
  [string]$WorkingDirectory,
  [string]$PriorityClass,
  [string]$AffinityMaskHex,
  [string]$EnvJson,
  [string]$CaptureStdout,
  [string]$CaptureStderr
)

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $Exe
$psi.Arguments = $ArgsLine
$psi.WorkingDirectory = $WorkingDirectory
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = ($CaptureStdout -eq "1")
$psi.RedirectStandardError = ($CaptureStderr -eq "1")
$psi.CreateNoWindow = $true

$envMap = @{}
if ($EnvJson) {
  $parsed = $EnvJson | ConvertFrom-Json
  if ($parsed) {
    $parsed.PSObject.Properties | ForEach-Object {
      $envMap[$_.Name] = [string]$_.Value
    }
  }
}
foreach ($entry in $envMap.GetEnumerator()) {
  $psi.EnvironmentVariables[$entry.Key] = $entry.Value
}

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = $proc.Start()

$priorityError = $null
$appliedPriorityClass = $null
if ($PriorityClass) {
  try {
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$PriorityClass
    $appliedPriorityClass = $proc.PriorityClass.ToString()
  } catch {
    $priorityError = $_.Exception.Message
  }
}

$affinityError = $null
$appliedAffinityMaskHex = $null
if ($AffinityMaskHex) {
  try {
    $maskValue = [UInt64]$AffinityMaskHex
    $proc.ProcessorAffinity = [IntPtr]::new([Int64]$maskValue)
    $appliedAffinityMaskHex = ("0x{0:X}" -f [UInt64]$proc.ProcessorAffinity.ToInt64())
  } catch {
    $affinityError = $_.Exception.Message
  }
}

$stdoutTask = if ($psi.RedirectStandardOutput) { $proc.StandardOutput.ReadToEndAsync() } else { $null }
$stderrTask = if ($psi.RedirectStandardError) { $proc.StandardError.ReadToEndAsync() } else { $null }
$proc.WaitForExit()
$stdout = if ($stdoutTask) { $stdoutTask.GetAwaiter().GetResult() } else { "" }
$stderr = if ($stderrTask) { $stderrTask.GetAwaiter().GetResult() } else { "" }
$sw.Stop()

[pscustomobject]@{
  status = $proc.ExitCode
  durationMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 6)
  stdout = $stdout
  stderr = $stderr
  benchmarkIsolation = [pscustomobject]@{
    mode = "enforce"
    requestedPriorityClass = $PriorityClass
    appliedPriorityClass = $appliedPriorityClass
    requestedAffinityMaskHex = $AffinityMaskHex
    appliedAffinityMaskHex = $appliedAffinityMaskHex
    priorityError = $priorityError
    affinityError = $affinityError
  }
} | ConvertTo-Json -Compress -Depth 6
