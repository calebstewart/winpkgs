BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestRoot = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $Ctx = @{ Root = $TestDrive }

    function Props([string]$Suffix, [bool]$Present) {
        @{ key = "$TestRoot\$Suffix"; present = $Present; restartExplorer = $false }
    }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before, [string]$Dir) {
        $splat = @{ Type = 'winpkgs/registryKey'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
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

    It 'backs a key up and restores it, values and subkeys included' {
        $p = Props 'restorable' $false
        New-Item -Path (Path $p) -Force | Out-Null
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 42 -Type DWord

        $current = Op Get $p
        $dir = Join-Path $TestDrive 'backup'
        $before = Op Backup $p $current $null $dir
        $before.backup | Should -Exist

        Op Set $p $current
        (Op Get $p).exists | Should -BeFalse

        $record = @{ exists = $true; backup = $before.backup }
        Op Restore $p $null $record
        (Op Get $p).exists | Should -BeTrue
        (Get-ItemProperty -LiteralPath (Path $p)).V | Should -Be 42
        (Test-Path -LiteralPath ((Path $p) + '\child')) | Should -BeTrue
    }

    It 'restores absence by deleting the key it created' {
        $p = Props 'ephemeral' $true
        $before = Op Get $p
        $before.exists | Should -BeFalse
        Op Set $p $before
        (Op Get $p).exists | Should -BeTrue
        Op Restore $p $null $before
        (Op Get $p).exists | Should -BeFalse
    }

    It 'describes changes' {
        Op Describe (Props 'zz' $true) @{ exists = $false } | Should -Be 'absent -> present'
        Op Describe (Props 'zz' $false) @{ exists = $false } | Should -Be 'absent'
    }
}
