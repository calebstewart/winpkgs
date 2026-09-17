BeforeAll {
    # Not the module: this file is inlined into a user's profile, so the suite
    # dot-sources it the way the profile would.
    . (Join-Path $PSScriptRoot '..\profile\Sudo.ps1')

    # The mode is a machine value in HKLM; the resource-style stand-in points
    # the read at a scratch key of our own.
    $ModeKey = 'HKCU:\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    New-Item -Path $ModeKey -Force | Out-Null
    $env:WINPKGS_SUDO_KEY = $ModeKey
    function Mode([int]$Value) { Set-ItemProperty -LiteralPath $ModeKey -Name Enabled -Value $Value -Type DWord }

    # A stand-in for sudo.exe, so nothing elevates and the arguments are
    # readable afterwards. A .ps1 shim is what the runtime's other external
    # commands use.
    $Shim = Join-Path $TestDrive 'sudo.ps1'
    $Log = Join-Path $TestDrive 'argv.txt'
    Set-Content -LiteralPath $Shim -Encoding UTF8 -Value @'
$args | Set-Content -LiteralPath $env:WINPKGS_SUDO_LOG
exit 7
'@
    $env:WINPKGS_SUDO = $Shim
    $env:WINPKGS_SUDO_LOG = $Log

    function Argv { @(Get-Content -LiteralPath $Log) }
    function Decode([string]$Base64) { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Base64)) }
    # What Resolve-WinPkgsSudoCommand encoded, decoded back.
    function Payload($Invocation) { Decode $Invocation.arguments[$Invocation.arguments.Count - 1] }
    function Resolve($Arguments, [int]$Mode = 3, [bool]$LoadProfile = $false) {
        Resolve-WinPkgsSudoCommand -Arguments $Arguments -Mode $Mode -LoadProfile $LoadProfile
    }
}

AfterAll {
    Remove-Item -LiteralPath $ModeKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:WINPKGS_SUDO, Env:WINPKGS_SUDO_KEY, Env:WINPKGS_SUDO_LOG -ErrorAction SilentlyContinue
}

Describe 'Get-WinPkgsSudoMode' {
    It 'is $null when the value is absent, and the number when it is there' {
        Remove-ItemProperty -LiteralPath $ModeKey -Name Enabled -ErrorAction SilentlyContinue
        Get-WinPkgsSudoMode | Should -BeNullOrEmpty
        foreach ($m in 0, 1, 2, 3) {
            Mode $m
            Get-WinPkgsSudoMode | Should -Be $m
        }
    }
}

Describe 'Invoke-WinPkgsSudo' {
    BeforeEach {
        Mode 3
        Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    }

    It 'refuses pipeline input without running sudo' {
        { Invoke-WinPkgsSudo -Argument @('cmd.exe') -ExpectingInput -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*pipeline input*'
        Test-Path -LiteralPath $Log | Should -BeFalse
    }

    It 'refuses when Sudo for Windows is switched off, before elevating anything' {
        Mode 0
        { Invoke-WinPkgsSudo -Argument @('cmd.exe') -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*switched off*'
        Test-Path -LiteralPath $Log | Should -BeFalse
    }

    It 'runs sudo and carries the exit code back' {
        Invoke-WinPkgsSudo -Argument @('cmd.exe', '/c', 'echo', 'hi')
        $LASTEXITCODE | Should -Be 7
        (Argv)[0] | Should -BeLike '*cmd.exe'
    }
}

Describe 'Resolve-WinPkgsSudoCommand' {
    It 'passes a program straight through, resolved to its full path' {
        $i = Resolve @('cmd.exe', '/c', 'echo', 'hi')
        $i.command | Should -BeNullOrEmpty
        $i.arguments[0] | Should -BeLike '*\cmd.exe'
        $i.arguments[1..3] | Should -Be @('/c', 'echo', 'hi')
    }

    It 'resolves an alias to what it names -- the case sudo.exe cannot do' {
        # `ls` is Get-ChildItem in PowerShell and no program at all.
        $i = Resolve @('ls', 'C:\')
        $i.command | Should -Not -BeNullOrEmpty
        Payload $i | Should -BeLike "*& 'Get-ChildItem' 'C:\'*"
    }

    It 'encodes a cmdlet for an elevated PowerShell without the profile' {
        $i = Resolve @('Get-ChildItem', '-Force')
        $i.arguments | Should -Contain '-NoProfile'
        $i.arguments | Should -Contain '-EncodedCommand'
        $i.arguments | Should -Not -Contain '-NoExit'
        $payload = Payload $i
        $payload | Should -BeLike "*& 'Get-ChildItem' -Force*"
        $payload | Should -BeLike '*exit $LASTEXITCODE*'
    }

    It 'loads the profile only when asked' {
        (Resolve @('Get-ChildItem') 3 $true).arguments | Should -Not -Contain '-NoProfile'
    }

    It 'holds the window open in forceNewWindow, for a program too' {
        (Resolve @('Get-ChildItem') 1).arguments | Should -Contain '-NoExit'
        $i = Resolve @('cmd.exe', '/c', 'echo', 'hi') 1
        $i.command | Should -Not -BeNullOrEmpty
        $i.arguments | Should -Contain '-NoExit'
        # Everything that is not a parameter name crosses as a quoted literal.
        Payload $i | Should -BeLike "*cmd.exe' '/c' 'echo' 'hi'*"
    }

    It 'sends a session function along with the command' {
        function script:demo-fn { param($x) $x }
        $i = Resolve @('demo-fn', 'a b')
        $payload = Payload $i
        $payload | Should -BeLike '*function script:demo-fn*'
        $payload | Should -BeLike "*& 'demo-fn' 'a b'*"
    }

    It 'imports the module a function came from instead of copying it' {
        $i = Resolve @('Get-WinPkgsSudoMode')
        # Dot-sourced here, so it has no module; a real module function does.
        $command = Get-Command Start-Job
        if ($command.CommandType -eq 'Function' -and $command.Module) {
            Payload (Resolve @('Start-Job')) | Should -BeLike '*Import-Module*'
        }
        $i.command | Should -Not -BeNullOrEmpty
    }

    It 'runs a scriptblock as written' {
        $i = Resolve @({ Get-Service -Name Spooler })
        Payload $i | Should -BeLike '*Get-Service -Name Spooler*'
    }

    It 'refuses $using:, which would silently mean nothing' {
        $value = 'x'
        $i = Resolve @({ Write-Output $using:value })
        $i.error | Should -BeLike '*$using:*'
        $i.arguments | Should -BeNullOrEmpty
    }

    It 'hands a name it cannot resolve to sudo.exe, whose own words are better' {
        $i = Resolve @('--version')
        $i.command | Should -BeNullOrEmpty
        $i.arguments | Should -Be @('--version')
    }

    It 'refuses a payload too large for a command line rather than spilling it to disk' {
        $big = 'x' * 40000
        $i = Resolve @({ Write-Output 'PLACEHOLDER' }.ToString().Replace('PLACEHOLDER', $big) | ForEach-Object { [scriptblock]::Create($_) })
        $i.error | Should -BeLike '*too large*'
    }

    It 'quotes arguments as data and leaves parameter names as syntax' {
        $payload = Payload (Resolve @('Get-ChildItem', '-Path', 'C:\Program Files', '-Force'))
        $payload | Should -BeLike "*-Path 'C:\Program Files' -Force*"
    }
}
