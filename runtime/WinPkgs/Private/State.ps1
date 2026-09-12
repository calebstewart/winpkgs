<#
    State lives on the Windows side, one tree per kind of configuration:

      %ProgramData%\winpkgs\system\    the machine; written elevated, writable by administrators only
      %LOCALAPPDATA%\winpkgs\home\     this user
        state.json                     ledger: what winpkgs installed / created (winget ids, file targets, fonts -> files, services),
                                       the revision each activation last ran at, and `current`: the generation the kind is on
        generations\NNN\               one sequence per kind
          closure\                     the closure applied: config.json, runtime\, files\, fonts\ -- a file another
                                       generation keeps with the same content is a hard link to it
          manifest.json                every closure file's SHA-256, and the fingerprint they add up to
          journal.json                 what the apply that created the generation changed
          journal-K.json               what its K-th run changed: going back to it, applying it again over drift
          files\                       Backup() output (files\run-K\ for run K)

    Generations recorded before closures were kept have a config.json and no
    closure\: they are listed, and cannot be gone back to.

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

function Get-WinPkgsGenerationDir {
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Number
    )
    return Join-Path (Get-WinPkgsStateDir -Kind $Kind) ('generations\{0:D3}' -f $Number)
}

function Get-WinPkgsCurrentGeneration {
    # The generation a kind is on -- the one last switched to, as a profile
    # link names one. 0 until an apply has recorded one.
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)
    return [int](Read-WinPkgsState -Kind $Kind)['current']
}

function Set-WinPkgsCurrentGeneration {
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Number
    )
    $state = Read-WinPkgsState -Kind $Kind
    $state['current'] = $Number
    Save-WinPkgsState -Kind $Kind -State $state
}

# What of a closure the machine needs: the document -- kept as config.json,
# whatever it was called -- and beside it the runtime that understands it and
# the files and fonts it names. bin\activate and the wsl link are the WSL
# side's.
$script:ClosureDirs = @('runtime', 'files', 'fonts')

function Get-WinPkgsStreamHash {
    # SHA-256 of a file, read in large blocks. Get-FileHash reads a few KiB at a
    # time, which over \\wsl.localhost makes 230 MB of fonts a 16 s read rather
    # than a 2 s one.
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read), (1024 * 1024)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-WinPkgsClosureSources {
    # For the closure of the document at -Path: name in the closure -> where
    # the file is now, and the name of every directory, so that an empty one
    # -- a declared directory with nothing in it -- is kept too.
    param([Parameter(Mandatory)][string]$Path)
    $root = Split-Path -Parent $Path
    $files = @{ 'config.json' = $Path }
    $directories = @()
    foreach ($dir in $script:ClosureDirs) {
        $path = Join-Path $root $dir
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $base = (Get-Item -LiteralPath $path -Force).FullName.TrimEnd('\')
        $directories += $dir
        foreach ($item in Get-ChildItem -LiteralPath $path -Recurse -Force) {
            $name = $dir + $item.FullName.Substring($base.Length)
            if ($item.PSIsContainer) { $directories += $name } else { $files[$name] = $item.FullName }
        }
    }
    return @{ files = $files; directories = $directories }
}

function Get-WinPkgsClosureManifest {
    <#
    .SYNOPSIS
        Every file of the closure of the document at -Path with its SHA-256,
        its directories, and the fingerprint they add up to: what tells one
        configuration from another, as a store path does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sources = Get-WinPkgsClosureSources -Path $Path
    $files = @{}
    foreach ($name in $sources.files.Keys) { $files[$name] = Get-WinPkgsStreamHash -Path $sources.files[$name] }
    # Ordinal, so that neither the culture nor the order a directory happens to
    # be listed in changes the fingerprint.
    $lines = [string[]]@(
        @($files.Keys | ForEach-Object { "$($files[$_]) $_" }) +
        @($sources.directories | ForEach-Object { "directory $_" })
    )
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-', '') }
    finally { $sha.Dispose() }
    return @{ fingerprint = $fingerprint; files = $files; directories = @($sources.directories) }
}

function Get-WinPkgsGenerationManifest {
    # The manifest of the closure a generation keeps; $null for one recorded
    # before closures were kept.
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Number
    )
    $path = Join-Path (Get-WinPkgsGenerationDir -Kind $Kind -Number $Number) 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
}

function Read-WinPkgsGenerationDocument {
    # The document a generation keeps, rooted in its closure, so that its
    # sources are read from there.
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Number
    )
    return Read-WinPkgsDocument -Path (Join-Path (Get-WinPkgsGenerationDir -Kind $Kind -Number $Number) 'closure\config.json')
}

function Resolve-WinPkgsTargetGeneration {
    <#
    .SYNOPSIS
        Which generation applying a closure makes current.

    .DESCRIPTION
        With -Generation N, N itself, and the closure must be the one N keeps:
        that is how rollback applies a generation. Otherwise the current
        generation when the closure is the one it keeps -- the same
        configuration again, converging whatever drifted -- then the newest
        when it is that one's -- back to the configuration last built, after
        going back from it, which is Nix's own rule for a profile -- and for
        anything else a new generation, numbered after the newest.

        Returns @{ number; new; current }.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [int]$Generation = 0
    )
    $target = @{ number = 0; new = $false; current = (Get-WinPkgsCurrentGeneration -Kind $Kind) }
    if ($Generation -gt 0) {
        $kept = Get-WinPkgsGenerationManifest -Kind $Kind -Number $Generation
        if (-not $kept) { throw "No $Kind generation $Generation with a kept closure; see: winpkgs $Kind generations" }
        if ($kept['fingerprint'] -ne $Manifest['fingerprint']) {
            throw "This is not the closure $Kind generation $Generation keeps"
        }
        $target.number = $Generation
        return $target
    }
    $newest = (Get-WinPkgsNextGeneration -Kind $Kind) - 1
    foreach ($candidate in @($target.current, $newest)) {
        if ($candidate -lt 1) { continue }
        $kept = Get-WinPkgsGenerationManifest -Kind $Kind -Number $candidate
        if ($kept -and $kept['fingerprint'] -eq $Manifest['fingerprint']) {
            $target.number = $candidate
            return $target
        }
    }
    $target.number = $newest + 1
    $target.new = $true
    return $target
}

