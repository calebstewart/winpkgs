<#
    winpkgs/winget - a package installed through winget, driven by the
    Microsoft.WinGet.Client module rather than by parsing CLI output. Reads fall
    back to parsing `winget list` in the one host where the module cannot read
    at all: see Test-WinPkgsWinGetModuleReads.

    properties: id, version (string; null only for a package from another
                source, such as msstore), pinned (bool), upgrade (bool),
                source, scope (null|user|machine)

    What `version` asks for, first match wins (Get-WinPkgsWinGetPolicy):

      pinned        exactly it: an older install is updated to it, a newer one
                    uninstalled and reinstalled at it.
      upgrade       winget's latest: a pending winget update is drift, and no
                    version is ever handed to winget.
      version set   at least it -- the default the configuration resolved from
                    its winget-pkgs pin: an older install is updated to it, a
                    newer one is left alone. Windows programs update
                    themselves, and a machine ahead of the pin is not drift.
      version null  present is enough.

    A document without `pinned` predates it. A document travels with the
    runtime that was built beside it, so this one only meets such a document
    by hand; read here, its pin is a floor.

    Versions compare the way winget compares them (Compare-WinPkgsVersion), so
    the "2.51.0.0" Add/Remove Programs reports is the manifest's "2.51.0". A
    version winget cannot tell -- it says Unknown when there is no
    DisplayVersion -- is never drift, and one of another shape altogether (B6
    against 1.2.3) is not drift under a floor: the plan says so, rather than
    reinstalling on every apply.

    Handed installation media's installers (`winpkgs.ps1 -Installers`, the
    context's `Installers`), Get and Set work from the carried files instead
    and never ask winget: WinGet.Offline.ps1. Test and Describe are the same
    either way.
#>

function Import-WinPkgsWinGetClient {
    if (Get-Module Microsoft.WinGet.Client) { return }
    if (Get-Module -ListAvailable Microsoft.WinGet.Client) {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        return
    }
    # The elevated phase may run under Windows PowerShell, whose module path
    # does not include pwsh's. The module itself supports both hosts.
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $roots = @(
        (Join-Path $documents 'PowerShell\Modules')
        (Join-Path $env:ProgramFiles 'PowerShell\Modules')
        (Join-Path $documents 'WindowsPowerShell\Modules')
    )
    foreach ($root in $roots) {
        $psd1 = Get-ChildItem -Path (Join-Path $root 'Microsoft.WinGet.Client\*\Microsoft.WinGet.Client.psd1') -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($psd1) {
            Import-Module $psd1.FullName -ErrorAction Stop
            return
        }
    }
    throw 'The Microsoft.WinGet.Client module is not installed. Run runtime\bootstrap.ps1 first.'
}

function Get-WinPkgsWinGetCommand {
    # WINPKGS_WINGET names a script to run instead, for the tests.
    if ($env:WINPKGS_WINGET) { return $env:WINPKGS_WINGET }
    return 'winget.exe'
}

function Test-WinPkgsWinGetModuleReads {
    <#
    .SYNOPSIS
        Whether Get-WinGetPackage can be trusted to enumerate installed
        packages in this host.

    .DESCRIPTION
        It cannot under an elevated Windows PowerShell. The module ships two
        payloads and Windows PowerShell loads net48, whose WinRT activation
        goes through its own shim (SharedDependencies\<arch>\winrtact.dll);
        from a high-integrity process that shim cannot bring up the package
        catalog, and Get-WinGetPackage stalls and then fails with 0x800706BA
        (RPC_S_SERVER_UNAVAILABLE). Get-WinGetVersion answers normally in the
        same process, so COM itself is fine and nothing looks broken until a
        package is read; winget.exe answers normally too, which is the way out.

        Unelevated Windows PowerShell reads fine, and so does pwsh either way,
        so this is not "Windows PowerShell cannot read" -- it is the elevated
        pair. Get-WinPkgsElevationHost falls back to Windows PowerShell exactly
        when pwsh is the MSIX build, which makes this the machine-scope phase
        on any machine whose only pwsh came from winget 7.6 or newer.
    #>
    return -not ($PSVersionTable.PSVersion.Major -lt 6 -and (Test-WinPkgsElevated))
}

