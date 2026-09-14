<#
    winpkgs/winget, offline: a package installed from the installer the media
    carries (winpkgs.installer.offline), without winget and without a network.

    `winpkgs.ps1 plan|apply -Installers <dir>` hands the resource the
    directory holding installers.json: the phase's installer records (what
    lib/installer.nix's offlinePlan wrote), each with its file, the ids in the
    same phase it requires first, and the order they all go in. Given one,
    Get, Test and Set work from it and never load the WinGet client; without
    one, nothing here runs.

    What is installed is found the way winget finds it, so that the first
    apply with a network hands the packages to winget as though it had
    installed them itself:

      - an installer that registers in Add/Remove Programs, by the key its
        manifest names (ProductCode -- Inno's is `{AppId}_is1`, an MSI's its
        GUID), else by its AppsAndFeaturesEntries (product code, upgrade code
        through the MSI upgrade-code table, display name and publisher), else
        by the keys the install itself added, noted in the ledger when it ran
        (winget's own ARP correlation);
      - a portable, bare or in a zip, by the key winget writes for one, which
        this writes the same way, with the same layout and the same index;
      - an MSIX, by its package family name.

    Installers run with winget's switches for their type, the manifest's
    Silent (else winget's default for the type) and Custom, as one command line
    (Invoke-WinPkgsCommandLine). Their exit code is read against the record's
    InstallerSuccessCodes and ExpectedReturnCodes: 3010 and 1641, or a code the
    manifest calls rebootRequiredToFinish, succeed and ask for a restart;
    alreadyInstalled succeeds; anything else fails with the manifest's word for
    it. A package's same-phase requirements are installed first, in the
    sidecar's order, when absent or below the minimum; Windows features it
    needs are enabled, from an elevated apply; Windows libraries it needs are
    reported when missing, since the media does not carry them.

    The ledger is `owned.winget`, as online. Uninstalling, and downgrading to a
    pin, stay winget's: offline media installs a fresh machine, and anything
    removed later is removed with a network.

    Test hooks, all optional: WINPKGS_UNINSTALL_ROOT is a registry key standing
    in for the Add/Remove Programs roots (HKLM, HKLM32 and HKCU beneath it) and
    the MSI upgrade-code tables (UpgradeCodes\HKLM and \HKCU); WINPKGS_MSIEXEC
    names a script run instead of msiexec.exe; WINPKGS_APPX_STATE names a JSON
    file of package family name -> version standing in for the machine's
    packages, and WINPKGS_APPX_LOG records every add; WINPKGS_PORTABLE_ROOT is
    a directory standing in for WinGet's (user\ and machine\ beneath it, each
    with Packages\ and Links\); WINPKGS_PORTABLE_PATH_KEY redirects the PATH
    the Links directory goes on; WINPKGS_PORTABLE_NO_LINKS makes every link
    fail, as it does without the privilege to create one.
#>

$script:WinGetSourceIdentifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'

# winget's silent switches where a manifest names none (GetDefaultKnownSwitches).
$script:WinGetDefaultSilent = @{
    msi      = '/quiet /norestart'
    wix      = '/quiet /norestart'
    burn     = '/quiet /norestart'
    inno     = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    nullsoft = '/S'
}

#region the sidecar

function Read-WinPkgsInstallers {
    <#
    .SYNOPSIS
        One phase of a media's installers.json: its records by id, their
        order, and the directory their files are relative to.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind
    )
    $file = Join-Path $Path 'installers.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "-Installers names the directory the media's installers.json is in, and $Path has none"
    }
    $sidecar = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    if ($sidecar['version'] -ne 1) {
        throw "$file is version '$($sidecar['version'])' and this runtime reads version 1; rebuild the media with a matching winpkgs"
    }
    $phase = $sidecar[$Kind]
    $installers = @{}
    $order = @()
    if ($phase) {
        if ($phase['installers']) { $installers = $phase['installers'] }
        $order = @($phase['order'])
    }
    return @{
        root       = (Resolve-Path -LiteralPath $Path).ProviderPath
        kind       = $Kind
        order      = $order
        installers = $installers
    }
}

