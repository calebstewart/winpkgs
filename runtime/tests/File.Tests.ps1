BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Root = Join-Path $TestDrive 'closure'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'files\dir\sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'files\hello.txt') -Value 'hello' -NoNewline
    Set-Content -LiteralPath (Join-Path $Root 'files\dir\a.txt') -Value 'a' -NoNewline
    Set-Content -LiteralPath (Join-Path $Root 'files\dir\sub\b.txt') -Value 'b' -NoNewline

    $env:WINPKGS_TEST_HOME = Join-Path $TestDrive 'home'
    $Ctx = @{ Root = $Root }

    function Props([string]$Target, [string]$Source) { @{ target = $Target; source = $Source } }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before, [string]$BackupDir) {
        $splat = @{ Type = 'winpkgs/file'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        if ($BackupDir) { $splat['BackupDir'] = $BackupDir }
        Invoke-WinPkgsResource @splat
    }
}

AfterAll { Remove-Item Env:\WINPKGS_TEST_HOME -ErrorAction SilentlyContinue }

Describe 'winpkgs/file' {
    It 'expands environment variables in the target' {
        $p = Props '%WINPKGS_TEST_HOME%\a\hello.txt' 'files/hello.txt'
        (Op Get $p).target | Should -Be (Join-Path $env:WINPKGS_TEST_HOME 'a\hello.txt')
    }

    It 'creates a file with missing parent directories, then is idempotent' {
        $p = Props '%WINPKGS_TEST_HOME%\a\hello.txt' 'files/hello.txt'
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        Get-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'a\hello.txt') -Raw | Should -Be 'hello'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'detects drift in content' {
        $p = Props '%WINPKGS_TEST_HOME%\a\hello.txt' 'files/hello.txt'
        Set-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'a\hello.txt') -Value 'tampered' -NoNewline
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Describe $p $c | Should -Be 'present'
        Op Set $p $c
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'mirrors a directory and removes files not in the source' {
        $p = Props '%WINPKGS_TEST_HOME%\d' 'files/dir'
        Op Set $p (Op Get $p)
        Op Test $p (Op Get $p) | Should -BeTrue
        Set-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'd\extra.txt') -Value 'x'
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        Test-Path (Join-Path $env:WINPKGS_TEST_HOME 'd\extra.txt') | Should -BeFalse
        Test-Path (Join-Path $env:WINPKGS_TEST_HOME 'd\sub\b.txt') | Should -BeTrue
    }

    It 'leaves copied files writable' {
        $src = Join-Path $Root 'files\ro.txt'
        Set-Content -LiteralPath $src -Value 'ro' -NoNewline
        Set-ItemProperty -LiteralPath $src -Name IsReadOnly -Value $true
        $p = Props '%WINPKGS_TEST_HOME%\ro.txt' 'files/ro.txt'
        Op Set $p (Op Get $p)
        (Get-Item (Join-Path $env:WINPKGS_TEST_HOME 'ro.txt')).IsReadOnly | Should -BeFalse
    }

    It 'backs up and restores previous content' {
        $target = Join-Path $env:WINPKGS_TEST_HOME 'r.txt'
        Set-Content -LiteralPath $target -Value 'original' -NoNewline
        $p = Props '%WINPKGS_TEST_HOME%\r.txt' 'files/hello.txt'
        $before = Op Get $p
        $extra = Op Backup $p $before $null (Join-Path $TestDrive 'backup0')
        $extra.backup | Should -Not -BeNullOrEmpty
        foreach ($k in $extra.Keys) { $before[$k] = $extra[$k] }
        Op Set $p $before
        Get-Content -LiteralPath $target -Raw | Should -Be 'hello'
        Op Restore $p $null $before
        Get-Content -LiteralPath $target -Raw | Should -Be 'original'
    }

    It 'restores absence' {
        $p = Props '%WINPKGS_TEST_HOME%\new.txt' 'files/hello.txt'
        $before = Op Get $p
        Op Set $p $before
        Op Restore $p $null $before
        Test-Path (Join-Path $env:WINPKGS_TEST_HOME 'new.txt') | Should -BeFalse
    }

    It 'throws when the source is missing from the closure' {
        $p = Props '%WINPKGS_TEST_HOME%\a\hello.txt' 'files/nope.txt'
        { Op Test $p (Op Get $p) } | Should -Throw '*missing from closure*'
    }
}
