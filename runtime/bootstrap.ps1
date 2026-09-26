<#
.SYNOPSIS
    Prepare a fresh Windows machine for winpkgs and optionally run it.

.DESCRIPTION
    The only file in the runtime that must run under Windows PowerShell 5.1,
    because that is all a clean install has. It installs PowerShell 7 and the
    Microsoft.WinGet.Client module via winget, then hands off to winpkgs.ps1.

    Two ways in:

      # A closure is already on disk (e.g. reached via \\wsl.localhost from activate)
      bootstrap.ps1 -Then apply -Config <closure>\config.json

      # No WSL yet: clone a repo that has a committed closure and apply it
      bootstrap.ps1 -Repo https://github.com/you/config -Path closures/desktop

.NOTES
    Requires winget, which ships with Windows 11 and updated Windows 10.
#>
[CmdletBinding()]
param(
    # winpkgs.ps1 command to run afterwards (plan | apply).
    [string]$Then,
    [string]$Config,
    [string]$Scope,
    [switch]$NoElevate,

    # Git URL of a repository containing a committed closure.
    [string]$Repo,
    # Path of the closure directory inside that repository.
    [string]$Path = '.',
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'
# winget reports "already installed, nothing to upgrade" as a non-zero exit
# (-1978335189), and Install-WithWinGet below treats that as success -- which it
# can only do if a non-zero exit reaches it as a code rather than an exception.
# Same for the git calls that follow.
$PSNativeCommandUseErrorActionPreference = $false

function Test-CommandAvailable([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-WithWinGet([string]$Id, [string]$InstallerType) {
    Write-Host "bootstrap: installing $Id"
    $choice = if ($InstallerType) { @('--installer-type', $InstallerType) } else { @() }
    & winget install --id $Id --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity @choice
    # 0x8A15002B: already installed and no applicable upgrade.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # --installer-type is not in every winget a clean machine has, and a
        # manifest need not offer the type asked for. Neither is worth failing a
        # bootstrap over when the package itself is available: say so, take
        # whatever winget serves by default, and let the caller check what it got.
        if ($InstallerType) {
            Write-Warning "winget could not install $Id as $InstallerType (exit $LASTEXITCODE); taking its default installer"
            Install-WithWinGet $Id
            return
        }
        throw "winget install $Id failed with exit code $LASTEXITCODE"
    }
    Update-SessionPath
}

if (-not (Test-CommandAvailable winget)) {
    throw "winget is not available. Install 'App Installer' from the Microsoft Store (or let Windows Update finish), then re-run."
}

# An *unpackaged* pwsh, by preference: a UAC-elevated MSIX pwsh cannot write
# HKLM, so Get-WinPkgsElevationHost will not run the machine-scope phase in one
# and falls back to Windows PowerShell -- where the WinGet client module cannot
# read installed packages at all (Test-WinPkgsWinGetModuleReads). winget serves
# Microsoft.PowerShell as the MSIX by default from 7.6 and only the MSIX from
# 7.7, so the .msi is asked for by name -- winget calls that installer type
# `wix` -- and this stops being possible at 7.7, when the warning below is all
# that is left. It is a nicety either way: winget reads fall back to winget.exe.
$unpackagedPwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $unpackagedPwsh)) {
    Install-WithWinGet Microsoft.PowerShell -InstallerType wix
}
if (-not (Test-CommandAvailable pwsh)) {
    throw 'pwsh is installed but not yet on PATH. Open a new terminal and re-run.'
}
if (-not (Test-Path -LiteralPath $unpackagedPwsh)) {
    # Not fatal: the machine-scope phase still runs under Windows PowerShell,
    # and winget reads there go through winget.exe.
    Write-Warning "no unpackaged pwsh at $unpackagedPwsh; the machine-scope phase will run under Windows PowerShell 5.1"
}

Write-Host 'bootstrap: ensuring Microsoft.WinGet.Client module'
# Passed base64-encoded: Windows PowerShell strips embedded double quotes from
# arguments to native executables, which would mangle a -Command string.
$ensureModule = @'
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        Install-PSResource Microsoft.WinGet.Client -Scope CurrentUser -TrustRepository -Quiet -AcceptLicense
    } else {
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -AcceptLicense
    }
}
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ensureModule))
& pwsh -NoProfile -NoLogo -EncodedCommand $encoded
if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Microsoft.WinGet.Client module' }

# The elevated phase runs under Windows PowerShell when pwsh is the MSIX build,
# and Windows PowerShell has its own module directory.
if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
    Write-Host 'bootstrap: ensuring Microsoft.WinGet.Client for Windows PowerShell'
    # The PowerShellGet a clean Windows ships -- 1.0.0.1 -- has no
    # -AcceptLicense, and passing a parameter it does not have is an error
    # rather than a no-op. -Force covers what it is otherwise there for: the
    # NuGet provider and the untrusted-repository prompt.
    $moduleArgs = @{ Name = 'Microsoft.WinGet.Client'; Scope = 'CurrentUser'; Force = $true }
    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) {
        $moduleArgs['AcceptLicense'] = $true
    }
    Install-Module @moduleArgs
}

$entry = Join-Path $PSScriptRoot 'winpkgs.ps1'

if ($Repo) {
    if (-not (Test-CommandAvailable git)) { Install-WithWinGet Git.Git }
    $dest = Join-Path $env:LOCALAPPDATA 'winpkgs\src'
    if (Test-Path (Join-Path $dest '.git')) {
        Write-Host "bootstrap: updating $dest"
        & git -C $dest fetch --quiet origin
        & git -C $dest checkout --quiet $Ref
        & git -C $dest pull --quiet --ff-only
    } else {
        Write-Host "bootstrap: cloning $Repo into $dest"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        & git clone --quiet --branch $Ref $Repo $dest
    }
    if ($LASTEXITCODE -ne 0) { throw 'git failed' }

    $closure = Join-Path $dest $Path
    $Config = Join-Path $closure 'config.json'
    $entry = Join-Path $closure 'runtime\winpkgs.ps1'
    if (-not $Then) { $Then = 'apply' }
}

if ($Then) {
    $forward = @($Then, '-Config', $Config)
    if ($Scope) { $forward += @('-Scope', $Scope) }
    if ($NoElevate) { $forward += '-NoElevate' }
    & pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $entry @forward
    exit $LASTEXITCODE
}

Write-Host 'bootstrap: done. pwsh and Microsoft.WinGet.Client are installed.'