function ConvertFrom-WinPkgsWinGetList {
    <#
    .SYNOPSIS
        The installed row `winget list --id <id> --exact` prints, as the same
        shape the module's reader returns. $null when there is no such row.

    .DESCRIPTION
        The row is found by its Id, and columns are not counted. winget pads
        every column to its widest cell and separates them with a single space
        -- `Git  Git.Git 2.55.0.3 winget` -- so spacing does not mark where one
        field ends and the next begins, and the header that would give the
        offsets is localized. The Id is the one thing here that is known, so it
        is matched as a whole field: that identifies the row (a spinner, the
        source agreements and the rule are all skipped for lack of it), rules
        out a longer id that merely starts the same way (Git.Git-LFS), and says
        where the rest of the row starts.

        After Version the row carries Available, Source, both or neither, and
        the two are told apart by content -- a source is a source name, an
        available version is not. Getting that wrong would only ever mean
        `updateAvailable` on a package that has no update, so it stays
        conservative: anything ambiguous is read as the source.
    #>
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Id, [string]$Source)

    $sources = @('winget', 'msstore') + @($Source | Where-Object { $_ })
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }

        # The Id as a whole field: bounded by whitespace or the ends of the line.
        $at = -1
        $from = 0
        while ($from -le $line.Length - $Id.Length) {
            $found = $line.IndexOf($Id, $from, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { break }
            $end = $found + $Id.Length
            if (($found -eq 0 -or [char]::IsWhiteSpace($line[$found - 1])) -and
                ($end -ge $line.Length -or [char]::IsWhiteSpace($line[$end]))) {
                $at = $found
                break
            }
            $from = $found + 1
        }
        if ($at -lt 0) { continue }

        $rest = @(($line.Substring($at + $Id.Length) -split '\s+') | Where-Object { $_ })
        if (-not $rest) { continue }

        $available = $null
        foreach ($field in @($rest | Select-Object -Skip 1)) {
            if ($sources -notcontains $field) { $available = $field; break }
        }
        $name = $line.Substring(0, $at).Trim()
        return @{
            exists          = $true
            version         = $rest[0]
            name            = if ($name) { $name } else { $Id }
            updateAvailable = [bool]$available
            available       = $available
        }
    }
    return $null
}

function Get-WinPkgsWinGetPackageFromCli {
    # What is installed, read from winget.exe rather than from the module.
    # --disable-interactivity because a source agreement not yet accepted
    # would otherwise prompt, and the elevated phase has no console to answer
    # with (0x8a150042, "Error reading input in prompt").
    param([hashtable]$Properties)

    $arguments = @(
        'list', '--id', [string]$Properties['id'], '--exact'
        '--disable-interactivity', '--accept-source-agreements'
    )
    if ($Properties['source']) { $arguments += @('--source', [string]$Properties['source']) }

    $result = Invoke-WinPkgsExternal -Command (Get-WinPkgsWinGetCommand) -Arguments $arguments
    # 0x8A150014: nothing installed matches. Any other failure is a fault
    # rather than an answer -- reading it as "absent" would reinstall a package
    # that is perfectly present.
    if ($result.code -eq -1978335212) { return @{ exists = $false } }
    if ($result.failed) {
        throw "winget could not report whether $($Properties['id']) is installed (exit $($result.code)): $($result.text)"
    }

    $row = ConvertFrom-WinPkgsWinGetList -Lines $result.lines -Id ([string]$Properties['id']) -Source ([string]$Properties['source'])
    if (-not $row) { return @{ exists = $false } }
    return $row
}

function Get-WinPkgsWinGetVersionHint {
    # What a request at a named version most often fails on: the version
    # itself. winget-pkgs removes old manifests, and the version came from the
    # configuration's pinned copy of it, which the live source may have moved
    # past (0x8A150017, "No version found matching").
    param([string]$Id, [string]$Version)
    return " -- winget's source may no longer carry $Id ${Version}: winget-pkgs removes old manifests, and this version came from the configuration's pinned copy of it. Update the winget-pkgs input (nix flake update winget-pkgs) so the resolved version is one winget still has, set upgrade = true to follow winget's latest, or pin a version the source carries. If winget instead insists the package is current, its view of the installed version differs from winpkgs'; a pin, or upgrade = true, settles it."
}

