<#
.SYNOPSIS
    Restore and verify ignored IX reference payloads from .refs/index.md.

.DESCRIPTION
    This is the only networked acquisition path for IX references. zig build
    remains offline and never invokes this script implicitly.
#>
[CmdletBinding()]
param(
    [ValidateSet('build', 'research', 'all')]
    [string]$Group = 'build',
    [switch]$VerifyOnly,
    [string]$RefsRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) { throw "refs bootstrap: $Message" }

function Read-Manifest([string]$ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Fail "manifest not found: $ManifestPath" }
    $text = Get-Content -LiteralPath $ManifestPath -Raw
    $match = [regex]::Match($text, '(?s)```json\s+refs-manifest-v1\s*(.*?)\s*```')
    if (-not $match.Success) { Fail 'manifest is missing refs-manifest-v1 JSON' }
    try { $manifest = $match.Groups[1].Value | ConvertFrom-Json } catch { Fail "manifest JSON is invalid: $($_.Exception.Message)" }
    if ($manifest.schema -ne 'ix.refs.v1') { Fail "unsupported manifest schema: $($manifest.schema)" }
    if ($null -eq $manifest.entries -or $manifest.entries.Count -eq 0) { Fail 'manifest has no entries' }
    return $manifest
}

function Validate-Entry($Entry) {
    foreach ($field in @('id','role','status','provider','repository','source_url','archive_url','ref','commit_sha','archive_sha256','license','local_path','rationale')) {
        if ([string]::IsNullOrWhiteSpace([string]$Entry.$field)) { Fail "entry $($Entry.id) is missing $field" }
    }
    if ($Entry.provider -ne 'github') { Fail "entry $($Entry.id) uses unsupported provider $($Entry.provider)" }
    if ($Entry.role -notin @('build','research')) { Fail "entry $($Entry.id) has invalid role $($Entry.role)" }
    if ($Entry.source_url -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$') { Fail "entry $($Entry.id) has an unqualified source URL" }
    if ($Entry.archive_url -notmatch '^https://codeload\.github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/zip/[0-9a-f]{40}$') { Fail "entry $($Entry.id) has an unqualified archive URL" }
    if ($Entry.commit_sha -notmatch '^[0-9a-f]{40}$') { Fail "entry $($Entry.id) has an invalid commit SHA" }
    if ($Entry.archive_sha256 -notmatch '^[0-9A-Fa-f]{64}$') { Fail "entry $($Entry.id) has an invalid archive SHA-256" }
    if ([IO.Path]::IsPathRooted($Entry.local_path) -or $Entry.local_path -match '(^|[\\/])\.\.([\\/]|$)') { Fail "entry $($Entry.id) has an unsafe local path" }
    if ($Entry.local_path -match '(^|[\\/])\.git([\\/]|$)') { Fail "entry $($Entry.id) may not target .git" }
}

function Select-Entries($Manifest, [string]$SelectedGroup) {
    $seenIds = @{}
    $seenPaths = @{}
    foreach ($entry in $Manifest.entries) {
        Validate-Entry $entry
        if ($seenIds.ContainsKey($entry.id)) { Fail "duplicate entry id: $($entry.id)" }
        if ($seenPaths.ContainsKey($entry.local_path)) { Fail "duplicate local path: $($entry.local_path)" }
        $seenIds[$entry.id] = $true
        $seenPaths[$entry.local_path] = $true
    }
    if ($SelectedGroup -eq 'all') { return @($Manifest.entries) }
    return @($Manifest.entries | Where-Object { $_.role -eq $SelectedGroup })
}

function Assert-SafeArchive($ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $root = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in $archive.Entries) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail "archive contains an unsafe path: $($entry.FullName)" }
        }
    } finally { $archive.Dispose() }
}

function Get-Target([string]$Root, [string]$RelativePath) {
    $target = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { Fail "target escapes refs root: $RelativePath" }
    return $target
}

function Verify-Local($Entry, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { return $false }
    $markerPath = Join-Path $Target '.ix-ref.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail "existing ref has no provenance marker: $($Entry.local_path)" }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($marker.id -ne $Entry.id -or $marker.commit_sha -ne $Entry.commit_sha -or $marker.archive_sha256 -ne $Entry.archive_sha256) { Fail "existing ref marker does not match manifest: $($Entry.id)" }
    if ($Entry.PSObject.Properties['required_paths']) {
        foreach ($required in @($Entry.required_paths)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Target $required) -PathType Leaf)) { Fail "required path missing for $($Entry.id): $required" }
        }
    }
    return $true
}

