<#
    winpkgs/file - a file or directory copied from the closure to the machine.
    Compared by SHA-256 so unchanged content is never rewritten.

    properties: target (may contain %VAR% or a leading ~), source (relative to the document),
                merge (optional; see below)

    properties.merge: the file is also written by the program it configures,
    and part of what that program writes must survive. The declared file is
    combined with what is on the machine rather than replacing it, and
    compared by its JSON content rather than its bytes, since the program
    rewrites it in its own formatting. A single JSON file only. One kind
    exists: 'windows-terminal' (Merge-WinPkgsTerminalSettings).

    Context.Substitutions (from the document's settings.substitutions, resolved
    by Resolve-WinPkgsSubstitutions): literal text replaced inside text files as
    they are written, for values only the machine knows -- home-manager's
    /home/<user> becomes the real profile directory. Comparison uses the
    substituted content, so idempotence is unaffected. Binary files are copied
    as they are.

    Context.Kind: a file in the way that is in use -- a running program being
    upgraded -- is moved into that kind's trash rather than failing the apply
    (Private/Trash.ps1).
#>

function Resolve-WinPkgsFileTarget {
    param([Parameter(Mandatory)][string]$Target)
    $expanded = [Environment]::ExpandEnvironmentVariables($Target)
    if ($expanded.StartsWith('~')) { $expanded = $env:USERPROFILE + $expanded.Substring(1) }
    return $expanded
}

function Get-WinPkgsDesiredBytes {
    # What a source file should contain on the machine: its bytes as in the
    # closure, unless it is a text file mentioning something to substitute.
    param([Parameter(Mandatory)][string]$Path, [array]$Substitutions)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $unchanged = @{ bytes = $bytes; changed = $false }
    if (-not $Substitutions -or $Substitutions.Count -eq 0 -or $bytes.Length -eq 0) { return $unchanged }
    # A NUL in the first 8 KiB means binary.
    $probe = [Math]::Min($bytes.Length, 8192)
    for ($i = 0; $i -lt $probe; $i++) { if ($bytes[$i] -eq 0) { return $unchanged } }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)   # no BOM added; a present BOM survives the round trip
    try { $text = $utf8.GetString($bytes) } catch { return $unchanged }
    $changed = $false
    foreach ($s in $Substitutions) {
        $from = [string]$s['from']
        if ($from -and $text.Contains($from)) {
            $text = $text.Replace($from, [string]$s['to'])
            $changed = $true
        }
    }
    if (-not $changed) { return $unchanged }
    return @{ bytes = $utf8.GetBytes($text); changed = $true }
}

function Get-WinPkgsBytesHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-WinPkgsFileHashes {
    # Relative path -> SHA-256 of what is on disk. A single file is keyed by ''.
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $result = @{}
    if ($item.PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $Path -File -Recurse -Force) {
            $rel = $f.FullName.Substring($item.FullName.Length).TrimStart('\', '/')
            $result[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        }
    } else {
        $result[''] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $result
}

function Get-WinPkgsSourceHashes {
    # Relative path -> SHA-256 of what the machine *should* have: the closure's
    # content after substitution.
    param([Parameter(Mandatory)][string]$Path, [array]$Substitutions)
    $item = Get-Item -LiteralPath $Path -Force
    $result = @{}
    if ($item.PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $Path -File -Recurse -Force) {
            $rel = $f.FullName.Substring($item.FullName.Length).TrimStart('\', '/')
            $result[$rel] = Get-WinPkgsBytesHash -Bytes (Get-WinPkgsDesiredBytes -Path $f.FullName -Substitutions $Substitutions).bytes
        }
    } else {
        $result[''] = Get-WinPkgsBytesHash -Bytes (Get-WinPkgsDesiredBytes -Path $Path -Substitutions $Substitutions).bytes
    }
    return $result
}

function Clear-WinPkgsReadOnly {
    # Files copied out of the Nix store arrive read-only; applications expect to edit their own config.
    param([Parameter(Mandatory)][string]$Path)
    $items = @(Get-Item -LiteralPath $Path -Force)
    $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($i in $items) {
        if ($i.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $i.Attributes = $i.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
}

function Test-WinPkgsJsonEqual {
    # Two parsed JSON values alike: objects whatever their key order, arrays in
    # order, numbers by value whichever host parsed them.
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A) -and ($null -eq $B) }
    if ($A -is [System.Collections.IDictionary]) {
        if ($B -isnot [System.Collections.IDictionary] -or $A.Count -ne $B.Count) { return $false }
        foreach ($k in $A.Keys) {
            if (-not $B.Contains($k) -or -not (Test-WinPkgsJsonEqual $A[$k] $B[$k])) { return $false }
        }
        return $true
    }
    if ($A -is [array]) {
        if ($B -isnot [array] -or $A.Count -ne $B.Count) { return $false }
        for ($i = 0; $i -lt $A.Count; $i++) {
            if (-not (Test-WinPkgsJsonEqual $A[$i] $B[$i])) { return $false }
        }
        return $true
    }
    if ($A -is [string] -or $B -is [string]) { return ($A -is [string]) -and ($B -is [string]) -and ($A -ceq $B) }
    if ($A -is [bool] -or $B -is [bool]) { return ($A -is [bool]) -and ($B -is [bool]) -and ($A -eq $B) }
    return ([double]$A) -eq ([double]$B)
}

function ConvertTo-WinPkgsSortedJson {
    # A parsed JSON value with every object's keys in ordinal order, for
    # ConvertTo-Json: the same text from every run, where a hashtable's order
    # is not. Terminal writes its own file sorted the same way.
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $o = [ordered]@{}
        foreach ($k in $keys) { $o[$k] = ConvertTo-WinPkgsSortedJson $Value[$k] }
        return $o
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { , (ConvertTo-WinPkgsSortedJson $item) })
        return , $items
    }
    return $Value
}

