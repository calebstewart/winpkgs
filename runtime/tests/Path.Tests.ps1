BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    # Never the real HKCU\Environment: the resource takes key/name so tests can
    # point it at a scratch key. The broadcast only fires for HKCU\Environment.
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string]$Dir) { @{ dir = $Dir; key = $TestKey; name = 'Path' } }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/path'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function RawValue {
        $k = Get-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5))
        @{ value = $k.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'); kind = $k.GetValueKind('Path').ToString() }
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'winpkgs/path' {
    It 'creates the value as ExpandString when it does not exist' {
        $p = Props '%LOCALAPPDATA%\winpkgs\bin'
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        $raw = RawValue
        $raw.kind | Should -Be 'ExpandString'
        $raw.value | Should -Be '%LOCALAPPDATA%\winpkgs\bin'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'appends to an existing value and keeps the other entries and kind' {
        $p = Props 'C:\tools'
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        $raw = RawValue
        $raw.kind | Should -Be 'ExpandString'
        $raw.value | Should -Be '%LOCALAPPDATA%\winpkgs\bin;C:\tools'
    }

    It 'matches case-insensitively, ignoring trailing separators and expansion' {
        Op Test (Props 'c:\TOOLS\') (Op Get (Props 'x')) | Should -BeTrue
        Op Test (Props ($env:LOCALAPPDATA + '\winpkgs\bin')) (Op Get (Props 'x')) | Should -BeTrue
        Op Test (Props 'C:\other') (Op Get (Props 'x')) | Should -BeFalse
    }

    It 'restores the previous value' {
        $p = Props 'C:\third'
        $before = Op Get $p
        Op Set $p $before
        (RawValue).value | Should -Be '%LOCALAPPDATA%\winpkgs\bin;C:\tools;C:\third'
        Op Restore $p $null $before
        (RawValue).value | Should -Be '%LOCALAPPDATA%\winpkgs\bin;C:\tools'
    }

    It 'describes changes' {
        Op Describe (Props 'C:\new') (Op Get (Props 'C:\new')) | Should -Be 'append C:\new'
    }
}
