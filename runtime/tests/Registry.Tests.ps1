BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string]$Name, [string]$Type, $Value) {
        @{ key = $TestKey; name = $Name; type = $Type; value = $Value; restartExplorer = $false }
    }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/registry'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'winpkgs/registry' {
    It 'reports a missing key as absent and out of state' {
        $p = Props 'Nope' 'DWord' 1
        $c = Op Get $p
        $c.exists | Should -BeFalse
        $c.keyExists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
    }

    It 'creates a DWord (creating the key) and is then idempotent' {
        $p = Props 'Hidden' 'DWord' 1
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.exists | Should -BeTrue
        $c.type | Should -Be 'DWord'
        $c.value | Should -Be 1
        Op Test $p $c | Should -BeTrue
    }

    It 'round-trips DWords above the int32 range' {
        $p = Props 'Big' 'DWord' 4294967295
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.value | Should -Be 4294967295
        Op Test $p $c | Should -BeTrue
    }

    It 'writes QWord' {
        $p = Props 'Q' 'QWord' 8589934592
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.type | Should -Be 'QWord'
        $c.value | Should -Be 8589934592
    }

    It 'writes String, case-sensitively compared' {
        $p = Props 'S' 'String' 'Hello'
        Op Set $p (Op Get $p)
        Op Test $p (Op Get $p) | Should -BeTrue
        Op Test (Props 'S' 'String' 'hello') (Op Get $p) | Should -BeFalse
    }

    It 'writes ExpandString without expanding it' {
        $p = Props 'E' 'ExpandString' '%APPDATA%\x'
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.type | Should -Be 'ExpandString'
        $c.value | Should -Be '%APPDATA%\x'
        Op Test $p $c | Should -BeTrue
    }

    It 'writes MultiString' {
        $p = Props 'M' 'MultiString' @('a', 'b')
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.type | Should -Be 'MultiString'
        @($c.value) | Should -Be @('a', 'b')
        Op Test $p $c | Should -BeTrue
        Op Test (Props 'M' 'MultiString' @('a')) $c | Should -BeFalse
    }

    It 'writes Binary' {
        $p = Props 'B' 'Binary' @(1, 2, 255)
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.type | Should -Be 'Binary'
        @($c.value) | Should -Be @(1, 2, 255)
        Op Test $p $c | Should -BeTrue
    }

    It 'changes the kind of an existing value' {
        $p = Props 'Hidden' 'String' 'yes'
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        (Op Get $p).type | Should -Be 'String'
    }

    It 'deletes with Absent and is then idempotent' {
        $p = Props 'Hidden' 'Absent' $null
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        $c = Op Get $p
        $c.exists | Should -BeFalse
        $c.keyExists | Should -BeTrue
        Op Test $p $c | Should -BeTrue
    }

    It 'restores a previous value' {
        $p5 = Props 'R' 'DWord' 5
        Op Set $p5 (Op Get $p5)
        $before = Op Get $p5
        $p6 = Props 'R' 'DWord' 6
        Op Set $p6 $before
        (Op Get $p6).value | Should -Be 6
        Op Restore $p6 $null $before
        (Op Get $p5).value | Should -Be 5
    }

    It 'restores absence' {
        $p = Props 'Gone' 'DWord' 1
        $before = Op Get $p
        $before.exists | Should -BeFalse
        Op Set $p $before
        (Op Get $p).exists | Should -BeTrue
        Op Restore $p $null $before
        (Op Get $p).exists | Should -BeFalse
    }

    It 'describes changes' {
        Op Describe (Props 'Zz' 'DWord' 1) (Op Get (Props 'Zz' 'DWord' 1)) | Should -Be 'absent -> DWord 1'
    }

    # The provider spells the unnamed default value '(default)' for writes and
    # cannot delete it at all; the API calls it ''. Both halves need proving.
    It 'writes and reads the unnamed default value' {
        $p = Props '' 'String' 'shell32.dll'
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.exists | Should -BeTrue
        $c.type | Should -Be 'String'
        $c.value | Should -Be 'shell32.dll'
        Op Test $p $c | Should -BeTrue
    }

    It 'writes an empty default value (the Windows 11 classic context menu switch)' {
        $p = Props '' 'String' ''
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.exists | Should -BeTrue
        $c.value | Should -Be ''
        Op Test $p $c | Should -BeTrue
    }

    It 'changes the kind of the default value' {
        Op Set (Props '' 'String' 'x') (Op Get (Props '' 'String' 'x'))
        $p = Props '' 'DWord' 3
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.type | Should -Be 'DWord'
        $c.value | Should -Be 3
    }

    It 'deletes and restores the default value' {
        $p = Props '' 'String' 'keepme'
        Op Set $p (Op Get $p)
        $before = Op Get $p
        $gone = Props '' 'Absent' $null
        Op Set $gone (Op Get $gone)
        $c = Op Get $p
        $c.exists | Should -BeFalse
        $c.keyExists | Should -BeTrue
        Op Test $gone $c | Should -BeTrue
        Op Restore $p $null $before
        (Op Get $p).value | Should -Be 'keepme'
    }
}