function Ensure-GeneratedAliases($Entry, [string]$Target) {
    if ($Entry.PSObject.Properties['generated_aliases']) {
        foreach ($alias in @($Entry.generated_aliases)) {
            $source = Join-Path $Target $alias.from
            $destination = Join-Path $Target $alias.to
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { Fail "generated alias source missing for $($Entry.id): $($alias.from)" }
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination
            }
        }
    }
    if ($Entry.PSObject.Properties['generated_copies']) {
        foreach ($copy in @($Entry.generated_copies)) {
            $source = Join-Path $Target $copy.from
            $destination = Join-Path $Target $copy.to
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { Fail "generated copy source missing for $($Entry.id): $($copy.from)" }
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            foreach ($child in @(Get-ChildItem -LiteralPath $source -Force)) {
                $childDestination = Join-Path $destination $child.Name
                if (-not (Test-Path -LiteralPath $childDestination)) { Copy-Item -LiteralPath $child.FullName -Destination $destination -Recurse }
            }
        }
    }
    if ($Entry.PSObject.Properties['generated_empty_files']) {
        foreach ($relativePath in @($Entry.generated_empty_files)) {
            $destination = Join-Path $Target $relativePath
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
                Set-Content -LiteralPath $destination -Value "/* IX compatibility shim: upstream no longer ships this legacy build input. */" -Encoding UTF8
            }
        }
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $scriptRoot
$manifest = Read-Manifest (Join-Path $workspaceRoot '.refs\index.md')
$entries = Select-Entries $manifest $Group
$refsRootResolved = if ($RefsRoot) { [IO.Path]::GetFullPath($RefsRoot) } else { Join-Path $workspaceRoot '.refs' }
New-Item -ItemType Directory -Force -Path $refsRootResolved | Out-Null
$cacheRoot = Join-Path ([IO.Path]::GetTempPath()) 'ix-zig-ref-bootstrap'
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

foreach ($entry in $entries) {
    $target = Get-Target $refsRootResolved $entry.local_path
    if (Test-Path -LiteralPath $target -PathType Container) {
        Ensure-GeneratedAliases $entry $target
        if (Verify-Local $entry $target) { Write-Output "verified $($entry.id)"; continue }
    }
    if ($VerifyOnly) { Fail "missing ref in verify-only mode: $($entry.id) -> $($entry.local_path)" }

    $archivePath = Join-Path $cacheRoot "$($entry.id)-$($entry.commit_sha).zip"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "downloading $($entry.repository)@$($entry.commit_sha)"
        Invoke-WebRequest -Uri $entry.archive_url -OutFile $archivePath -UseBasicParsing -TimeoutSec 900
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $entry.archive_sha256) { Fail "archive hash mismatch for $($entry.id): expected $($entry.archive_sha256), got $actualHash" }

    $staging = Join-Path $cacheRoot "extract-$($entry.id)-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Assert-SafeArchive $archivePath $staging
        Expand-Archive -LiteralPath $archivePath -DestinationPath $staging -Force
        $children = @(Get-ChildItem -LiteralPath $staging -Force)
        $sourceRoot = if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $children[0].FullName } else { $staging }
        if (Test-Path -LiteralPath $target) { Fail "target appeared during bootstrap; refusing overwrite: $($entry.local_path)" }
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
        Move-Item -LiteralPath $sourceRoot -Destination $target
        Ensure-GeneratedAliases $entry $target
        $marker = [ordered]@{schema='ix.refs.marker.v1';id=$entry.id;repository=$entry.repository;commit_sha=$entry.commit_sha;archive_sha256=$entry.archive_sha256;source_url=$entry.source_url;verified_utc=[DateTime]::UtcNow.ToString('o')}
        $marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.ix-ref.json') -Encoding UTF8
        if (-not (Verify-Local $entry $target)) { Fail "post-extraction verification failed for $($entry.id)" }
        Write-Output "restored $($entry.id)"
    } finally {
        if (Test-Path -LiteralPath $staging) { [IO.Directory]::Delete($staging, $true) }
    }
}
Write-Output "refs bootstrap complete: $($entries.Count) $Group entries"