function Get-WinPkgsCarriedRecord {
    param([Parameter(Mandatory)][hashtable]$Installers, [Parameter(Mandatory)][string]$Id)
    $record = $Installers['installers'][$Id]
    if (-not $record) {
        throw "$Id is not among the installers the media carries for the $($Installers['kind']) configuration ($(Join-Path $Installers['root'] 'installers.json')); rebuild the media from this configuration"
    }
    return $record
}

function Get-WinPkgsInstallerType {
    # The type that decides how a record installs: a zip's is what it holds.
    param([Parameter(Mandatory)][hashtable]$Record)
    if ($Record['type'] -eq 'zip') { return [string]$Record['nestedType'] }
    return [string]$Record['type']
}

#endregion

#region Add/Remove Programs

function Get-WinPkgsUninstallRoots {
    # Where installers register, with the scope each stands for.
    if ($env:WINPKGS_UNINSTALL_ROOT) {
        $base = $env:WINPKGS_UNINSTALL_ROOT
        return @(
            @{ key = "$base\HKLM"; scope = 'machine' }
            @{ key = "$base\HKLM32"; scope = 'machine' }
            @{ key = "$base\HKCU"; scope = 'user' }
        )
    }
    return @(
        @{ key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'machine' }
        @{ key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'machine' }
        @{ key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'user' }
    )
}

function Get-WinPkgsArpEntries {
    <#
    .SYNOPSIS
        Every Add/Remove Programs entry: its key, the key's name, and the
        values an entry is recognised by.
    #>
    $entries = New-Object Collections.Generic.List[hashtable]
    foreach ($root in Get-WinPkgsUninstallRoots) {
        $path = ConvertTo-WinPkgsRegistryPath -Key $root.key
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue) {
            $entries.Add(@{
                    key            = "$($root.key)\$($k.PSChildName)"
                    name           = $k.PSChildName
                    scope          = $root.scope
                    displayName    = [string]$k.GetValue('DisplayName')
                    displayVersion = [string]$k.GetValue('DisplayVersion')
                    publisher      = [string]$k.GetValue('Publisher')
                })
        }
    }
    return , $entries.ToArray()
}

function ConvertTo-WinPkgsPackedGuid {
    # The MSI registry's spelling of a GUID and back again, which is the same
    # operation: the first three groups reversed character by character, the
    # remaining sixteen characters pairwise.
    param([Parameter(Mandatory)][string]$Guid)
    $hex = ($Guid -replace '[{}-]', '').ToUpperInvariant()
    if ($hex.Length -ne 32) { return $null }
    $reverse = { param($s) $c = $s.ToCharArray(); [array]::Reverse($c); -join $c }
    $out = (& $reverse $hex.Substring(0, 8)) + (& $reverse $hex.Substring(8, 4)) + (& $reverse $hex.Substring(12, 4))
    # Substrings, not $hex[$i]: [char] + [char] is arithmetic in PowerShell.
    for ($i = 16; $i -lt 32; $i += 2) { $out += $hex.Substring($i + 1, 1) + $hex.Substring($i, 1) }
    return $out
}

function ConvertFrom-WinPkgsPackedGuid {
    param([Parameter(Mandatory)][string]$Packed)
    $hex = ConvertTo-WinPkgsPackedGuid -Guid $Packed
    if (-not $hex) { return $null }
    return '{' + $hex.Substring(0, 8) + '-' + $hex.Substring(8, 4) + '-' + $hex.Substring(12, 4) + '-' + $hex.Substring(16, 4) + '-' + $hex.Substring(20, 12) + '}'
}

function Get-WinPkgsUpgradeCodeProducts {
    # The product codes the MSI registry lists under an upgrade code.
    param([Parameter(Mandatory)][string]$UpgradeCode)
    $packed = ConvertTo-WinPkgsPackedGuid -Guid $UpgradeCode
    if (-not $packed) { return @() }
    $tables = if ($env:WINPKGS_UNINSTALL_ROOT) {
        @("$env:WINPKGS_UNINSTALL_ROOT\UpgradeCodes\HKLM", "$env:WINPKGS_UNINSTALL_ROOT\UpgradeCodes\HKCU")
    } else {
        @('HKLM\SOFTWARE\Classes\Installer\UpgradeCodes', 'HKCU\Software\Microsoft\Installer\UpgradeCodes')
    }
    $products = @()
    foreach ($table in $tables) {
        $path = ConvertTo-WinPkgsRegistryPath -Key "$table\$packed"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($name in (Get-Item -LiteralPath $path).GetValueNames()) {
            if ($name) { $products += ConvertFrom-WinPkgsPackedGuid -Packed $name }
        }
    }
    return $products
}

