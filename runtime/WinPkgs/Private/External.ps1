<#
    Running an external command, where the exit code is data rather than an
    exception.

    The module runs under `$ErrorActionPreference = 'Stop'`, and two different
    hosts turn a perfectly ordinary external command into a terminating error
    under it -- both of them *before* the exit code can be read:

      - Windows PowerShell 5.1 turns whatever a native command writes to
        stderr, once it is redirected with 2>&1, into an ErrorRecord. reg.exe
        and winget chat on stderr when they succeed, so this fires on success.

      - PowerShell 7.3+ with `$PSNativeCommandUseErrorActionPreference` on
        promotes a non-zero exit code itself. It is off by default, but it is a
        host setting: a profile, a CI image or a future default can turn it on
        under a runtime that never asked for it.

    Neither belongs here. Every caller in this module reads an exit code and
    decides for itself what it means -- powercfg answers /query for a hidden
    setting with a header and exit 0, winget says -1978335189 for "already
    installed", w32tm fails /resync with no network and that must not fail an
    apply. So both behaviours are switched off for the duration of the call,
    and the result is returned as data.

    The try/catch is not redundant: the WINPKGS_* test hooks name a .ps1 shim
    rather than an .exe, and a script's Write-Error still throws under 'Stop'
    if anything upstream re-raises the preference.
#>
function Invoke-WinPkgsExternal {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @()
    )
    # Function-scoped: these shadow the caller's values for this call only.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $out = @()
    $thrown = ''
    $code = 0
    try {
        $out = & $Command @Arguments 2>&1
        # A command that sets no exit code (nothing native has run in this
        # session yet) is a success, not a null failure.
        $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        $code = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
        $thrown = $_.Exception.Message
    }

    $lines = @($out | ForEach-Object { [string]$_ })
    return @{
        failed = ($code -ne 0)
        code   = $code
        lines  = $lines
        text   = ((@($lines) + $thrown) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
    }
}
