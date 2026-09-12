function ConvertTo-WinPkgsTimeSpan {
    # "30d", "12h", "90m"; a bare number is days.
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -notmatch '^(\d+)([dhm]?)$') { throw "Not a duration: '$Text' (use e.g. 30d, 12h, 90m)" }
    $n = [int]$Matches[1]
    switch ($Matches[2]) {
        'h' { return [timespan]::FromHours($n) }
        'm' { return [timespan]::FromMinutes($n) }
        default { return [timespan]::FromDays($n) }
    }
}

function Invoke-WinPkgsGarbageCollect {
    <#
    .SYNOPSIS
        Delete old generations of one kind: the closures they keep, their
        journals and their backups.

    .DESCRIPTION
        The newest -Keep generations are never touched, whatever their age, and
        neither is the current one, wherever it is -- it is what the machine is
        on. Beyond those, everything goes -- or, with -OlderThan, only those
        started longer ago than that. Returns the generations removed (or, with
        -DryRun, the ones that would be).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [int]$Keep = 10,
        [string]$OlderThan,
        [switch]$DryRun
    )

    $generations = @(Get-WinPkgsGeneration -Kind $Kind | Sort-Object Generation)
    $excess = $generations.Count - [Math]::Max($Keep, 0)
    if ($excess -le 0) { return @() }
    $candidates = @($generations | Select-Object -First $excess | Where-Object { -not $_.Current })

    if ($OlderThan) {
        $cutoff = (Get-Date) - (ConvertTo-WinPkgsTimeSpan -Text $OlderThan)
        $candidates = @($candidates | Where-Object {
            $started = [datetime]::MinValue
            [datetime]::TryParse([string]$_.Started, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$started) -and $started -lt $cutoff
        })
    }

    foreach ($g in $candidates) {
        if (-not $DryRun) { Remove-Item -LiteralPath $g.Path -Recurse -Force }
        $g
    }
}