function Find-WinPkgsArpEntry {
    <#
    .SYNOPSIS
        The Add/Remove Programs entry a record's install made, or $null: by
        product code, then by each AppsAndFeaturesEntry, then by the keys the
        install itself added.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [object[]]$Entries,
        [string[]]$Recorded = @()
    )
    if ($null -eq $Entries) { $Entries = Get-WinPkgsArpEntries }
    $byName = { param($n) if (-not $n) { return $null }; $Entries | Where-Object { $_.name -eq $n } | Select-Object -First 1 }

    $hit = & $byName ([string]$Record['productCode'])
    if ($hit) { return $hit }
    foreach ($a in @($Record['appsAndFeaturesEntries'])) {
        if (-not $a) { continue }
        $hit = & $byName ([string]$a['productCode'])
        if ($hit) { return $hit }
        if ($a['upgradeCode']) {
            foreach ($product in Get-WinPkgsUpgradeCodeProducts -UpgradeCode ([string]$a['upgradeCode'])) {
                $hit = & $byName $product
                if ($hit) { return $hit }
            }
        }
        if ($a['displayName']) {
            $hit = $Entries | Where-Object {
                $_.displayName -eq [string]$a['displayName'] -and (-not $a['publisher'] -or $_.publisher -eq [string]$a['publisher'])
            } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }
    foreach ($key in $Recorded) {
        $hit = $Entries | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-WinPkgsRecordedArpKeys {
    # What an earlier offline install of the package added to Add/Remove
    # Programs, as the ledger noted it.
    param([Parameter(Mandatory)][string]$Id, [hashtable]$Context)
    if (-not $Context) { return @() }
    $state = if ($Context['State']) { $Context['State'] } elseif ($Context['Kind']) { Read-WinPkgsState -Kind $Context['Kind'] } else { $null }
    if (-not $state) { return @() }
    if (-not $state['arp'] -or -not $state['arp'].ContainsKey($Id)) { return @() }
    return @($state['arp'][$Id])
}

#endregion

#region MSIX

function Get-WinPkgsAppxVersion {
    # The installed version of a package family, for the user or provisioned
    # for the machine, or $null.
    param([Parameter(Mandatory)][string]$FamilyName, [Parameter(Mandatory)][string]$Scope)
    if ($env:WINPKGS_APPX_STATE) {
        if (-not (Test-Path -LiteralPath $env:WINPKGS_APPX_STATE)) { return $null }
        $known = Get-Content -LiteralPath $env:WINPKGS_APPX_STATE -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
        if ($known.ContainsKey($FamilyName)) { return [string]$known[$FamilyName] }
        return $null
    }
    if ($Scope -eq 'machine') {
        $name = $FamilyName -replace '_[^_]+$', ''
        $p = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1
        if ($p) { return [string]$p.Version }
        return $null
    }
    $p = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $FamilyName } | Select-Object -First 1
    if ($p) { return [string]$p.Version }
    return $null
}

function Install-WinPkgsAppx {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][hashtable]$Record, [Parameter(Mandatory)][string]$Scope)
    if ($env:WINPKGS_APPX_STATE) {
        if ($env:WINPKGS_APPX_LOG) { Add-Content -LiteralPath $env:WINPKGS_APPX_LOG -Value "add $Scope $File" }
        $known = @{}
        if (Test-Path -LiteralPath $env:WINPKGS_APPX_STATE) {
            $known = Get-Content -LiteralPath $env:WINPKGS_APPX_STATE -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
        }
        $known[[string]$Record['packageFamilyName']] = [string]$Record['version']
        $known | ConvertTo-Json | Set-Content -LiteralPath $env:WINPKGS_APPX_STATE -Encoding utf8
        return
    }
    if ($Scope -eq 'machine') {
        # Provisioned: every account gets it at its next sign-in, the way
        # winget installs an MSIX for the machine.
        Add-AppxProvisionedPackage -Online -PackagePath $File -SkipLicense -ErrorAction Stop | Out-Null
    } else {
        Add-AppxPackage -Path $File -ErrorAction Stop
    }
}