<#
    Windows Terminal adds an entry to settings.json's profiles.list for each
    profile it generates -- Windows PowerShell, Command Prompt, PowerShell 7,
    every WSL distro, Azure Cloud Shell -- and records its GUID in state.json,
    beside settings.json (generatedProfiles). A recorded profile missing from
    settings.json is one the user deleted, so Terminal hides it, and with
    every profile hidden it refuses the file. So an entry on the machine for a
    recorded profile the configuration does not declare is Terminal's, and is
    written back after the declared ones. A profile the configuration declares
    -- by guid, or by name when the declaration has no guid -- is the
    configuration's; a profile made in Terminal's UI was never generated. The
    rest of the file is the configuration's, as with any file.
#>
function Get-WinPkgsTerminalProfileList {
    # The profile objects of a settings document: profiles.list, or a bare
    # `profiles` array, which Terminal also reads.
    param($Settings)
    if ($Settings -isnot [System.Collections.IDictionary]) { return @() }
    $profiles = $Settings['profiles']
    $list = if ($profiles -is [System.Collections.IDictionary]) { $profiles['list'] } else { $profiles }
    return @(@($list) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

function ConvertTo-WinPkgsTerminalGuid {
    param($Value)
    if ($Value -isnot [string] -or -not $Value.Trim()) { return $null }
    return $Value.Trim().Trim('{', '}').ToLowerInvariant()
}

function Merge-WinPkgsTerminalSettings {
    # Adds the machine's entries for Terminal's generated profiles to the
    # declared settings, in place. Returns how many it added.
    param([hashtable]$Settings, $Machine, [string]$Target)
    $recorded = @{}
    $statePath = Join-Path (Split-Path -Parent $Target) 'state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $state = ConvertFrom-WinPkgsJson ([IO.File]::ReadAllText($statePath)) } catch { $state = $null }
        if ($state -is [System.Collections.IDictionary]) {
            foreach ($g in @($state['generatedProfiles'])) {
                $id = ConvertTo-WinPkgsTerminalGuid $g
                if ($id) { $recorded[$id] = $true }
            }
        }
    }

    $declared = @{}
    $names = @{}
    foreach ($p in Get-WinPkgsTerminalProfileList $Settings) {
        $id = ConvertTo-WinPkgsTerminalGuid $p['guid']
        if ($id) { $declared[$id] = $true } elseif ($p['name'] -is [string]) { $names[$p['name']] = $true }
    }

    $kept = @(foreach ($p in Get-WinPkgsTerminalProfileList $Machine) {
            $id = ConvertTo-WinPkgsTerminalGuid $p['guid']
            if (-not $id -or -not $recorded.ContainsKey($id) -or $declared.ContainsKey($id)) { continue }
            if ($p['name'] -is [string] -and $names.ContainsKey($p['name'])) { continue }
            $declared[$id] = $true   # once, should the machine's list repeat one
            $p
        })
    if ($kept.Count -eq 0) { return 0 }

    $profiles = $Settings['profiles']
    if ($profiles -is [array]) {
        $Settings['profiles'] = @($profiles) + $kept
    } else {
        if ($profiles -isnot [System.Collections.IDictionary]) {
            $profiles = @{}
            $Settings['profiles'] = $profiles
        }
        $list = if ($null -eq $profiles['list']) { @() } else { @($profiles['list']) }
        $profiles['list'] = $list + $kept
    }
    return $kept.Count
}

function Get-WinPkgsMergedFile {
    # What a merged file should hold, given what is on the machine now.
    # Returns the document (parsed), the machine's (parsed; $null when there
    # is none or it is not JSON) and the bytes to write: the declared file as
    # it is when nothing of the machine's is kept.
    param([hashtable]$Properties, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    $source = Join-Path $Context['Root'] $Properties['source']
    if (-not (Test-Path -LiteralPath $source)) { throw "Source missing from closure: $source" }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "merge '$($Properties['merge'])' needs a single file; $source is a directory" }

    $desired = Get-WinPkgsDesiredBytes -Path $source -Substitutions $Context['Substitutions']
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($desired.bytes).TrimStart([char]0xFEFF)
    $document = ConvertFrom-WinPkgsJson $text
    if ($document -isnot [hashtable]) { throw "merge '$($Properties['merge'])' needs a JSON object; $source is not one" }

    $machine = $null
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        # Unreadable as JSON (a hand edit with comments, say): nothing on the
        # machine to keep, and the declared file replaces it.
        try { $machine = ConvertFrom-WinPkgsJson ([IO.File]::ReadAllText($target)) } catch { $machine = $null }
    }

    $kept = switch ($Properties['merge']) {
        'windows-terminal' { Merge-WinPkgsTerminalSettings -Settings $document -Machine $machine -Target $target }
        default { throw "Unknown merge '$($Properties['merge'])' for $target" }
    }
    $bytes = $desired.bytes
    if ($kept -gt 0) {
        $json = ConvertTo-Json (ConvertTo-WinPkgsSortedJson $document) -Depth 100
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json + "`n")
    }
    return @{ document = $document; machine = $machine; bytes = $bytes }
}

