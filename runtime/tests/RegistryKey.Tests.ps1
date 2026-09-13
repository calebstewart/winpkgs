BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestRoot = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string]$Suffix, [bool]$Present) {
        @{ key = "$TestRoot\$Suffix"; present = $Present; restartExplorer = $false }
    }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [string]$Dir) {
        $splat = @{ Type = 'winpkgs/registryKey'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Dir) { $splat['BackupDir'] = $Dir }
        Invoke-WinPkgsResource @splat
    }
    function Path([hashtable]$P) { 'Registry::HKEY_CURRENT_USER\' + $P.key.Substring(5) }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestRoot.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'winpkgs/registryKey' {
    It 'reports a missing key as absent and out of state' {
        $p = Props 'missing' $true
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
    }

    It 'creates a key and is then idempotent' {
        $p = Props 'make' $true
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.exists | Should -BeTrue
        Op Test $p $c | Should -BeTrue
    }

    It 'is in state when an absent key should be absent' {
        $p = Props 'never' $false
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'deletes a key with its subkeys and values' {
        $p = Props 'doomed' $false
        New-Item -Path (Path $p) -Force | Out-Null
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 1 -Type DWord
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        (Op Get $p).exists | Should -BeFalse
    }

    It 'exports a key before it is deleted, values and subkeys included' {
        $p = Props 'exported' $false
        New-Item -Path (Path $p) -Force | Out-Null
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 42 -Type DWord

        $current = Op Get $p
        $extra = Op Backup $p $current (Join-Path $TestDrive 'backup')
        $extra.backup | Should -Exist

        Op Set $p $current
        (Op Get $p).exists | Should -BeFalse

        # The export is the record of what was deleted: importing it puts the key back.
        $r = InModuleScope WinPkgs -Parameters @{ File = $extra.backup } { param($File) Invoke-WinPkgsReg -Arguments @('import', $File) }
        $r['failed'] | Should -BeFalse
        (Get-ItemProperty -LiteralPath (Path $p)).V | Should -Be 42
        (Test-Path -LiteralPath ((Path $p) + '\child')) | Should -BeTrue
    }

    It 'describes changes' {
        Op Describe (Props 'zz' $true) @{ exists = $false } | Should -Be 'absent -> present'
        Op Describe (Props 'zz' $false) @{ exists = $false } | Should -Be 'absent'
    }
}
