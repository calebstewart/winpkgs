<#
    State lives on the Windows side, one tree per kind of configuration:

      %ProgramData%\winpkgs\system\    the machine; written elevated, writable by administrators only
      %LOCALAPPDATA%\winpkgs\home\     this user
        state.json                     ledger: what winpkgs installed / created (winget ids, file targets, fonts -> files, services),
                                       and the revision each activation last ran at
        generations\NNN\journal.json   one sequence per kind
        generations\NNN\config.json
        generations\NNN\files\         Backup() output

    WINPKGS_STATE_DIR overrides the parent (tests): <dir>\<kind>.

    Before the split there was one tree per *scope* -- user state directly in
    %LOCALAPPDATA%\winpkgs, machine state directly in %ProgramData%\winpkgs, and
    a counter shared between them. Those move into home\ and system\ the first
    time they are touched with enough rights to do so.
#>

function Get-WinPkgsStateDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)

    if ($env:WINPKGS_STATE_DIR) { return (Join-Path $env:WINPKGS_STATE_DIR $Kind) }
    $parent = if ($Kind -eq 'system') { Join-Path $env:ProgramData 'winpkgs' } else { Join-Path $env:LOCALAPPDATA 'winpkgs' }
    $dir = Join-Path $parent $Kind
    if (Move-WinPkgsLegacyState -From $parent -Into $dir -Kind $Kind) { return $dir }
    # Legacy state that could not be moved yet (system state, unelevated): read
    # it where it is, so `winpkgs system generations` still tells the truth.
    return $parent
}

function Move-WinPkgsLegacyState {
    # Pre-split layout -> per-kind directory. Returns whether $Into is now the
    # place to look: true when there was nothing to move or the move succeeded,
    # false when legacy state exists and could not be moved (no rights).
    param([string]$From, [string]$Into, [string]$Kind)
    $legacy = @('state.json', 'generations') | Where-Object { Test-Path -LiteralPath (Join-Path $From $_) }
    if ($legacy.Count -eq 0) { return $true }
    if ((Test-Path -LiteralPath (Join-Path $Into 'state.json')) -or (Test-Path -LiteralPath (Join-Path $Into 'generations'))) { return $true }
    try {
        New-Item -ItemType Directory -Force -Path $Into | Out-Null
        foreach ($item in $legacy) {
            Move-Item -LiteralPath (Join-Path $From $item) -Destination (Join-Path $Into $item) -Force
        }
        # The shared counter is gone; each kind numbers its own generations.
        $counter = Join-Path $From 'generation'
        if (Test-Path -LiteralPath $counter) { Remove-Item -LiteralPath $counter -Force }
        Write-Host "[$Kind] moved pre-split state from $From into $Into"
        return $true
    } catch {
        Write-Verbose "Could not migrate state from $From yet: $($_.Exception.Message)"
        return $false
    }
}

function Protect-WinPkgsStateDir {
    <#
    .SYNOPSIS
        Make a state directory writable by administrators only.

    .DESCRIPTION
        The system state is trusted by elevated processes -- the ledger decides
        what a prune deletes -- and %ProgramData% lets every user create files
        and directories anywhere beneath it, and own what they create. So the
        system state directory gets a protected ACL of its own: SYSTEM and
        Administrators full control, Users read and execute, inherited by
        everything below. A directory whose ACL is already protected is left as
        it is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    if ((Get-Acl -LiteralPath $Path).AreAccessRulesProtected) { return }
    # A fresh object rather than the directory's own: Set-Acl then writes the
    # DACL alone, not the owner it would otherwise carry along.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $grants = @(
        @('S-1-5-18', 'FullControl'),       # SYSTEM
        @('S-1-5-32-544', 'FullControl'),   # Administrators
        @('S-1-5-32-545', 'ReadAndExecute') # Users
    )
    foreach ($g in $grants) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier $g[0]
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule $sid, $g[1], $inherit, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Read-WinPkgsState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)

    $file = Join-Path (Get-WinPkgsStateDir -Kind $Kind) 'state.json'
    $state = @{}
    if (Test-Path -LiteralPath $file) {
        $state = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    }
    if (-not $state.ContainsKey('owned')) { $state['owned'] = @{} }
    foreach ($backend in 'winget', 'files', 'services') {
        if (-not $state['owned'].ContainsKey($backend)) { $state['owned'][$backend] = @() }
        $state['owned'][$backend] = @($state['owned'][$backend])
    }
    # Fonts are keyed: resource name -> the file names it installed.
    if (-not ($state['owned']['fonts'] -is [hashtable])) { $state['owned']['fonts'] = @{} }
    # Not ownership: activation name -> the revision it last ran at.
    if (-not ($state['activations'] -is [hashtable])) { $state['activations'] = @{} }
    return $state
}

function Save-WinPkgsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$State
    )
    $dir = Get-WinPkgsStateDir -Kind $Kind
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
    # One sequence per kind, like NixOS system generations and home-manager's:
    # one more than the highest recorded.
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)
    $root = Join-Path (Get-WinPkgsStateDir -Kind $Kind) 'generations'
    $max = 0
    if (Test-Path -LiteralPath $root) {
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
            $v = 0
            if ([int]::TryParse($d.Name, [ref]$v) -and $v -gt $max) { $max = $v }
        }
    }
    return $max + 1
}

function New-WinPkgsGeneration {
    <#
    .SYNOPSIS
        Create the directory for a new generation of a kind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$Label = 'apply'
    )
    $number = Get-WinPkgsNextGeneration -Kind $Kind
    $dir = Join-Path (Get-WinPkgsStateDir -Kind $Kind) ('generations\{0:D3}' -f $number)
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'files') | Out-Null
    if (Test-Path -LiteralPath $ConfigPath) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $dir 'config.json') -Force
    }

    return @{
        number  = $number
        dir     = $dir
        label   = $Label
        started = (Get-Date).ToString('o')
        entries = [System.Collections.Generic.List[object]]::new()
    }
}

function Save-WinPkgsJournal {
    param([Parameter(Mandatory)][hashtable]$Generation)
    @{
        number  = $Generation.number
        label   = $Generation.label
        started = $Generation.started
        entries = @($Generation.entries)
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Generation.dir 'journal.json') -Encoding utf8
}

function Get-WinPkgsGeneration {
    <#
    .SYNOPSIS
        List recorded generations, oldest first, for one kind or both.
    #>
    [CmdletBinding()]
    param([ValidateSet('system', 'home')][string[]]$Kind = @('system', 'home'))

    $all = foreach ($k in $Kind) {
        $root = Join-Path (Get-WinPkgsStateDir -Kind $k) 'generations'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
            $journalPath = Join-Path $d.FullName 'journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { continue }
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
            $label = if ($journal.ContainsKey('label')) { $journal['label'] } else { $journal['kind'] }  # pre-split journals
            [pscustomobject]@{
                Kind       = $k
                Generation = [int]$journal['number']
                Action     = $label
                Started    = $journal['started']
                Changes    = @($journal['entries']).Count
                Path       = $d.FullName
            }
        }
    }
    $all | Sort-Object Kind, Generation
}