#endregion

#region portables, the way winget lays them out

function Get-WinPkgsPortableRoots {
    param([Parameter(Mandatory)][ValidateSet('machine', 'user')][string]$Scope)
    if ($env:WINPKGS_PORTABLE_ROOT) {
        $base = Join-Path $env:WINPKGS_PORTABLE_ROOT $Scope
    } elseif ($Scope -eq 'machine') {
        $base = Join-Path $env:ProgramFiles 'WinGet'
    } else {
        $base = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'
    }
    $pathKey = if ($env:WINPKGS_PORTABLE_PATH_KEY) { $env:WINPKGS_PORTABLE_PATH_KEY }
    elseif ($Scope -eq 'machine') { 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
    else { 'HKCU\Environment' }
    $arp = @(Get-WinPkgsUninstallRoots | Where-Object { $_.scope -eq $Scope })[0].key
    return @{
        packages = Join-Path $base 'Packages'
        links    = Join-Path $base 'Links'
        pathKey  = $pathKey
        arp      = $arp
    }
}

function Get-WinPkgsPortableKey {
    # The Add/Remove Programs key, and the install directory, winget names a
    # portable by.
    param([Parameter(Mandatory)][string]$Id)
    return "${Id}_$script:WinGetSourceIdentifier"
}

function Add-WinPkgsPathEntry {
    # A directory on a PATH value, if it is not there already.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Key)
    $props = @{ dir = $Dir; key = $Key; name = 'Path' }
    $current = Get-WinPkgsPath -Properties $props -Context @{}
    if (-not (Test-WinPkgsPath -Properties $props -Current $current -Context @{})) {
        Set-WinPkgsPath -Properties $props -Current $current -Context @{}
    }
}

function Write-WinPkgsPortableIndex {
    <#
    .SYNOPSIS
        The index winget keeps beside a portable package, <key>.db in its
        install directory: every top-level file (with its SHA-256) and
        directory, and every link, which is what winget reads to uninstall
        and upgrade it. Schema 1.0, as winget writes it.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Links = @()
    )
    Initialize-WinPkgsSqlite
    $db = Join-Path $Directory "$Key.db"
    if (Test-Path -LiteralPath $db) { Remove-Item -LiteralPath $db -Force }

    $statements = New-Object Collections.Generic.List[string]
    $values = New-Object Collections.Generic.List[object[]]
    $statements.Add("CREATE TABLE [metadata](`n    [name] TEXT PRIMARY KEY NOT NULL,`n    [value] TEXT NOT NULL) WITHOUT ROWID"); $values.Add($null)
    $statements.Add('CREATE TABLE [portable]([filepath] TEXT NOT NULL UNIQUE COLLATE NOCASE, [filetype] INT64 NOT NULL, [sha256] BLOB, [symlinktarget] TEXT)'); $values.Add($null)
    $metadata = [ordered]@{
        databaseIdentifier = [guid]::NewGuid().ToString('B').ToUpperInvariant()
        lastwritetime      = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        majorVersion       = '1'
        minorVersion       = '0'
    }
    foreach ($name in $metadata.Keys) {
        $statements.Add('INSERT INTO [metadata] ([name], [value]) VALUES (?, ?)')
        $values.Add([object[]]@($name, $metadata[$name]))
    }
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $_.Name -ne "$Key.db" } | Sort-Object Name) {
        $statements.Add('INSERT INTO [portable] ([filepath], [filetype], [sha256], [symlinktarget]) VALUES (?, ?, ?, ?)')
        if ($item.PSIsContainer) {
            $values.Add([object[]]@($item.FullName, [int64]2, $null, $null))
        } else {
            $sha = [Text.Encoding]::ASCII.GetBytes((Get-WinPkgsStreamHash -Path $item.FullName).ToLowerInvariant())
            $values.Add([object[]]@($item.FullName, [int64]1, $sha, $null))
        }
    }
    foreach ($l in $Links) {
        $statements.Add('INSERT INTO [portable] ([filepath], [filetype], [sha256], [symlinktarget]) VALUES (?, ?, ?, ?)')
        $values.Add([object[]]@([string]$l.link, [int64]3, $null, [string]$l.target))
    }
    [WinPkgs.Native.Sqlite]::Run($db, $statements.ToArray(), $values.ToArray())
}

