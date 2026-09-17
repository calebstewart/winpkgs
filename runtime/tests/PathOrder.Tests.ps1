BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    # Never the real Environment key: the resource takes key/name, as
    # winpkgs/path does, so the suite points it at a scratch key.
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string[]]$Dirs) { @{ dirs = $Dirs; key = $TestKey; name = 'Path' } }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current) {
        $splat = @{ Type = 'winpkgs/pathOrder'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        Invoke-WinPkgsResource @splat
    }
    function Value([string]$Text) {
        Invoke-WinPkgsResource -Type 'winpkgs/registry' -Operation Set -Context $Ctx -Properties @{
            key = $TestKey; name = 'Path'; type = 'ExpandString'; value = $Text
        }
    }
    function RawValue {
        $k = Get-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5))
        @{ value = $k.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'); kind = $k.GetValueKind('Path').ToString() }
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'winpkgs/pathOrder' {
    It 'creates the value as ExpandString when it does not exist' {
        $p = Props @('C:\lead')
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        $raw = RawValue
        $raw.kind | Should -Be 'ExpandString'
        $raw.value | Should -Be 'C:\lead'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'moves the directories to the front, in order, keeping the rest as they were' {
        Value 'C:\windows;C:\windows\system32;C:\lead;C:\other'
        $p = Props @('C:\lead', 'C:\other')
        Op Test $p (Op Get $p) | Should -BeFalse
        Op Set $p (Op Get $p)
        (RawValue).value | Should -Be 'C:\lead;C:\other;C:\windows;C:\windows\system32'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'is idempotent: a second Set changes nothing' {
        $p = Props @('C:\lead', 'C:\other')
        Op Set $p (Op Get $p)
        (RawValue).value | Should -Be 'C:\lead;C:\other;C:\windows;C:\windows\system32'
    }

    It 'keeps the spelling the machine already has rather than restating it' {
        Value 'C:\windows;C:\Program Files\WinGet\Links'
        $p = Props @('%ProgramFiles%\WinGet\Links')
        Op Set $p (Op Get $p)
        # Moved, not rewritten, and not added a second time.
        (RawValue).value | Should -Be 'C:\Program Files\WinGet\Links;C:\windows'
    }

    It 'removes the duplicates of a directory it leads' {
        Value 'C:\a;C:\lead;C:\b;C:\LEAD\;C:\c'
        $p = Props @('C:\lead')
        Op Set $p (Op Get $p)
        (RawValue).value | Should -Be 'C:\lead;C:\a;C:\b;C:\c'
    }

    It 'is drift when something unmanaged gets in front' {
        Value 'C:\lead;C:\rest'
        $p = Props @('C:\lead')
        Op Test $p (Op Get $p) | Should -BeTrue
        Value 'C:\installer;C:\lead;C:\rest'
        Op Test $p (Op Get $p) | Should -BeFalse
    }

    It 'is drift when the led directories are out of order' {
        Value 'C:\b;C:\a;C:\rest'
        Op Test (Props @('C:\a', 'C:\b')) (Op Get (Props @('C:\a', 'C:\b'))) | Should -BeFalse
    }

    It 'keeps a String value a String' {
        Invoke-WinPkgsResource -Type 'winpkgs/registry' -Operation Set -Context $Ctx -Properties @{
            key = $TestKey; name = 'Path'; type = 'String'; value = 'C:\rest'
        }
        $p = Props @('C:\lead')
        Op Set $p (Op Get $p)
        (RawValue).kind | Should -Be 'String'
    }

    It 'describes the change' {
        Value 'C:\rest'
        Op Describe (Props @('C:\a', 'C:\b')) (Op Get (Props @('C:\a', 'C:\b'))) | Should -Be 'lead with C:\a, C:\b (now C:\rest)'
    }
}