function Get-WinPkgsKeptFiles {
    # SHA-256 -> a file with that content that some generation of the kind
    # keeps, the newest generation's first.
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)
    $index = @{}
    $root = Join-Path (Get-WinPkgsStateDir -Kind $Kind) 'generations'
    if (-not (Test-Path -LiteralPath $root)) { return $index }
    $numbered = foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
        $v = 0
        if ([int]::TryParse($d.Name, [ref]$v)) { @{ number = $v; dir = $d.FullName } }
    }
    foreach ($g in @($numbered | Sort-Object { $_.number } -Descending)) {
        $path = Join-Path $g.dir 'manifest.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $files = (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson)['files']
        foreach ($name in $files.Keys) {
            if (-not $index.ContainsKey($files[$name])) { $index[$files[$name]] = Join-Path $g.dir "closure\$name" }
        }
    }
    return $index
}

function New-WinPkgsGeneration {
    <#
    .SYNOPSIS
        Keep a closure as a new generation of a kind: its files under
        generations\NNN\closure, and its manifest.

    .DESCRIPTION
        A file that another generation keeps with the same content becomes a
        hard link to it rather than a copy, so a font that has not changed costs
        nothing per generation; NTFS hard links need no elevation. Where one
        cannot be made (the 1023-link limit, a file since deleted) the file is
        copied. The closure is assembled beside the generation's directory and
        renamed into it, so no generation ever holds part of one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        # The document whose closure it is.
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][int]$Number
    )
    $generations = Join-Path (Get-WinPkgsStateDir -Kind $Kind) 'generations'
    New-Item -ItemType Directory -Force -Path $generations | Out-Null
    # What an apply that died while keeping its closure left behind.
    foreach ($stale in @(Get-ChildItem -LiteralPath $generations -Directory -Filter '*.partial')) {
        Remove-Item -LiteralPath $stale.FullName -Recurse -Force
    }

    $dir = Get-WinPkgsGenerationDir -Kind $Kind -Number $Number
    $partial = "$dir.partial"
    $closure = Join-Path $partial 'closure'
    $kept = Get-WinPkgsKeptFiles -Kind $Kind
    $root = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($closure)
    foreach ($name in @($Manifest['directories'])) { [void][IO.Directory]::CreateDirectory((Join-Path $closure $name)) }
    Initialize-WinPkgsKernel32
    foreach ($name in $Manifest['files'].Keys) {
        $to = Join-Path $closure $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
        $same = $kept[$Manifest['files'][$name]]
        if ($same -and [WinPkgs.Native.Kernel32]::CreateHardLinkW($to, $same, [IntPtr]::Zero)) { continue }
        $from = if ($name -eq 'config.json') { $Path } else { Join-Path $root $name }
        [IO.File]::Copy($from, $to)
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $partial 'files') | Out-Null
    $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $partial 'manifest.json') -Encoding utf8
    [IO.Directory]::Move($partial, $dir)
    return $dir
}

function New-WinPkgsRun {
    <#
    .SYNOPSIS
        The record of one run of a generation: journal.json for the apply that
        created it, journal-K.json for its K-th run after that -- going back to
        it, or applying it again over drift -- each with its own backups.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Number,
        [string]$Label = 'apply'
    )
    $dir = Get-WinPkgsGenerationDir -Kind $Kind -Number $Number
    $k = 1
    $journal = Join-Path $dir 'journal.json'
    while (Test-Path -LiteralPath $journal) {
        $k++
        $journal = Join-Path $dir "journal-$k.json"
    }
    return @{
        number  = $Number
        label   = $Label
        started = (Get-Date).ToString('o')
        journal = $journal
        backups = if ($k -eq 1) { Join-Path $dir 'files' } else { Join-Path $dir "files\run-$k" }
        entries = [System.Collections.Generic.List[object]]::new()
    }
}

function Save-WinPkgsJournal {
    param([Parameter(Mandatory)][hashtable]$Run)
    @{
        number  = $Run.number
        label   = $Run.label
        started = $Run.started
        entries = @($Run.entries)
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Run.journal -Encoding utf8
}

function Get-WinPkgsGeneration {
    <#
    .SYNOPSIS
        List recorded generations, oldest first, for one kind or both, with the
        current one marked. Started and Changes are those of the apply that
        created each.
    #>
    [CmdletBinding()]
    param([ValidateSet('system', 'home')][string[]]$Kind = @('system', 'home'))

    $all = foreach ($k in $Kind) {
        $root = Join-Path (Get-WinPkgsStateDir -Kind $k) 'generations'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $current = Get-WinPkgsCurrentGeneration -Kind $k
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
            $journalPath = Join-Path $d.FullName 'journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { continue }
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
            $label = if ($journal.ContainsKey('label')) { $journal['label'] } else { $journal['kind'] }  # pre-split journals
            [pscustomobject]@{
                Kind       = $k
                Generation = [int]$journal['number']
                Current    = ([int]$journal['number'] -eq $current)
                Action     = $label
                Started    = $journal['started']
                Changes    = @($journal['entries']).Count
                Path       = $d.FullName
            }
        }
    }
    $all | Sort-Object Kind, Generation
}
