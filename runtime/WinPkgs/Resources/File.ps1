<#
    winpkgs/file - a file or directory copied from the closure to the machine.
    Compared by SHA-256 so unchanged content is never rewritten.

    properties: target (may contain %VAR% or a leading ~), source (relative to the document)

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
    $source = Join-Path $Context['Root'] $Properties['source']
    Copy-WinPkgsFileTree -Source $source -Destination $target -Substitutions $Context['Substitutions'] -Trash (Get-WinPkgsFileTrash -Context $Context)
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

function Restore-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    if ($Before['exists']) {
        if (-not $Before['backup']) { throw "No backup recorded for $target; cannot restore" }
        # A backup is what was on the machine: already substituted, copied back as is.
        Copy-WinPkgsFileTree -Source $Before['backup'] -Destination $target -Trash (Get-WinPkgsFileTrash -Context $Context)
        if ($Before['owned']) { Add-WinPkgsOwned -Context $Context -Backend files -Id $Properties['target'] }
        return
    }
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
    -Restore 'Restore-WinPkgsFile' `
    -Backup 'Backup-WinPkgsFile' `
    -Describe 'Format-WinPkgsFileChange'
