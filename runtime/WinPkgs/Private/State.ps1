<#
    State lives on the Windows side, one tree per scope:

      <state>\state.json                 ledger + generation counter
      <state>\generations\NNN\journal.json
      <state>\generations\NNN\config.json
      <state>\generations\NNN\files\      Backup() output

    WINPKGS_STATE_DIR overrides the location (used by tests).
#>

function Get-WinPkgsStateDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope)

    if ($env:WINPKGS_STATE_DIR) { return (Join-Path $env:WINPKGS_STATE_DIR $Scope) }
    if ($Scope -eq 'machine') { return (Join-Path $env:ProgramData 'winpkgs') }
    return (Join-Path $env:LOCALAPPDATA 'winpkgs')
}

function Read-WinPkgsState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope)

    $file = Join-Path (Get-WinPkgsStateDir -Scope $Scope) 'state.json'
    $state = @{}
    if (Test-Path -LiteralPath $file) {
        $state = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    }
    if (-not $state.ContainsKey('generation')) { $state['generation'] = 0 }
    if (-not $state.ContainsKey('owned')) { $state['owned'] = @{} }
    foreach ($backend in 'winget', 'files') {
        if (-not $state['owned'].ContainsKey($backend)) { $state['owned'][$backend] = @() }
        $state['owned'][$backend] = @($state['owned'][$backend])
    }
    return $state
}

function Save-WinPkgsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope,
        [Parameter(Mandatory)][hashtable]$State
    )
    $dir = Get-WinPkgsStateDir -Scope $Scope
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
}

function Add-WinPkgsOwned {
    param([hashtable]$Context, [Parameter(Mandatory)][string]$Backend, [Parameter(Mandatory)][string]$Id)
    if (-not $Context -or -not $Context['State']) { return }
    $owned = @($Context['State']['owned'][$Backend] | Where-Object { $_ -ne $Id })
    $Context['State']['owned'][$Backend] = $owned + @($Id)
}

function Remove-WinPkgsOwned {
    param([hashtable]$Context, [Parameter(Mandatory)][string]$Backend, [Parameter(Mandatory)][string]$Id)
    if (-not $Context -or -not $Context['State']) { return }
    $Context['State']['owned'][$Backend] = @($Context['State']['owned'][$Backend] | Where-Object { $_ -ne $Id })
}

function Get-WinPkgsNextGeneration {
    <#
    .SYNOPSIS
        Allocate the next generation number. One number space across both
        scopes, so a generation identifies itself without a scope: the counter
        lives in the user state directory, which the elevated child (the same
        user, elevated) can write as well. Persisted before use, so a crash
        still leaves a numbered record.
    #>
    $counter = Join-Path (Get-WinPkgsStateDir -Scope user) 'generation'
    if (Test-Path -LiteralPath $counter) {
        $n = [int](Get-Content -LiteralPath $counter -Raw).Trim()
    } else {
        # First run with a shared counter: continue above anything already on
        # disk from the days of per-scope counters.
        $n = 0
        foreach ($s in 'user', 'machine') {
            $root = Join-Path (Get-WinPkgsStateDir -Scope $s) 'generations'
            if (Test-Path -LiteralPath $root) {
                foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
                    $v = 0
                    if ([int]::TryParse($d.Name, [ref]$v) -and $v -gt $n) { $n = $v }
                }
            }
        }
    }
    $n++
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $counter) | Out-Null
    Set-Content -LiteralPath $counter -Value "$n" -Encoding utf8
    return $n
}

function New-WinPkgsGeneration {
    <#
    .SYNOPSIS
        Create the directory for a new generation in a scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$Kind = 'apply'
    )
    $number = Get-WinPkgsNextGeneration
    $State['generation'] = $number
    $dir = Join-Path (Get-WinPkgsStateDir -Scope $Scope) ('generations\{0:D3}' -f $number)
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'files') | Out-Null
    if (Test-Path -LiteralPath $ConfigPath) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $dir 'config.json') -Force
    }
    Save-WinPkgsState -Scope $Scope -State $State

    return @{
        number  = $number
        dir     = $dir
        kind    = $Kind
        started = (Get-Date).ToString('o')
        entries = [System.Collections.Generic.List[object]]::new()
    }
}

function Save-WinPkgsJournal {
    param([Parameter(Mandatory)][hashtable]$Generation)
    @{
        number  = $Generation.number
        kind    = $Generation.kind
        started = $Generation.started
        entries = @($Generation.entries)
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Generation.dir 'journal.json') -Encoding utf8
}

function Get-WinPkgsGeneration {
    <#
    .SYNOPSIS
        List recorded generations across scopes, oldest first.
    #>
    [CmdletBinding()]
    param([ValidateSet('user', 'machine')][string[]]$Scope = @('user', 'machine'))

    $all = foreach ($s in $Scope) {
        $root = Join-Path (Get-WinPkgsStateDir -Scope $s) 'generations'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
            $journalPath = Join-Path $d.FullName 'journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { continue }
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
            [pscustomobject]@{
                Generation = [int]$journal['number']
                Scope      = $s
                Kind       = $journal['kind']
                Started    = $journal['started']
                Changes    = @($journal['entries']).Count
                Path       = $d.FullName
            }
        }
    }
    $all | Sort-Object Generation, Scope
}

function Find-WinPkgsGenerationScope {
    <#
    .SYNOPSIS
        Which scope holds generation N. Generations from before the shared
        counter may exist in both; that needs an explicit -Scope.
    #>
    param([Parameter(Mandatory)][int]$Generation)
    $found = @(foreach ($s in 'user', 'machine') {
        $journal = Join-Path (Get-WinPkgsStateDir -Scope $s) ('generations\{0:D3}\journal.json' -f $Generation)
        if (Test-Path -LiteralPath $journal) { $s }
    })
    if ($found.Count -eq 0) { throw "No generation $Generation in any scope (see: winpkgs generations)" }
    if ($found.Count -gt 1) {
        throw "Generation $Generation exists in both user and machine scope (numbering was per-scope before it became shared); pass -Scope user or -Scope machine"
    }
    return $found[0]
}
