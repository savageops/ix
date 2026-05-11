param(
    [string]$Zig = "C:\Users\Savage\.local\zig\zig-x86_64-windows-0.16.0\zig.exe"
)

$ErrorActionPreference = "Stop"

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)
if (-not $isWindowsHost) {
    Write-Error "USN journal smoke is Windows-only; directory-watch fallback is validated by unit tests on other hosts."
}

if (-not (Test-Path -LiteralPath $Zig)) {
    Write-Error "Zig binary not found at '$Zig'. Pass -Zig <path> to override."
}

Write-Host "ix USN smoke: validating journal cursor, record mapping, continuity, fallback, and generation publish paths"
& $Zig build test --summary all
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "ix USN smoke: complete"