function Assert-WinPkgsWinGetResult {
    param($Result, [string]$What, [string]$Scope, [string]$Id, [string]$Version)
    if ($null -eq $Result) { throw "winget returned nothing for: $What" }
    if ($Result.Status -ne 'Ok') {
        $detail = @("status $($Result.Status)")
        if ($Result.ExtendedErrorCode) { $detail += "error $($Result.ExtendedErrorCode)" }
        if ($Result.InstallerErrorCode) { $detail += "installer exit $($Result.InstallerErrorCode)" }
        $hint = ''
        if ($Result.Status -eq 'NoApplicableInstallers' -and $Scope -eq 'user') {
            # The manifest offers only a machine-wide installer (LLVM, most
            # MSI-based tools). A home configuration never elevates, so it
            # cannot take that installer; the package belongs to the machine.
            $hint = " -- the package has no per-user installer; it installs machine-wide. Declare it in the system configuration (environment.systemPackages) rather than the home configuration."
        } elseif ($Version) {
            $hint = Get-WinPkgsWinGetVersionHint -Id $Id -Version $Version
        }
        throw "winget failed to ${What}: $($detail -join ', ')$hint"
    }
    if ($Result.RebootRequired) { Write-Warning "$What requests a reboot" }
}

function Invoke-WinPkgsWinGetAt {
    <#
    .SYNOPSIS
        Install or update at the version the document names, and say what to
        do when winget does not have it.

    .DESCRIPTION
        The module may answer a version its source lacks either as a result
        whose Status is not Ok or by throwing; both get the same hint.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Update')][string]$Command,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$What,
        [string]$Scope,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version
    )
    try {
        $result = switch ($Command) {
            'Install' { Install-WinGetPackage @Arguments }
            'Update'  { Update-WinGetPackage @Arguments }
        }
    } catch {
        throw "winget failed to ${What}: $($_.Exception.Message)$(Get-WinPkgsWinGetVersionHint -Id $Id -Version $Version)"
    }
    Assert-WinPkgsWinGetResult -Result $result -What $What -Scope $Scope -Id $Id -Version $Version
}

#region versions

function ConvertTo-WinPkgsVersionPart {
    # One dot-separated part the way winget reads it: the leading digits as a
    # number and the rest as a string, so "10", "0-beta" and "rc1" all have a
    # place. A run of digits too long for a number is left as a string.
    param([string]$Part)
    $m = [regex]::Match($Part, '^(\d*)(.*)$')
    $n = [uint64]0
    if ($m.Groups[1].Value -and [uint64]::TryParse($m.Groups[1].Value, [ref]$n)) {
        return @{ n = $n; s = $m.Groups[2].Value }
    }
    return @{ n = [uint64]0; s = $Part }
}

function Compare-WinPkgsVersion {
    <#
    .SYNOPSIS
        -1, 0 or 1: how winget orders two versions.

    .DESCRIPTION
        Split on '.', each part a number followed by a string, missing trailing
        parts read as 0 -- so "1.0" is "1.0.0" and "2.51.0.0" is "2.51.0" --
        and within a part the number decides first, then a bare part outranks
        one with a suffix ("1.0" is newer than "1.0-beta"), then the suffixes
        compare as plain strings. A total order: nothing here throws, whatever
        the strings are, which the [version] cast did for "2" against "10" and
        for a dated version.
    #>
    param([string]$A, [string]$B)
    $pa = @($A.Trim() -split '\.')
    $pb = @($B.Trim() -split '\.')
    $count = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $x = if ($i -lt $pa.Count) { ConvertTo-WinPkgsVersionPart $pa[$i] } else { @{ n = [uint64]0; s = '' } }
        $y = if ($i -lt $pb.Count) { ConvertTo-WinPkgsVersionPart $pb[$i] } else { @{ n = [uint64]0; s = '' } }
        if ($x.n -ne $y.n) { if ($x.n -lt $y.n) { return -1 } else { return 1 } }
        if ($x.s -ceq $y.s) { continue }
        if (-not $x.s) { return 1 }
        if (-not $y.s) { return -1 }
        return [Math]::Sign([string]::CompareOrdinal($x.s, $y.s))
    }
    return 0
}

function Test-WinPkgsVersionKnown {
    # winget reports 'Unknown' when Add/Remove Programs has no DisplayVersion.
    # Nothing can be said about such an install, so nothing is done about it.
    param([string]$Version)
    return [bool]($Version -and $Version.Trim() -and $Version.Trim() -ne 'Unknown')
}