function Install-WinPkgsPortable {
    <#
    .SYNOPSIS
        Place a portable package the way winget does -- files in
        WinGet\Packages\<id>_<source>, a link per command in WinGet\Links, the
        Links directory on PATH -- and register it the way winget does, so
        that winget finds it installed afterwards and can upgrade and
        uninstall it as its own.

    .DESCRIPTION
        A link needs Developer Mode or elevation. Where one cannot be made,
        the directory holding its target goes on PATH instead, and the entry
        says so (InstallDirectoryAddedToPath), which is winget's own fallback;
        a zip whose manifest says its programs depend on their directory
        (ArchiveBinariesDependOnPath) gets both.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][ValidateSet('machine', 'user')][string]$Scope
    )
    $id = [string]$Record['id']
    $roots = Get-WinPkgsPortableRoots -Scope $Scope
    $key = Get-WinPkgsPortableKey -Id $id
    $directory = Join-Path $roots.packages $key
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    # What each command is called, and what it runs. A target keeps the
    # manifest's relative path as written, forward slashes and all, which is
    # how winget records it.
    $commands = @()
    if ($Record['type'] -eq 'zip') {
        Expand-Archive -LiteralPath $File -DestinationPath $directory -Force
        foreach ($nested in @($Record['nestedFiles'])) {
            if (-not $nested) { continue }
            $relative = [string]$nested['relativeFilePath']
            $alias = if ($nested['portableCommandAlias']) { [string]$nested['portableCommandAlias'] } else { [IO.Path]::GetFileNameWithoutExtension($relative) }
            $commands += @{ alias = $alias; target = "$directory\$relative" }
        }
    } else {
        $alias = if (@($Record['commands']).Count -gt 0 -and $Record['commands'][0]) { [string]$Record['commands'][0] } else { [IO.Path]::GetFileNameWithoutExtension($File) }
        $name = $alias + [IO.Path]::GetExtension($File)
        Copy-Item -LiteralPath $File -Destination (Join-Path $directory $name) -Force
        $commands += @{ alias = $alias; target = "$directory\$name" }
    }

    $links = @()
    $onPath = @()
    New-Item -ItemType Directory -Force -Path $roots.links | Out-Null
    foreach ($c in $commands) {
        $target = $c.target -replace '/', '\'
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "$id carries no $($c.target), which its manifest names as the program behind '$($c.alias)'"
        }
        $link = Join-Path $roots.links ($c.alias + [IO.Path]::GetExtension($target))
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        # CreateSymbolicLinkW with SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
        # as winget makes them: with Developer Mode on, an unelevated process
        # may. Windows PowerShell's New-Item never passes the flag, so from the
        # unelevated home phase -- which setup runs under 5.1 -- it would
        # always fail.
        $made = $false
        if (-not $env:WINPKGS_PORTABLE_NO_LINKS) {
            Initialize-WinPkgsKernel32
            $made = [WinPkgs.Native.Kernel32]::CreateSymbolicLinkW($link, $target, 0x2)
            if (-not $made) {
                $reason = (New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error())).Message
                Write-Verbose "No link for $($c.alias): $reason"
            }
        }
        if ($made) { $links += @{ link = $link; target = $c.target } }
        if (-not $made -or $Record['archiveBinariesDependOnPath']) { $onPath += (Split-Path -Parent $target) }
    }
    if ($links.Count -gt 0) { Add-WinPkgsPathEntry -Dir $roots.links -Key $roots.pathKey }
    foreach ($dir in @($onPath | Select-Object -Unique)) { Add-WinPkgsPathEntry -Dir $dir -Key $roots.pathKey }

    Write-WinPkgsPortableIndex -Directory $directory -Key $key -Links $links

    # The name and publisher are the package's, from its locale manifest, as
    # winget writes them. They are not cosmetic: a portable has no product
    # code, and they are what winget recognises the install as the package by
    # (with the id instead of the name, `winget list` shows it only as an
    # Add/Remove Programs entry of no source).
    $arp = "$($roots.arp)\$key"
    $values = [ordered]@{
        WinGetPackageIdentifier = $id
        WinGetSourceIdentifier  = $script:WinGetSourceIdentifier
        UninstallString         = "winget uninstall --product-code $key"
        WinGetInstallerType     = 'portable'
        DisplayName             = $(if ($Record['name']) { [string]$Record['name'] } else { $id })
        DisplayVersion          = [string]$Record['version']
    }
    if ($Record['publisher']) { $values['Publisher'] = [string]$Record['publisher'] }
    $values['InstallDate'] = (Get-Date).ToString('yyyyMMdd')
    $values['InstallLocation'] = $directory
    foreach ($name in $values.Keys) { Write-WinPkgsRegistryValue -Key $arp -Name $name -Kind String -Value $values[$name] }
    Write-WinPkgsRegistryValue -Key $arp -Name 'InstallDirectoryCreated' -Kind DWord -Value 1
    if ($onPath.Count -gt 0) { Write-WinPkgsRegistryValue -Key $arp -Name 'InstallDirectoryAddedToPath' -Kind DWord -Value 1 }
}

