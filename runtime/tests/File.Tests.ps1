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

Describe 'winpkgs/file substitutions' {
    BeforeAll {
        $SubRoot = Join-Path $TestDrive 'closure-sub'
        New-Item -ItemType Directory -Force -Path (Join-Path $SubRoot 'files\tree') | Out-Null
        Set-Content -LiteralPath (Join-Path $SubRoot 'files\gitconfig') -Encoding utf8 -NoNewline -Value "[user]`n`tsigningkey = /home/me/.ssh/id_ed25519`n"
        Set-Content -LiteralPath (Join-Path $SubRoot 'files\tree\a.conf') -Encoding utf8 -NoNewline -Value 'home=/home/me'
        Set-Content -LiteralPath (Join-Path $SubRoot 'files\tree\b.conf') -Encoding utf8 -NoNewline -Value 'nothing to see'
        [IO.File]::WriteAllBytes((Join-Path $SubRoot 'files\tree\blob.bin'), [byte[]](0x2f, 0x68, 0x6f, 0x6d, 0x65, 0x2f, 0x6d, 0x65, 0x00, 0xff))  # "/home/me" then NUL
        $SubCtx = @{
            Root          = $SubRoot
            Substitutions = @(@{ from = '/home/me'; to = 'C:/Users/me' })
        }
        function SubOp([string]$Operation, [hashtable]$P, [hashtable]$Current) {
            $splat = @{ Type = 'winpkgs/file'; Operation = $Operation; Properties = $P; Context = $SubCtx }
            if ($Current) { $splat['Current'] = $Current }
            Invoke-WinPkgsResource @splat
        }
    }

    It 'writes the substituted text and is then in desired state' {
        $p = @{ target = '%WINPKGS_TEST_HOME%\sub\.gitconfig'; source = 'files/gitconfig' }
        SubOp Set $p (SubOp Get $p)
        Get-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'sub\.gitconfig') -Raw | Should -Be "[user]`n`tsigningkey = C:/Users/me/.ssh/id_ed25519`n"
        SubOp Test $p (SubOp Get $p) | Should -BeTrue
    }

    It 'reports drift when the machine still has the placeholder' {
        $p = @{ target = '%WINPKGS_TEST_HOME%\sub\.gitconfig'; source = 'files/gitconfig' }
        Set-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'sub\.gitconfig') -Encoding utf8 -NoNewline -Value "[user]`n`tsigningkey = /home/me/.ssh/id_ed25519`n"
        SubOp Test $p (SubOp Get $p) | Should -BeFalse
    }

    It 'substitutes inside a tree, leaves untouched and binary files byte-identical' {
        $p = @{ target = '%WINPKGS_TEST_HOME%\sub\tree'; source = 'files/tree' }
        SubOp Set $p (SubOp Get $p)
        $dest = Join-Path $env:WINPKGS_TEST_HOME 'sub\tree'
        Get-Content -LiteralPath (Join-Path $dest 'a.conf') -Raw | Should -Be 'home=C:/Users/me'
        Get-Content -LiteralPath (Join-Path $dest 'b.conf') -Raw | Should -Be 'nothing to see'
        (Get-FileHash (Join-Path $dest 'blob.bin')).Hash | Should -Be (Get-FileHash (Join-Path $SubRoot 'files\tree\blob.bin')).Hash
        SubOp Test $p (SubOp Get $p) | Should -BeTrue
    }

    It 'without substitutions the same source is compared and copied as is' {
        $p = @{ target = '%WINPKGS_TEST_HOME%\nosub\gitconfig'; source = 'files/gitconfig' }
        $plain = @{ Type = 'winpkgs/file'; Operation = 'Set'; Properties = $p; Context = @{ Root = $SubRoot } }
        $plain['Current'] = Invoke-WinPkgsResource -Type winpkgs/file -Operation Get -Properties $p -Context @{ Root = $SubRoot }
        Invoke-WinPkgsResource @plain
        Get-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'nosub\gitconfig') -Raw | Should -Match '/home/me/'
    }

    It 'resolves settings.substitutions: env vars expanded, forward slashes' {
        $env:WINPKGS_TEST_PROFILE = 'C:\Users\Some One'
        $doc = @{ settings = @{ substitutions = @(@{ from = '/home/x'; to = '%WINPKGS_TEST_PROFILE%' }) } }
        $r = @(InModuleScope WinPkgs -Parameters @{ doc = $doc } { Resolve-WinPkgsSubstitutions -Document $doc })
        $r.Count | Should -Be 1
        $r[0]['to'] | Should -Be 'C:/Users/Some One'
        @(InModuleScope WinPkgs { Resolve-WinPkgsSubstitutions -Document @{ settings = @{ prune = @{} } } }).Count | Should -Be 0
        Remove-Item Env:\WINPKGS_TEST_PROFILE
    }
}