function Test-WinPkgsVersionComparable {
    # Two versions of the same shape: both known, and both starting with a
    # digit or both not. "B6" against "1.2.3" would read as older and send a
    # floor after a package that is not behind at all.
    param([string]$A, [string]$B)
    if (-not (Test-WinPkgsVersionKnown $A) -or -not (Test-WinPkgsVersionKnown $B)) { return $false }
    return (($A.Trim() -match '^\d') -eq ($B.Trim() -match '^\d'))
}

#endregion

function Get-WinPkgsWinGetPolicy {
    # exact | latest | minimum | present: what `version` means, in precedence
    # order. A pin outranks upgrade; upgrade outranks a resolved default,
    # which is the one that came from nowhere the user wrote.
    param([hashtable]$Properties)
    $version = [string]$Properties['version']
    if ($Properties['pinned'] -and $version) { return 'exact' }
    if ($Properties['upgrade']) { return 'latest' }
    if ($version) { return 'minimum' }
    return 'present'
}

function Get-WinPkgsWinGetPackageFromModule {
    param([hashtable]$Properties)
    Import-WinPkgsWinGetClient
    $pkg = Get-WinGetPackage -Id $Properties['id'] -MatchOption Equals -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return @{ exists = $false } }
    $available = $null
    if ($pkg.IsUpdateAvailable -and $pkg.AvailableVersions) { $available = [string]$pkg.AvailableVersions[0] }
    return @{
        exists          = $true
        version         = [string]$pkg.InstalledVersion
        name            = [string]$pkg.Name
        updateAvailable = [bool]$pkg.IsUpdateAvailable
        available       = $available
    }
}

function Get-WinPkgsWinGetPackage {
    # The module where it can read (Test-WinPkgsWinGetModuleReads), winget.exe
    # where it cannot. The predicate is what keeps the stall out of the elevated
    # phase -- nine packages waiting on the same doomed activation is minutes --
    # and the catch is for the hosts nobody has characterised: a reader that
    # throws is worth retrying through the CLI, once, before giving up.
    param([hashtable]$Properties, [hashtable]$Context)
    if ($Context -and $Context['Installers']) { return (Get-WinPkgsOfflinePackage -Properties $Properties -Context $Context) }
    if (Test-WinPkgsWinGetModuleReads) {
        try { return (Get-WinPkgsWinGetPackageFromModule -Properties $Properties) }
        catch {
            Write-Warning "the WinGet client module could not read $($Properties['id']) ($($_.Exception.Message)); asking winget.exe instead"
        }
    }
    return (Get-WinPkgsWinGetPackageFromCli -Properties $Properties)
}

function Test-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $have = [string]$Current['version']
    $want = [string]$Properties['version']
    switch (Get-WinPkgsWinGetPolicy -Properties $Properties) {
        'latest' { return (-not $Current['updateAvailable']) }
        'exact' {
            if (-not (Test-WinPkgsVersionKnown $have)) { return $true }
            return ((Compare-WinPkgsVersion -A $have -B $want) -eq 0)
        }
        'minimum' {
            if (-not (Test-WinPkgsVersionComparable -A $have -B $want)) { return $true }
            return ((Compare-WinPkgsVersion -A $have -B $want) -ge 0)
        }
        default { return $true }
    }
}

