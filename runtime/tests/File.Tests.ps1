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

# A program running from the directory being replaced: a copy of cmd.exe,
# waiting. Its image can be renamed but not deleted, as an upgraded service's.
Describe 'winpkgs/file: a file in use' {
    BeforeAll {
        $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
        $Trash = Join-Path $env:WINPKGS_STATE_DIR 'home\trash'
        $KindCtx = @{ Root = $Root; Kind = 'home' }

        function Start-Running([string]$Dir) {
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            $exe = Join-Path $Dir 'svc.exe'
            Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" -Destination $exe
            $proc = Start-Process -FilePath $exe -ArgumentList '/c', 'ping -n 30 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 300
            return $proc
        }
        function Stop-Running($Proc) {
            Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
            [void]$Proc.WaitForExit(5000)
        }
        function Trashed { @(Get-ChildItem -LiteralPath $Trash -File -Force -ErrorAction SilentlyContinue) }
    }
    AfterAll { Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue }
    BeforeEach { Remove-Item -LiteralPath $Trash -Recurse -Force -ErrorAction SilentlyContinue }

    It 'replaces a directory whose program is running, moving the program aside' {
        $dir = Join-Path $env:WINPKGS_TEST_HOME 'running'
        $proc = Start-Running $dir
        try {
            $p = Props '%WINPKGS_TEST_HOME%\running' 'files/dir'
            Invoke-WinPkgsResource -Type winpkgs/file -Operation Set -Properties $p -Context $KindCtx `
                -Current (Invoke-WinPkgsResource -Type winpkgs/file -Operation Get -Properties $p -Context $KindCtx)
            Test-Path (Join-Path $dir 'svc.exe') | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $dir 'a.txt') -Raw | Should -Be 'a'
            (Trashed).Name | Should -BeLike '*-svc.exe'
        } finally { Stop-Running $proc }
    }

    It 'deletes a running file the configuration no longer has, the same way' {
        $dir = Join-Path $env:WINPKGS_TEST_HOME 'gone'
        $proc = Start-Running $dir
        try {
            $p = Props '%WINPKGS_TEST_HOME%\gone' 'files/dir'
            Invoke-WinPkgsResource -Type winpkgs/file -Operation Restore -Properties $p -Before @{ exists = $false } -Context $KindCtx
            Test-Path -LiteralPath $dir | Should -BeFalse
            @(Trashed).Count | Should -Be 1
        } finally { Stop-Running $proc }
    }

    It 'still fails without a kind to keep a trash for' {
        $dir = Join-Path $env:WINPKGS_TEST_HOME 'nokind'
        $proc = Start-Running $dir
        try {
            $p = Props '%WINPKGS_TEST_HOME%\nokind' 'files/dir'
            { Op Set $p (Op Get $p) } | Should -Throw
        } finally { Stop-Running $proc }
    }

    It 'empties the trash of what is no longer in use, and keeps what is' {
        Mock -ModuleName WinPkgs Test-WinPkgsElevated { $false }
        $proc = Start-Running (Join-Path $env:WINPKGS_TEST_HOME 'kept')
        try {
            InModuleScope WinPkgs -Parameters @{ Path = (Join-Path $env:WINPKGS_TEST_HOME 'kept'); Trash = $Trash } {
                Remove-WinPkgsPath -Path $Path -Trash $Trash
            }
            Set-Content -LiteralPath (Join-Path $Trash 'free.txt') -Value 'x'
            InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind home }
            (Trashed).Name | Should -BeLike '*-svc.exe'
        } finally { Stop-Running $proc }
        InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind home }
        @(Trashed).Count | Should -Be 0
    }

    It 'elevated, schedules what is still in use for deletion at restart, once' {
        Mock -ModuleName WinPkgs Test-WinPkgsElevated { $true }
        Mock -ModuleName WinPkgs Register-WinPkgsDeleteAtRestart { }
        $proc = Start-Running (Join-Path $env:WINPKGS_TEST_HOME 'scheduled')
        try {
            InModuleScope WinPkgs -Parameters @{ Path = (Join-Path $env:WINPKGS_TEST_HOME 'scheduled'); Trash = $Trash } {
                Remove-WinPkgsPath -Path $Path -Trash $Trash
            }
            InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind system }   # another kind's trash: nothing there
            InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind home }
            InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind home }
            (Trashed).Name | Should -BeLike '*-svc.exe.at-restart'
            Should -Invoke -ModuleName WinPkgs Register-WinPkgsDeleteAtRestart -Times 1 -Exactly
        } finally { Stop-Running $proc }
        InModuleScope WinPkgs { Clear-WinPkgsTrash -Kind home }
        @(Trashed).Count | Should -Be 0
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
