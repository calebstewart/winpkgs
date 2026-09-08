<#
    Installed as %LOCALAPPDATA%\winpkgs\bin\winpkgs.ps1. Deliberately Windows
    PowerShell 5.1-compatible: typing `winpkgs` in a 5.1 prompt resolves to this
    file and runs it *in 5.1*, so it must not need anything newer itself. The
    real CLI (..\runtime\cli.ps1) needs pwsh 7; hand off to it.
#>
$cli = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\cli.ps1'
if (-not (Test-Path -LiteralPath $cli)) {
    Write-Error "winpkgs runtime not found at $cli. Re-run the activation from WSL once."
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    & $cli @args
    exit $LASTEXITCODE
}

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
    Write-Error "winpkgs needs PowerShell 7 (pwsh), which is not installed. Install it with: winget install Microsoft.PowerShell"
    exit 1
}
& $pwsh.Source -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli @args
exit $LASTEXITCODE