function Set-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($Context -and $Context['Installers']) {
        Set-WinPkgsOfflinePackage -Properties $Properties -Current $Current -Context $Context
        return
    }
    Import-WinPkgsWinGetClient
    $id = $Properties['id']
    $want = [string]$Properties['version']
    $policy = Get-WinPkgsWinGetPolicy -Properties $Properties
    $named = $policy -in @('exact', 'minimum')

    $common = @{ Id = $id; MatchOption = 'Equals'; Mode = 'Silent' }
    if ($Properties['source']) { $common['Source'] = $Properties['source'] }
    # Machine is SystemOrUnknown, not System: plenty of manifests declare no
    # scope at all (wez.wezterm does not), and System matches only installers
    # that declare one, so such a package could not be installed from a system
    # configuration at all -- NoApplicableInstallers. Run from the elevated
    # system apply, an installer with no declared scope installs for the
    # machine; a declared machine installer is still preferred where there is
    # one. User stays strict: a home configuration never elevates, and an
    # installer that does not say what it is may well need to.
    if ($Properties['scope'] -eq 'machine') { $common['Scope'] = 'SystemOrUnknown' }
    elseif ($Properties['scope'] -eq 'user') { $common['Scope'] = 'User' }
    # The version the document names, for the two policies that name one.
    # Never in $common: the latest policy asks winget for whatever its source
    # has, and a Version key binds even when its value is null.
    $atVersion = $common.Clone()
    if ($named) { $atVersion['Version'] = $want }

    if (-not $Current['exists']) {
        if ($named) {
            Invoke-WinPkgsWinGetAt -Command Install -Arguments $atVersion -What "install $id $want" -Scope $Properties['scope'] -Id $id -Version $want
        } else {
            $result = Install-WinGetPackage @common
            Assert-WinPkgsWinGetResult -Result $result -What "install $id" -Scope $Properties['scope']
        }
    } elseif ($policy -eq 'latest') {
        # Present, and winget has something newer than it.
        $result = Update-WinGetPackage @common
        Assert-WinPkgsWinGetResult -Result $result -What "update $id to $($Current['available'])"
    } elseif ($named) {
        $have = [string]$Current['version']
        $older = (Test-WinPkgsVersionKnown $have) -and ((Compare-WinPkgsVersion -A $have -B $want) -lt 0)
        if ($older) {
            Invoke-WinPkgsWinGetAt -Command Update -Arguments $atVersion -What "update $id to $want" -Scope $Properties['scope'] -Id $id -Version $want
        } elseif ($policy -eq 'exact') {
            # Newer than the pin, or a version winget cannot tell: winget has
            # no in-place downgrade, so out and back in at the pin.
            $u = Uninstall-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
            Assert-WinPkgsWinGetResult -Result $u -What "uninstall $id for downgrade"
            Invoke-WinPkgsWinGetAt -Command Install -Arguments $atVersion -What "install $id $want" -Scope $Properties['scope'] -Id $id -Version $want
        }
        # A floor that is met has nothing to change; Test does not send it here.
    }

    Add-WinPkgsOwned -Context $Context -Backend winget -Id $id
}

function Remove-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Context)
    Import-WinPkgsWinGetClient
    $id = $Properties['id']
    $current = Get-WinPkgsWinGetPackage -Properties $Properties -Context $Context
    if ($current['exists']) {
        $result = Uninstall-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
        Assert-WinPkgsWinGetResult -Result $result -What "uninstall $id"
    }
    Remove-WinPkgsOwned -Context $Context -Backend winget -Id $id
}

function Format-WinPkgsWinGetChange {
    # Read before a change as what will happen and after it as what did, and
    # for an entry in state under -ShowUnchanged, so a floor that is met by a
    # newer install says so rather than looking like a pending downgrade.
    param([hashtable]$Properties, [hashtable]$Current)
    $want = [string]$Properties['version']
    $policy = Get-WinPkgsWinGetPolicy -Properties $Properties
    $target = if ($policy -in @('exact', 'minimum')) { $want } else { 'latest' }
    if (-not $Current['exists']) { return "absent -> $target" }
    $have = [string]$Current['version']
    switch ($policy) {
        'latest' {
            if ($Current['updateAvailable']) { return "$have -> $($Current['available']) (upgrade)" }
            return "installed $have"
        }
        'exact' {
            if (-not (Test-WinPkgsVersionKnown $have)) { return "installed, version unknown ($want pinned)" }
            $c = Compare-WinPkgsVersion -A $have -B $want
            if ($c -lt 0) { return "$have -> $want" }
            if ($c -gt 0) { return "$have -> $want (downgrade)" }
            return "installed $have"
        }
        'minimum' {
            if (-not (Test-WinPkgsVersionKnown $have)) { return "installed, version unknown ($want or newer wanted)" }
            if (-not (Test-WinPkgsVersionComparable -A $have -B $want)) { return "installed $have ($want or newer wanted, not comparable)" }
            $c = Compare-WinPkgsVersion -A $have -B $want
            if ($c -lt 0) { return "$have -> $want" }
            if ($c -gt 0) { return "installed $have ($want or newer wanted)" }
            return "installed $have"
        }
        default { return "installed $have" }
    }
}

Register-WinPkgsResource -Type 'winpkgs/winget' `
    -Get 'Get-WinPkgsWinGetPackage' `
    -Test 'Test-WinPkgsWinGetPackage' `
    -Set 'Set-WinPkgsWinGetPackage' `
    -Remove 'Remove-WinPkgsWinGetPackage' `
    -Describe 'Format-WinPkgsWinGetChange'