#endregion

#region running an installer

function Get-WinPkgsInstallerSwitches {
    # The command line after the file: the manifest's silent switches, else
    # winget's for the type, then Custom.
    param([Parameter(Mandatory)][hashtable]$Record, [Parameter(Mandatory)][string]$Type)
    $switches = $Record['switches']
    if (-not $switches) { $switches = @{} }
    $silent = [string]$switches['silent']
    if (-not $silent -and $Type -eq 'exe') { $silent = [string]$switches['silentWithProgress'] }
    if (-not $silent) { $silent = [string]$script:WinGetDefaultSilent[$Type] }
    if (-not $silent -and $Type -eq 'exe') {
        throw "$($Record['id']) is an exe whose manifest gives no silent switch; winget would run it interactively, and nobody is there"
    }
    return (@($silent, [string]$switches['custom']) | Where-Object { $_ }) -join ' '
}

function Resolve-WinPkgsInstallerExit {
    <#
    .SYNOPSIS
        What an installer's exit code means, by its manifest: nothing to say,
        a restart to ask for, or a failure to throw.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$What
    )
    if ($Code -eq 0) { return }
    if ($Code -in @($Record['successCodes'] | ForEach-Object { [int]$_ })) { return }
    $expected = @($Record['expectedReturnCodes']) | Where-Object { $_ -and [int]$_['code'] -eq $Code } | Select-Object -First 1
    $response = if ($expected) { [string]$expected['response'] } elseif ($Code -in 3010, 1641) { 'rebootRequiredToFinish' } else { '' }
    switch ($response) {
        { $_ -in 'rebootRequiredToFinish', 'rebootRequiredForInstall', 'rebootInitiated' } {
            Set-WinPkgsRestartRequired -Because $What
            return
        }
        'alreadyInstalled' { return }
        '' { throw "$What failed: the installer exited $Code" }
        default {
            $more = if ($expected['responseUrl']) { " (see $($expected['responseUrl']))" } else { '' }
            throw "$What failed: the installer exited $Code, which its manifest calls $response$more"
        }
    }
}

