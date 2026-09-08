<#
    winpkgs/file - a file or directory copied from the closure to the machine.
    Compared by SHA-256 so unchanged content is never rewritten.

    properties: target (may contain %VAR% or a leading ~), source (relative to the document)
#>

function Resolve-WinPkgsFileTarget {
    param([Parameter(Mandatory)][string]$Target)
    $expanded = [Environment]::ExpandEnvironmentVariables($Target)
    if ($expanded.StartsWith('~')) { $expanded = $env:USERPROFILE + $expanded.Substring(1) }
    return $expanded
}

function Get-WinPkgsFileHashes {
    # Relative path -> SHA-256. A single file is keyed by ''.
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
    $want = Get-WinPkgsFileHashes -Path $source
    $have = $Current['hashes']
    if ($want.Count -ne $have.Count) { return $false }
    foreach ($k in $want.Keys) {
        if (-not $have.ContainsKey($k) -or $have[$k] -ne $want[$k]) { return $false }
    }
    return $true
}

function Copy-WinPkgsFileTree {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Clear-WinPkgsReadOnly -Path $Destination
}

function Set-WinPkgsFile {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $target = Resolve-WinPkgsFileTarget -Target $Properties['target']
    $source = Join-Path $Context['Root'] $Properties['source']
    Copy-WinPkgsFileTree -Source $source -Destination $target
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
        Copy-WinPkgsFileTree -Source $Before['backup'] -Destination $target
        return
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
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
