BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    # A scratch key, never the real HKCU\Environment; the broadcast only fires for that one.
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string]$Name, [string]$Value) { @{ name = $Name; value = $Value; key = $TestKey } }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/environment'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function Kind([string]$Name) {
        (Get-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5))).GetValueKind($Name).ToString()
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'winpkgs/environment' {
    It 'creates a plain value as String and is then idempotent' {
        $p = Props 'EDITOR' 'nvim'
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        Kind 'EDITOR' | Should -Be 'String'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'stores a value with %VAR% references as ExpandString' {
        $p = Props 'TOOLS' '%LOCALAPPDATA%\tools'
        Op Set $p (Op Get $p)
        Kind 'TOOLS' | Should -Be 'ExpandString'
        (Op Get $p).value | Should -Be '%LOCALAPPDATA%\tools'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'detects a changed value, case-sensitively, and updates in place' {
        $p = Props 'EDITOR' 'code'
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Describe $p $c | Should -Be 'nvim -> code'
        Op Set $p $c
        (Op Get $p).value | Should -Be 'code'
        Op Test (Props 'EDITOR' 'Code') (Op Get $p) | Should -BeFalse
    }

    It 'restores the previous value and absence' {
        $p = Props 'EDITOR' 'vim'
        $before = Op Get $p
        Op Set $p $before
        Op Restore $p $null $before
        (Op Get $p).value | Should -Be 'code'

        $q = Props 'NEWVAR' 'x'
        $absent = Op Get $q
        Op Set $q $absent
        Op Restore $q $null $absent
        (Op Get $q).exists | Should -BeFalse
    }
}
