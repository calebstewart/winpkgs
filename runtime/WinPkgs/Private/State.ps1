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
        $state = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    }
    if (-not $state.ContainsKey('generation')) { $state['generation'] = 0 }
    if (-not $state.ContainsKey('owned')) { $state['owned'] = @{} }
    if (-not $state['owned'].ContainsKey('winget')) { $state['owned']['winget'] = @() }
    $state['owned']['winget'] = @($state['owned']['winget'])
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

function New-WinPkgsGeneration {
    <#
    .SYNOPSIS
        Allocate the next generation directory for a scope and persist the
        bumped counter immediately, so a crash still leaves a numbered record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$Kind = 'apply'
    )
    $State['generation'] = [int]$State['generation'] + 1
    $number = [int]$State['generation']
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
        List recorded generations, newest last.
    #>
    [CmdletBinding()]
    param([ValidateSet('user', 'machine')][string[]]$Scope = @('user', 'machine'))

    foreach ($s in $Scope) {
        $root = Join-Path (Get-WinPkgsStateDir -Scope $s) 'generations'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name) {
            $journalPath = Join-Path $d.FullName 'journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { continue }
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            [pscustomobject]@{
                Scope      = $s
                Generation = [int]$journal['number']
                Kind       = $journal['kind']
                Started    = $journal['started']
                Changes    = @($journal['entries']).Count
                Path       = $d.FullName
            }
        }
    }
}
