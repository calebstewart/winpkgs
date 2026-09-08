<#
    winpkgs/path - a directory that must be present on a PATH-style registry
    value (by default the user's PATH in HKCU\Environment). PATH is a merge, not
    a set: the entry is appended if missing and everything else is left alone.

    properties: dir, key (default HKCU\Environment), name (default Path)
#>

function Get-WinPkgsPathTarget {
    param([hashtable]$Properties)
    $key = if ($Properties['key']) { $Properties['key'] } else { 'HKCU\Environment' }
    $name = if ($Properties['name']) { $Properties['name'] } else { 'Path' }
    return @{ key = $key; name = $name }
}

function ConvertTo-WinPkgsPathKey {
    # Comparison form: expanded, trailing separators dropped, case folded.
    param([string]$Dir)
    return [Environment]::ExpandEnvironmentVariables($Dir).TrimEnd('\', '/').ToLowerInvariant()
}

function Send-WinPkgsEnvironmentChange {
    # Tell running shells the user environment changed, so new processes see the PATH.
    try {
        if (-not ('WinPkgs.Native.User32' -as [type])) {
            Add-Type -Namespace WinPkgs.Native -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        }
        $result = [System.UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG
        [void][WinPkgs.Native.User32]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    } catch {
        Write-Verbose "WM_SETTINGCHANGE broadcast failed: $($_.Exception.Message)"
    }
}

function Get-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    $current = Get-WinPkgsRegistryValue -Properties @{ key = $t.key; name = $t.name } -Context $Context
    if ($current['exists']) {
        $current['entries'] = @([string]$current['value'] -split ';' | Where-Object { $_ -ne '' })
    }
    return $current
}

function Test-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $want = ConvertTo-WinPkgsPathKey -Dir $Properties['dir']
    foreach ($e in @($Current['entries'])) {
        if ((ConvertTo-WinPkgsPathKey -Dir $e) -eq $want) { return $true }
    }
    return $false
}

function Set-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    # Not `$x = if (...) { @(...) }`: assignment from an if-statement unrolls a
    # one-element array to a scalar, and += then concatenates strings.
    [string[]]$entries = @()
    if ($Current['exists']) { $entries = @($Current['entries']) }
    $entries += [string]$Properties['dir']
    # Keep the kind the value already has; a fresh value is ExpandString so %VAR% entries work.
    $kind = if ($Current['exists'] -and $Current['type'] -in 'String', 'ExpandString') { $Current['type'] } else { 'ExpandString' }
    Write-WinPkgsRegistryValue -Path (ConvertTo-WinPkgsRegistryPath -Key $t.key) -Name $t.name -Kind $kind -Value ($entries -join ';')
    if ($t.key -match '^(HKCU|HKEY_CURRENT_USER)\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Restore-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    Restore-WinPkgsRegistryValue -Properties @{ key = $t.key; name = $t.name } -Before $Before -Context $Context
    if ($t.key -match '^(HKCU|HKEY_CURRENT_USER)\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Format-WinPkgsPathChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) { return "new value with $($Properties['dir'])" }
    return "append $($Properties['dir'])"
}

Register-WinPkgsResource -Type 'winpkgs/path' `
    -Get 'Get-WinPkgsPath' `
    -Test 'Test-WinPkgsPath' `
    -Set 'Set-WinPkgsPath' `
    -Restore 'Restore-WinPkgsPath' `
    -Describe 'Format-WinPkgsPathChange'
