Set-StrictMode -Version Latest

# Returns the middle observed value without averaging away host-noise outliers.
function Get-IxMedian {
  param([double[]]$Values)
  if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  return $sorted[[int][math]::Floor($sorted.Count / 2)]
}

# Reports resource context without pretending thread or memory scaling is linear.
function Get-IxResourceNormalization {
  param(
    [double]$WallMs,
    [int]$Threads = 1,
    [Nullable[long]]$PeakResidentBytes = $null,
    [Nullable[long]]$AllocationLimitBytes = $null
  )
  $effectiveThreads = [math]::Max(1, $Threads)
  $peakMiB = if ($null -eq $PeakResidentBytes) { $null } else { [math]::Round(([long]$PeakResidentBytes) / 1MB, 3) }
  $memoryFraction = if ($null -eq $PeakResidentBytes -or $null -eq $AllocationLimitBytes -or [long]$AllocationLimitBytes -le 0) {
    $null
  } else {
    [math]::Round(([long]$PeakResidentBytes) / ([long]$AllocationLimitBytes), 8)
  }
  return [pscustomobject]@{
    threads = $effectiveThreads
    wall_ms = [math]::Round($WallMs, 4)
    rough_linear_one_thread_ms = [math]::Round($WallMs * $effectiveThreads, 4)
    peak_resident_mib = $peakMiB
    allocation_fraction = $memoryFraction
    interpretation = 'rough_linear_one_thread_ms is a work proxy only; measured one-thread timing and scan_work_ms_total outrank it'
  }
}

# Compares two rows only when both carry valid timing and resource evidence.
function Compare-IxResourceProfiles {
  param($Candidate, $Predecessor)
  if ($null -eq $Candidate -or $null -eq $Predecessor) { return $null }
  $candidateRatio = if ([double]$Predecessor.wall_ms -eq 0) { $null } else { [math]::Round([double]$Candidate.wall_ms / [double]$Predecessor.wall_ms, 6) }
  $workRatio = if ([double]$Predecessor.rough_linear_one_thread_ms -eq 0) { $null } else { [math]::Round([double]$Candidate.rough_linear_one_thread_ms / [double]$Predecessor.rough_linear_one_thread_ms, 6) }
  $memoryRatio = if ($null -eq $Candidate.peak_resident_mib -or $null -eq $Predecessor.peak_resident_mib -or [double]$Predecessor.peak_resident_mib -eq 0) {
    $null
  } else {
    [math]::Round([double]$Candidate.peak_resident_mib / [double]$Predecessor.peak_resident_mib, 6)
  }
  return [pscustomobject]@{
    wall_ratio = $candidateRatio
    rough_thread_work_ratio = $workRatio
    peak_memory_ratio = $memoryRatio
    authoritative = $false
    reason = 'resource normalization explains configuration asymmetry; parity-matched measured timings decide promotion'
  }
}
