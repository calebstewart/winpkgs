# The pointer resource against redirected keys: a scheme applied from a
# definition the test writes in the machine's format, loose name matching,
# and restore. The live cursor is never touched.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $env:WINPKGS_CURSORS_KEY = "$TestKey\Cursors"
    $env:WINPKGS_ACCESSIBILITY_KEY = "$TestKey\Accessibility"
    $env:WINPKGS_CURSOR_SCHEMES_KEY = "$TestKey\Schemes"
    $base = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)

    # Sets in Windows' own format: seventeen entries, a resource reference and
    # an id -- including the one Windows registers with a stray parenthesis.
    New-Item -Path "$base\Schemes" -Force | Out-Null
    $roles = 'arrow', 'help', 'appstarting', 'wait', 'crosshair', 'ibeam', 'nwpen', 'no', 'sizens', 'sizewe', 'sizenwse', 'sizenesw', 'sizeall', 'uparrow', 'hand', 'pin', 'person'
    $aero = ($roles | ForEach-Object { if ($_ -in 'crosshair', 'ibeam') { '' } else { "C:\WINDOWS\cursors\aero_$_.cur" } }) + '@C:\WINDOWS\system32\main.cpl' + '-1020'
    $aeroXl = ($roles | ForEach-Object { "C:\WINDOWS\cursors\aero_$($_)_xl.cur" }) + '@C:\WINDOWS\system32\main.cpl' + '-1022'
    $black = ($roles | ForEach-Object { if ($_ -eq 'hand') { '' } else { "C:\WINDOWS\cursors\$($_)_r.cur" } }) + '@C:\WINDOWS\system32\main.cpl' + '-1011'
    Set-ItemProperty -LiteralPath "$base\Schemes" -Name 'Windows Aero' -Value ($aero -join ',') -Type String
    Set-ItemProperty -LiteralPath "$base\Schemes" -Name 'Windows Aero XL)' -Value ($aeroXl -join ',') -Type String
    Set-ItemProperty -LiteralPath "$base\Schemes" -Name 'Windows Black' -Value ($black -join ',') -Type String

    # The user starts on the white set, as a fresh profile does.
    New-Item -Path "$base\Cursors" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$base\Cursors" -Name '(default)' -Value 'Windows Default' -Type String
    Set-ItemProperty -LiteralPath "$base\Cursors" -Name 'Arrow' -Value 'C:\Windows\cursors\aero_arrow.cur' -Type ExpandString
    Set-ItemProperty -LiteralPath "$base\Cursors" -Name 'Crosshair' -Value '' -Type ExpandString
    New-Item -Path "$base\Accessibility" -Force | Out-Null

    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/pointer'; Operation = $Operation; Properties = $P; Context = @{} }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function Cursor([string]$Name) { (Get-Item -LiteralPath "$base\Cursors").GetValue($Name, $null) }
    function Access([string]$Name) { (Get-Item -LiteralPath "$base\Accessibility").GetValue($Name, $null) }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'WINPKGS_CURSORS_KEY', 'WINPKGS_ACCESSIBILITY_KEY', 'WINPKGS_CURSOR_SCHEMES_KEY') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

Describe 'winpkgs/pointer' {
    It 'applies a named set from the machine definition, every role, empties included' {
        $p = @{ scheme = 'Windows Black'; name = 'Windows Black'; type = 4 }
        $c = Op Get $p
        $c.name | Should -Be 'Windows Default'
        Op Test $p $c | Should -BeFalse
        Op Describe $p $c | Should -Be 'Windows Default -> Windows Black'
        Op Set $p $c
        Cursor 'Arrow' | Should -Be 'C:\WINDOWS\cursors\arrow_r.cur'
        Cursor 'Person' | Should -Be 'C:\WINDOWS\cursors\person_r.cur'
        Cursor 'Hand' | Should -Be ''
        Cursor '' | Should -Be 'Windows Black'
        Cursor 'Scheme Source' | Should -Be 2
        Access 'CursorType' | Should -Be 4
        Op Test $p (Op Get $p) | Should -BeTrue
        Op Test @{ scheme = 'Windows Black'; name = 'Windows Black'; type = 5 } (Op Get $p) | Should -BeFalse
    }

    It 'matches a set name loosely, so the stray parenthesis Windows registers does not matter' {
        $p = @{ scheme = 'Windows Aero XL'; name = 'Windows Aero XL'; type = 3 }
        Op Set $p (Op Get $p)
        Cursor 'Arrow' | Should -Be 'C:\WINDOWS\cursors\aero_arrow_xl.cur'
        Op Test $p (Op Get $p) | Should -BeTrue
        Op Test @{ scheme = 'windows aero xl)'; name = 'Windows Aero XL'; type = 3 } (Op Get $p) | Should -BeTrue
    }

    It 'a set the machine does not define is an error naming it' {
        $p = @{ scheme = 'Neon Dreams'; name = 'Neon Dreams'; type = $null }
        { Op Test $p (Op Get $p) } | Should -Throw "*No cursor scheme named 'Neon Dreams'*"
    }

    It 'restores files, name and type, deleting what was absent' {
        $p = @{ scheme = 'Windows Aero'; name = 'Windows Aero'; type = 3 }
        $before = @{
            exists = $true; name = 'Windows Black'; type = 4
            files = @{ Arrow = 'C:\WINDOWS\cursors\arrow_r.cur'; Hand = ''; Person = $null }
        }
        foreach ($r in 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No', 'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Pin') { $before.files[$r] = "C:\WINDOWS\cursors\$($r.ToLower())_r.cur" }
        Op Set $p (Op Get $p)
        Cursor 'Arrow' | Should -Be 'C:\WINDOWS\cursors\aero_arrow.cur'
        Cursor '' | Should -Be 'Windows Aero'
        Access 'CursorType' | Should -Be 3
        Op Restore $p $null $before
        Cursor 'Arrow' | Should -Be 'C:\WINDOWS\cursors\arrow_r.cur'
        Cursor 'Person' | Should -BeNullOrEmpty
        Cursor '' | Should -Be 'Windows Black'
        Access 'CursorType' | Should -Be 4
    }
}