function Get-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    if (-not (Test-Path -LiteralPath $target)) { return @{ exists = $false; target = $target } }
    $item = Get-Item -LiteralPath $target -Force
    return @{
        exists      = $true
        target      = $target
        isDirectory = [bool]$item.PSIsContainer
        hashes      = Get-WinPkgsFileHashes -Path $target
    }
}

function Test-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    if ($Properties['merge']) {
        $merged = Get-WinPkgsMergedFile -Properties $Properties -Context $Context
        return Test-WinPkgsJsonEqual $merged.document $merged.machine
    }
    $source = Join-Path $Context['Root'] $Properties['source']
    if (-not (Test-Path -LiteralPath $source)) { throw "Source missing from closure: $source" }
    $want = Get-WinPkgsSourceHashes -Path $source -Substitutions $Context['Substitutions']
    $have = $Current['hashes']
    if ($want.Count -ne $have.Count) { return $false }
    foreach ($k in $want.Keys) {
        if (-not $have.ContainsKey($k) -or $have[$k] -ne $want[$k]) { return $false }
    }
    return $true
}

function Get-WinPkgsFileTrash {
    # Where files in use go, when the caller says whose apply this is.
    param([hashtable]$Context)
    if ($Context -and $Context['Kind']) { return Get-WinPkgsTrashDir -Kind $Context['Kind'] }
    return $null
}

function Copy-WinPkgsFileTree {
    param([string]$Source, [string]$Destination, [array]$Substitutions, [string]$Trash)
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Remove-WinPkgsPath -Path $Destination -Trash $Trash
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Clear-WinPkgsReadOnly -Path $Destination
    if (-not $Substitutions -or $Substitutions.Count -eq 0) { return }
    # Rewrite the copies whose content the substitutions touch.
    $src = Get-Item -LiteralPath $Source -Force
    $pairs = if ($src.PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
            @{ from = $f.FullName; to = Join-Path $Destination ($f.FullName.Substring($src.FullName.Length).TrimStart('\', '/')) }
        }
    } else { @{ from = $Source; to = $Destination } }
    foreach ($p in @($pairs)) {
        $desired = Get-WinPkgsDesiredBytes -Path $p['from'] -Substitutions $Substitutions
        if ($desired.changed) { [IO.File]::WriteAllBytes($p['to'], $desired.bytes) }
    }
}

function Set-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    if ($Properties['merge']) {
        $merged = Get-WinPkgsMergedFile -Properties $Properties -Context $Context
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Remove-WinPkgsPath -Path $target -Trash (Get-WinPkgsFileTrash -Context $Context)
        [IO.File]::WriteAllBytes($target, $merged.bytes)
    } else {
        $source = Join-Path $Context['Root'] $Properties['source']
        Copy-WinPkgsFileTree -Source $source -Destination $target -Substitutions $Context['Substitutions'] -Trash (Get-WinPkgsFileTrash -Context $Context)
    }
    # Ownership is what prune acts on. A file that existed before winpkgs first
    # wrote it is managed but not owned: it is not deleted when it leaves the
    # configuration.
    if (-not $Current['exists']) { Add-WinPkgsOwned -Context $Context -Backend files -Id $Properties['target'] }
}

function Backup-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context, [string]$BackupDir)
    if (-not $Current['exists']) { return @{} }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $dest = Join-Path $BackupDir 'content'
    Copy-Item -LiteralPath $Current['target'] -Destination $dest -Recurse -Force
    return @{ backup = $dest }
}

function Remove-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    Remove-WinPkgsPath -Path $target -Trash (Get-WinPkgsFileTrash -Context $Context)
    Remove-WinPkgsOwned -Context $Context -Backend files -Id $Properties['target']
}

function Format-WinPkgsFileChange {
    # Describe does not know whether Test passed, so describe the state, not the diff.
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) { return 'absent -> present' }
    $n = @($Current['hashes'].Keys).Count
    if ($Current['isDirectory']) { return "directory, $n file(s)" }
    return 'present'
}

Register-WinPkgsResource -Type 'winpkgs/file' `
    -Get 'Get-WinPkgsFile' `
    -Test 'Test-WinPkgsFile' `
    -Set 'Set-WinPkgsFile' `
    -Remove 'Remove-WinPkgsFile' `
    -Backup 'Backup-WinPkgsFile' `
    -Describe 'Format-WinPkgsFileChange'