function Invoke-WinPkgsInstaller {
    # One file, run as one type, its exit code read by its record.
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$What
    )
    $switches = Get-WinPkgsInstallerSwitches -Record $Record -Type $Type
    if ($Type -in 'msi', 'wix') {
        $msiexec = if ($env:WINPKGS_MSIEXEC) { $env:WINPKGS_MSIEXEC } else { Join-Path $env:SystemRoot 'System32\msiexec.exe' }
        $result = Invoke-WinPkgsCommandLine -Command $msiexec -CommandLine "/i `"$File`" $switches"
    } else {
        $result = Invoke-WinPkgsCommandLine -Command $File -CommandLine $switches
    }
    if ($result.text) { throw "$What failed: $($result.text)" }
    Resolve-WinPkgsInstallerExit -Record $Record -Code $result.code -What $What
}

function Install-WinPkgsCarried {
    <#
    .SYNOPSIS
        Install one carried record at a scope: check the file is the one the
        media was built with, run it as its type, and note what it added to
        Add/Remove Programs.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Installers,
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Scope,
        [hashtable]$Context
    )
    $id = [string]$Record['id']
    $what = "install $id $($Record['version']) from the media"
    $file = Join-Path $Installers['root'] ([string]$Record['file'])
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "${what}: the media has no $($Record['file'])" }
    $hash = Get-WinPkgsStreamHash -Path $file
    if ($hash -ne ([string]$Record['sha256']).ToUpperInvariant()) {
        throw "${what}: $($Record['file']) is not the file the media was built with (SHA-256 $hash, installers.json says $($Record['sha256']))"
    }
    Write-Host "      $what"

    Install-WinPkgsWindowsFeatures -Record $Record
    $type = Get-WinPkgsInstallerType -Record $Record
    if ($type -eq 'portable') {
        Install-WinPkgsPortable -Record $Record -File $file -Scope $Scope
        return
    }
    if ($type -in 'msix', 'appx') {
        if ($Record['type'] -eq 'zip') { throw "${what}: an MSIX inside a zip is not run offline" }
        Install-WinPkgsAppx -File $file -Record $Record -Scope $Scope
        return
    }

    $before = @(Get-WinPkgsArpEntries | ForEach-Object { $_.key })
    if ($Record['type'] -eq 'zip') {
        $work = Join-Path ([IO.Path]::GetTempPath()) ("winpkgs-" + [guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $file -DestinationPath $work -Force
            $nested = @($Record['nestedFiles'])[0]
            if (-not $nested) { throw "${what}: the zip's manifest names no installer inside it" }
            $inner = Join-Path $work (([string]$nested['relativeFilePath']) -replace '/', '\')
            if (-not (Test-Path -LiteralPath $inner -PathType Leaf)) { throw "${what}: the zip has no $($nested['relativeFilePath'])" }
            Invoke-WinPkgsInstaller -Record $Record -File $inner -Type $type -What $what
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Invoke-WinPkgsInstaller -Record $Record -File $file -Type $type -What $what
    }

    # winget's own correlation: what the install added is what it is, for an
    # installer whose manifest gives nothing better to recognise it by.
    $added = @(Get-WinPkgsArpEntries | ForEach-Object { $_.key } | Where-Object { $_ -notin $before })
    if ($added.Count -gt 0 -and $Context -and $Context['State']) {
        if (-not $Context['State']['arp']) { $Context['State']['arp'] = @{} }
        $Context['State']['arp'][$id] = $added
    }
}

function Install-WinPkgsWindowsFeatures {
    # What a record needs of Windows itself: features, which an elevated
    # apply enables, and libraries, which the media does not carry and which
    # are only said to be missing.
    param([Parameter(Mandatory)][hashtable]$Record)
    $dependencies = $Record['dependencies']
    if (-not $dependencies) { return }
    foreach ($feature in @($dependencies['windowsFeatures']) | Where-Object { $_ }) {
        $state = Get-WinPkgsFeatureState -Name $feature
        if ($state -in 'enabled', 'enablePending') { continue }
        if (-not (Test-WinPkgsElevated) -and -not $env:WINPKGS_FEATURE_STATE) {
            Write-Warning "$($Record['id']) needs the Windows feature $feature, which only an elevated apply can enable; declare it in the system configuration (windows.features.$feature = true)"
            continue
        }
        if (Enable-WinPkgsFeature -Name $feature) { Set-WinPkgsRestartRequired -Because "Feature $feature (for $($Record['id']))" }
    }
    foreach ($library in @($dependencies['windowsLibraries']) | Where-Object { $_ }) {
        Write-Warning "$($Record['id']) needs the Windows library $library, which the media does not carry"
    }
}

#endregion

#region the resource, offline

function Find-WinPkgsCarriedInstall {
    <#
    .SYNOPSIS
        Is a record's package installed, and at what version: @{ exists;
        version; name }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Scope,
        [hashtable]$Context
    )
    $id = [string]$Record['id']
    $type = Get-WinPkgsInstallerType -Record $Record
    if ($type -in 'msix', 'appx') {
        $version = Get-WinPkgsAppxVersion -FamilyName ([string]$Record['packageFamilyName']) -Scope $Scope
        if ($null -eq $version) { return @{ exists = $false } }
        return @{ exists = $true; version = $version; name = $id }
    }
    $entries = Get-WinPkgsArpEntries
    $hit = if ($type -eq 'portable') {
        $entries | Where-Object { $_.name -eq (Get-WinPkgsPortableKey -Id $id) } | Select-Object -First 1
    } else {
        Find-WinPkgsArpEntry -Record $Record -Entries $entries -Recorded (Get-WinPkgsRecordedArpKeys -Id $id -Context $Context)
    }
    if (-not $hit) { return @{ exists = $false } }
    $version = if ($hit.displayVersion) { $hit.displayVersion } else { 'Unknown' }
    $name = if ($hit.displayName) { $hit.displayName } else { $id }
    return @{ exists = $true; version = $version; name = $name }
}

function Get-WinPkgsOfflinePackage {
    param([hashtable]$Properties, [hashtable]$Context)
    $record = Get-WinPkgsCarriedRecord -Installers $Context['Installers'] -Id ([string]$Properties['id'])
    $found = Find-WinPkgsCarriedInstall -Record $record -Scope ([string]$Properties['scope']) -Context $Context
    if (-not $found['exists']) { return @{ exists = $false } }
    # Nothing newer is knowable without a source to ask.
    $found['updateAvailable'] = $false
    $found['available'] = $null
    return $found
}

function Install-WinPkgsCarriedRequirements {
    # What a record requires from its own phase, depth first in the order the
    # sidecar gives, each installed when absent or below the minimum the
    # requiring package asks for.
    param(
        [Parameter(Mandatory)][hashtable]$Installers,
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Scope,
        [hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Done
    )
    $required = @($Record['requires'] | Where-Object { $_ })
    $ordered = @($Installers['order'] | Where-Object { $_ -in $required }) + @($required | Where-Object { $_ -notin $Installers['order'] })
    foreach ($id in $ordered) {
        if ($Done.ContainsKey($id)) { continue }
        $Done[$id] = $true
        $dependency = Get-WinPkgsCarriedRecord -Installers $Installers -Id $id
        Install-WinPkgsCarriedRequirements -Installers $Installers -Record $dependency -Scope $Scope -Context $Context -Done $Done
        $asked = if ($Record['dependencies']) { @($Record['dependencies']['packages']) } else { @() }
        $minimum = $asked | Where-Object { $_ -and $_['id'] -eq $id } | ForEach-Object { [string]$_['minimumVersion'] } | Select-Object -First 1
        $found = Find-WinPkgsCarriedInstall -Record $dependency -Scope $Scope -Context $Context
        if ($found['exists']) {
            if (-not $minimum -or -not (Test-WinPkgsVersionComparable -A $found['version'] -B $minimum)) { continue }
            if ((Compare-WinPkgsVersion -A $found['version'] -B $minimum) -ge 0) { continue }
        }
        Write-Host "      $($Record['id']) needs $id"
        Install-WinPkgsCarried -Installers $Installers -Record $dependency -Scope $Scope -Context $Context
    }
}

function Set-WinPkgsOfflinePackage {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $installers = $Context['Installers']
    $id = [string]$Properties['id']
    $scope = [string]$Properties['scope']
    $record = Get-WinPkgsCarriedRecord -Installers $installers -Id $id

    # Looked at again rather than trusted from the plan: an earlier package in
    # this apply may have installed it as a requirement of its own.
    $now = Get-WinPkgsOfflinePackage -Properties $Properties -Context $Context
    if (-not (Test-WinPkgsWinGetPackage -Properties $Properties -Current $now -Context $Context)) {
        $policy = Get-WinPkgsWinGetPolicy -Properties $Properties
        if ($now['exists'] -and $policy -eq 'exact' -and (Test-WinPkgsVersionKnown $now['version']) -and
            (Compare-WinPkgsVersion -A $now['version'] -B ([string]$Properties['version'])) -gt 0) {
            throw "$id $($now['version']) is installed and the configuration pins $($Properties['version']); going down a version means uninstalling, which is winget's: apply again with a network"
        }
        Install-WinPkgsCarriedRequirements -Installers $installers -Record $record -Scope $scope -Context $Context -Done @{}
        Install-WinPkgsCarried -Installers $installers -Record $record -Scope $scope -Context $Context
    }
    Add-WinPkgsOwned -Context $Context -Backend winget -Id $id
}

#endregion
