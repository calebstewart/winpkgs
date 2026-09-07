<#
    winpkgs/winget - a package installed through winget, driven by the
    Microsoft.WinGet.Client module rather than by parsing CLI output.

    properties: id, version (null = any), source, scope (null|user|machine)
#>

function Import-WinPkgsWinGetClient {
    if (Get-Module Microsoft.WinGet.Client) { return }
    if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
        throw 'The Microsoft.WinGet.Client module is not installed. Run runtime\bootstrap.ps1 first.'
    }
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
}

function Assert-WinPkgsWinGetResult {
    param($Result, [string]$What)
    if ($null -eq $Result) { throw "winget returned nothing for: $What" }
    if ($Result.Status -ne 'Ok') {
        $detail = @("status $($Result.Status)")
        if ($Result.ExtendedErrorCode) { $detail += "error $($Result.ExtendedErrorCode)" }
        if ($Result.InstallerErrorCode) { $detail += "installer exit $($Result.InstallerErrorCode)" }
        throw "winget failed to ${What}: $($detail -join ', ')"
    }
    if ($Result.RebootRequired) { Write-Warning "$What requests a reboot" }
}

function Test-WinPkgsVersionLess {
    param([string]$A, [string]$B)
    try { return ([version]$A -lt [version]$B) }
    catch { return ([string]::CompareOrdinal($A, $B) -lt 0) }
}

function Get-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Context)
    Import-WinPkgsWinGetClient
    $pkg = Get-WinGetPackage -Id $Properties['id'] -MatchOption Equals -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return @{ exists = $false } }
    return @{ exists = $true; version = [string]$pkg.InstalledVersion; name = [string]$pkg.Name }
}

function Test-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    if ($Properties['version']) { return ([string]$Properties['version'] -eq [string]$Current['version']) }
    return $true
}

function Set-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    Import-WinPkgsWinGetClient
    $id = $Properties['id']

    $common = @{ Id = $id; MatchOption = 'Equals'; Mode = 'Silent' }
    if ($Properties['source']) { $common['Source'] = $Properties['source'] }
    if ($Properties['scope'] -eq 'machine') { $common['Scope'] = 'System' }
    elseif ($Properties['scope'] -eq 'user') { $common['Scope'] = 'User' }
    if ($Properties['version']) { $common['Version'] = $Properties['version'] }

    if ($Current['exists'] -and $Properties['version']) {
        if (Test-WinPkgsVersionLess -A $Current['version'] -B $Properties['version']) {
            $result = Update-WinGetPackage @common
            Assert-WinPkgsWinGetResult -Result $result -What "update $id to $($Properties['version'])"
        } else {
            # Downgrade: winget has no in-place path for this.
            $u = Uninstall-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
            Assert-WinPkgsWinGetResult -Result $u -What "uninstall $id for downgrade"
            $result = Install-WinGetPackage @common
            Assert-WinPkgsWinGetResult -Result $result -What "install $id $($Properties['version'])"
        }
    } else {
        $result = Install-WinGetPackage @common
        Assert-WinPkgsWinGetResult -Result $result -What "install $id"
    }

    Add-WinPkgsOwned -Context $Context -Backend winget -Id $id
}

function Restore-WinPkgsWinGetPackage {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    Import-WinPkgsWinGetClient
    $id = $Properties['id']
    $current = Get-WinPkgsWinGetPackage -Properties $Properties -Context $Context

    if (-not $Before['exists']) {
        if ($current['exists']) {
            $result = Uninstall-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
            Assert-WinPkgsWinGetResult -Result $result -What "uninstall $id"
        }
        Remove-WinPkgsOwned -Context $Context -Backend winget -Id $id
        return
    }

    if ($current['exists'] -and $current['version'] -eq $Before['version']) { return }
    Write-Warning "Reinstalling $id $($Before['version']) - package rollback is best effort"
    if ($current['exists']) {
        $u = Uninstall-WinGetPackage -Id $id -MatchOption Equals -Mode Silent
        Assert-WinPkgsWinGetResult -Result $u -What "uninstall $id"
    }
    $p = @{ Id = $id; MatchOption = 'Equals'; Mode = 'Silent' }
    if ($Properties['source']) { $p['Source'] = $Properties['source'] }
    if ($Before['version']) { $p['Version'] = $Before['version'] }
    $result = Install-WinGetPackage @p
    Assert-WinPkgsWinGetResult -Result $result -What "reinstall $id"
    Add-WinPkgsOwned -Context $Context -Backend winget -Id $id
}

function Format-WinPkgsWinGetChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $want = if ($Properties['version']) { $Properties['version'] } else { 'latest' }
    if (-not $Current['exists']) { return "absent -> $want" }
    if ($Properties['version'] -and $Current['version'] -ne $Properties['version']) {
        return "$($Current['version']) -> $want"
    }
    return "installed $($Current['version'])"
}

Register-WinPkgsResource -Type 'winpkgs/winget' `
    -Get 'Get-WinPkgsWinGetPackage' `
    -Test 'Test-WinPkgsWinGetPackage' `
    -Set 'Set-WinPkgsWinGetPackage' `
    -Restore 'Restore-WinPkgsWinGetPackage' `
    -Describe 'Format-WinPkgsWinGetChange'
