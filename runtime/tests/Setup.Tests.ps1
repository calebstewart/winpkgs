# setup.ps1, like install.ps1, is a script that ends in a reboot or an apply, so
# it cannot be dot-sourced. Its functions are lifted out of the parsed file,
# which also means these tests run the same text CI parses under both hosts.
BeforeAll {
    $SetupScript = (Resolve-Path (Join-Path $PSScriptRoot '..\setup.ps1')).Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($SetupScript, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "setup.ps1 does not parse: $($errors[0].Message)" }
    foreach ($definition in $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    foreach ($assignment in $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false)) {
        if ($assignment.Left.Extent.Text -in '$exitRebootRequired', '$windowsPowerShell') {
            . ([scriptblock]::Create($assignment.Extent.Text))
        }
    }

    # What the state functions close over in the script.
    $stateDir = Join-Path $TestDrive 'setup'
    $statePath = Join-Path $stateDir 'state.json'
}

Describe 'the run' {
    It 'is the six phases, in order' {
        (Get-SetupPhases -State @{ } | ForEach-Object { $_.Name }) -join ',' |
            Should -Be 'payload,wsl,winget,system,credential,home'
    }

    It 'has winget ready before the first apply that needs it' {
        $names = @(Get-SetupPhases -State @{ } | ForEach-Object { $_.Name })
        $names.IndexOf('winget') | Should -BeLessThan $names.IndexOf('system')
    }

    # Not "the system apply asked for a reboot" -- it is where the run stops
    # being elevated. Everything before it needs first logon's administrator
    # token; everything after it must not have one.
    It 'reboots once, after the last phase that needs an administrator' {
        $rebooting = @(Get-SetupPhases -State @{ } | Where-Object { $_.RebootAfter } | ForEach-Object { $_.Name })
        $rebooting | Should -Be @('credential')
    }

    It 'does everything that needs an administrator before that reboot' {
        $names = @(Get-SetupPhases -State @{ } | ForEach-Object { $_.Name })
        $reboot = $names.IndexOf('credential')
        foreach ($elevated in 'wsl', 'winget', 'system', 'credential') {
            $names.IndexOf($elevated) | Should -BeLessOrEqual $reboot
        }
    }

    It 'puts the home configuration after that reboot, never before it' {
        $names = @(Get-SetupPhases -State @{ } | ForEach-Object { $_.Name })
        $names.IndexOf('home') | Should -BeGreaterThan $names.IndexOf('credential')
    }
}

Describe 'what the run records' {
    BeforeEach {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }

    It 'starts with nothing done' {
        (Read-State).completed | Should -BeNullOrEmpty
    }

    It 'remembers a finished phase across a read' {
        $s = Read-State
        Set-PhaseDone -State $s -Name 'payload'
        Test-PhaseDone -State (Read-State) -Name 'payload' | Should -BeTrue
        Test-PhaseDone -State (Read-State) -Name 'wsl' | Should -BeFalse
    }

    It 'records a phase once, however often it is told' {
        $s = Read-State
        Set-PhaseDone -State $s -Name 'payload'
        Set-PhaseDone -State $s -Name 'payload'
        @((Read-State).completed).Count | Should -Be 1
    }

    It 'carries values the reboot would otherwise lose' {
        $s = Read-State
        Set-StateValue -State $s -Name 'distro' -Value 'NixOS'
        Set-StateValue -State $s -Name 'user' -Value 'Caleb Stewart'
        Get-StateValue -State (Read-State) -Name 'user' | Should -Be 'Caleb Stewart'
        Get-StateValue -State (Read-State) -Name 'missing' | Should -BeNullOrEmpty
    }
}

Describe 'applying a document' {
    BeforeEach {
        $script:payload = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:payload 'system\runtime') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:payload 'system\config.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:payload 'system\runtime\winpkgs.ps1') -Value '# stub'
        $script:state = @{ completed = @(); payload = $script:payload }
        Mock Write-Note { }
    }

    It 'is satisfied by a plain success' {
        Mock Invoke-Tool { 0 }
        { Invoke-DocumentPhase -State $script:state -Kind system } | Should -Not -Throw
    }

    # 3010 is "applied, and something needs a restart to take effect". This run
    # reboots after the system document regardless, so the code changes nothing
    # about what happens next -- but reading it as a failure would abort an
    # install that had in fact just succeeded.
    It 'reads 3010 as applied, not as failed' {
        Mock Invoke-Tool { 3010 }
        { Invoke-DocumentPhase -State $script:state -Kind system } | Should -Not -Throw
    }

    It 'still throws on a real failure' {
        Mock Invoke-Tool { 1 }
        { Invoke-DocumentPhase -State $script:state -Kind system } | Should -Throw '*exit code 1*'
    }

    It 'passes over a document the payload does not carry' {
        Mock Invoke-Tool { 1 }
        { Invoke-DocumentPhase -State $script:state -Kind home } | Should -Not -Throw
        Should -Not -Invoke Invoke-Tool
    }

    It 'applies with Windows PowerShell, which is all a new machine has' {
        Mock Invoke-Tool { 0 }
        Invoke-DocumentPhase -State $script:state -Kind system
        Should -Invoke Invoke-Tool -Times 1 -ParameterFilter { $File -like '*WindowsPowerShell*powershell.exe' }
    }

    It 'leaves the packages to winget when the payload carries no installers' {
        Mock Invoke-Tool { 0 }
        Invoke-DocumentPhase -State $script:state -Kind system
        Should -Invoke Invoke-Tool -Times 1 -ParameterFilter { $Arguments -notcontains '-Installers' }
    }

    # The copy on disk, which the state records, and never the media: the home
    # apply runs after the reboot, when the media may be gone.
    It 'hands both applies the payload on disk to install from, when it carries installers' {
        Set-Content -LiteralPath (Join-Path $script:payload 'installers.json') -Value '{}'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:payload 'home\runtime') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:payload 'home\config.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:payload 'home\runtime\winpkgs.ps1') -Value '# stub'
        Mock Invoke-Tool { 0 }
        Invoke-DocumentPhase -State $script:state -Kind system
        Invoke-DocumentPhase -State $script:state -Kind home
        Should -Invoke Invoke-Tool -Times 2 -Exactly -ParameterFilter {
            $at = [array]::IndexOf($Arguments, '-Installers')
            $at -gt [array]::IndexOf($Arguments, 'apply') -and $Arguments[$at + 1] -eq $script:payload
        }
    }
}

Describe 'the winget phase' {
    BeforeEach {
        $script:payload = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:payload | Out-Null
        $script:state = @{ completed = @(); payload = $script:payload }
        Mock Write-Note { }
        Mock Install-WinGetClientModule { }
        Mock Wait-WinGetReady { }
    }

    It 'installs the module and waits for winget' {
        Invoke-WinGetPhase -State $script:state
        Should -Invoke Install-WinGetClientModule -Times 1 -ParameterFilter {
            $Source -eq (Join-Path $script:payload 'modules\Microsoft.WinGet.Client')
        }
        Should -Invoke Wait-WinGetReady -Times 1
    }

    # The wait's repair fetches App Installer, and offline nothing asks winget
    # anything. The module still goes on: the first apply with a network hands
    # the packages to winget through it.
    It 'from offline media, installs the module and does not wait for winget' {
        Set-Content -LiteralPath (Join-Path $script:payload 'installers.json') -Value '{}'
        Invoke-WinGetPhase -State $script:state
        Should -Invoke Install-WinGetClientModule -Times 1
        Should -Not -Invoke Wait-WinGetReady
    }
}

Describe 'copying the payload' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:SourceRoot = Join-Path $script:root 'media'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:SourceRoot 'installers\system\A') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:SourceRoot 'setup.json'), (New-Object byte[] 100))
        [IO.File]::WriteAllBytes((Join-Path $script:SourceRoot 'installers\system\A\a.msi'), (New-Object byte[] 3MB))
        # What the functions close over, shadowed for this test alone.
        $stateDir = Join-Path $script:root 'setup'
        $statePath = Join-Path $stateDir 'state.json'
        $scriptCopy = Join-Path $stateDir 'setup.ps1'
        # $setupScript, the file the phase copies there, is the script's own
        # name for what BeforeAll calls $SetupScript: the same file.
        $script:state = @{ completed = @() }
        Mock Write-Note { }
    }

    It 'counts every file, however deep' {
        Get-DirectorySize -Path $script:SourceRoot | Should -Be (3MB + 100)
    }

    It 'copies it, records where, and says how long it took' {
        Invoke-PayloadPhase -State $script:state
        $target = Join-Path $stateDir 'payload'
        Join-Path $target 'installers\system\A\a.msi' | Should -Exist
        $scriptCopy | Should -Exist
        Get-StateValue -State (Read-State) -Name 'payload' | Should -Be $target
        Should -Invoke Write-Note -ParameterFilter { $Text -like 'copied in * s' }
    }

    # Offline media carries gigabytes of installers. A disk that cannot take
    # them is told before the copy, not halfway through it.
    It 'refuses a disk without room for it, before copying anything' {
        Mock Get-FreeSpace { 1MB }
        { Invoke-PayloadPhase -State $script:state } | Should -Throw '*needs 3?0 MB*has 1?0 MB free*'
        Join-Path $stateDir 'payload' | Should -Not -Exist
        Get-StateValue -State (Read-State) -Name 'payload' | Should -BeNullOrEmpty
    }
}

Describe 'retiring the setup credential' {
    BeforeEach {
        $script:steps = New-Object System.Collections.Generic.List[string]
        Mock Set-LocalAccountBlankPassword { $script:steps.Add('password') }
        Mock Disable-AutoLogon { $script:steps.Add('autologon') }
        Mock Unregister-ScheduledTask { $script:steps.Add('task') }
    }

    It 'changes the password, then stops the automatic logon, then removes itself' {
        Invoke-RetireSetupCredential -User 'me' -TaskName 't' -TaskPath '\winpkgs\'
        $script:steps -join ',' | Should -Be 'password,autologon,task'
        Should -Invoke Set-LocalAccountBlankPassword -ParameterFilter { $User -eq 'me' }
    }

    # The order is the safety: if the password cannot be changed, the machine
    # keeps the automatic logon and the setup password its builder knows, and
    # the task stays to try again at the next sign-in.
    It 'leaves the automatic logon and the task alone when the password cannot be changed' {
        Mock Set-LocalAccountBlankPassword { throw 'Access is denied.' }
        { Invoke-RetireSetupCredential -User 'me' -TaskName 't' -TaskPath '\winpkgs\' } | Should -Throw '*denied*'
        Should -Not -Invoke Disable-AutoLogon
        Should -Not -Invoke Unregister-ScheduledTask
    }
}

Describe 'the task that retires it' {
    It 'is a whole script that parses on its own' {
        $encoded = New-RetireCommand -User "O'Brien Smith" -TaskName 't' -TaskPath '\winpkgs\' -Log 'C:\x\credential.log'
        $script = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
        foreach ($name in 'Set-LocalAccountBlankPassword', 'Disable-AutoLogon', 'Invoke-RetireSetupCredential') {
            $defined | Should -Contain $name
        }
        # The quoting holds for a name with a quote and a space in it.
        $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Invoke-RetireSetupCredential' }, $true)
        $call.CommandElements[2].Value | Should -Be "O'Brien Smith"
    }

    # Run for real, as the task would run it, against an account that does not
    # exist: it has to get as far as the password, fail there, write its log,
    # and touch nothing after. Nothing on this machine is changed.
    It 'runs as Windows PowerShell runs it, and stops safely at the first step that fails' {
        $log = Join-Path $TestDrive 'credential.log'
        $user = 'winpkgs-no-such-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $encoded = New-RetireCommand -User $user -TaskName ('winpkgs-no-such-' + [guid]::NewGuid().ToString('N')) `
            -TaskPath '\winpkgs-tests\' -Log $log
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # The failure it is meant to hit is written to stderr, and Windows
        # PowerShell running this test under Stop turns merged native stderr
        # into a terminating error of its own, before anything is asserted.
        $ErrorActionPreference = 'Continue'
        $null = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        $log | Should -Exist
        $text = Get-Content -LiteralPath $log -Raw
        # It stopped in the first step, the password, and went no further.
        $text | Should -Match 'TerminatingError\(Set-LocalAccountBlankPassword\)'
        $text | Should -Not -Match 'TerminatingError\((Disable-AutoLogon|Unregister-ScheduledTask)\)'
        $text | Should -Not -Match 'the setup credential is retired'
    }
}

Describe 'registering it' {
    BeforeEach {
        $script:stateDir = $TestDrive
        Mock Write-Note { }
        Mock Register-ScheduledTask { }
    }

    It 'runs it as SYSTEM, at the next sign-in of the account, a little after' {
        Invoke-CredentialPhase -State @{ user = 'me' }
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $TaskPath -eq '\winpkgs\' -and
            $Principal.UserId -match 'SYSTEM$' -and $Principal.RunLevel -eq 'Highest' -and
            $Trigger.UserId -eq "$env:COMPUTERNAME\me" -and $Trigger.Delay -eq 'PT30S' -and
            $Action.Execute -like '*WindowsPowerShell*powershell.exe' -and $Action.Arguments -like '*-EncodedCommand *'
        }
    }

    It 'does not invent an account to lock when the run never recorded one' {
        Invoke-CredentialPhase -State @{ }
        Should -Not -Invoke Register-ScheduledTask
    }
}

Describe 'running another program' {
    # setup.ps1 runs with ErrorActionPreference Stop, and under Windows
    # PowerShell that turns the first line a program writes to a redirected
    # stderr into a terminating error. Real programs, no mocks: this is only
    # ever wrong under 5.1, which is the host setup.ps1 runs on.
    BeforeEach { Mock Out-Host { } }

    It 'judges a program by its exit code, not by its stderr' {
        $ErrorActionPreference = 'Stop'
        Invoke-Tool -File 'cmd.exe' -Arguments @('/c', 'echo a warning 1>&2 & exit /b 0') | Should -Be 0
    }

    It 'returns a failing exit code instead of throwing on the error text' {
        $ErrorActionPreference = 'Stop'
        Invoke-Tool -File 'cmd.exe' -Arguments @('/c', 'echo tar: command not found 1>&2 & exit /b 127') | Should -Be 127
    }

    It 'leaves the caller strict afterwards' {
        $ErrorActionPreference = 'Stop'
        $null = Invoke-Tool -File 'cmd.exe' -Arguments @('/c', 'exit /b 0')
        $ErrorActionPreference | Should -Be 'Stop'
    }
}

Describe 'reading what wsl.exe answers' {
    # A stand-in wsl.exe that does what the real one did on a new distro's first
    # start: a warning on stderr, the answer on stdout.
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        $script:WslExe = Join-Path $script:root 'wsl.cmd'
        $script:Distro = 'NixOS'
        Mock Write-Note { }
        function script:Set-FakeWsl([string[]]$Stdout, [int]$Code = 0) {
            $lines = @('@echo off', "echo wsl: Failed to start the systemd user session for 'nixos'. 1>&2")
            $lines += @($Stdout | ForEach-Object { "echo $_" })
            $lines += "exit /b $Code"
            Set-Content -LiteralPath $script:WslExe -Value $lines
        }
    }

    It 'gives back the path alone, whatever wsl warned about' {
        $ErrorActionPreference = 'Stop'
        Set-FakeWsl -Stdout '/mnt/c/Users/me/AppData/Local/Temp/x.sh'
        ConvertTo-DistroPath 'C:\Users\me\AppData\Local\Temp\x.sh' | Should -Be '/mnt/c/Users/me/AppData/Local/Temp/x.sh'
    }

    It 'still writes the warning down' {
        Set-FakeWsl -Stdout '/mnt/c/x'
        $null = ConvertTo-DistroPath 'C:\x'
        Should -Invoke Write-Note -ParameterFilter { $Text -like '*systemd user session*' }
    }

    It 'fails when wslpath does' {
        Set-FakeWsl -Stdout @() -Code 1
        { ConvertTo-DistroPath 'C:\x' } | Should -Throw '*wslpath failed*'
    }

    # What -Resume depends on: seeing that the distro is already there, so it is
    # not imported a second time.
    It 'sees a distro that is already imported' {
        $ErrorActionPreference = 'Stop'
        Set-FakeWsl -Stdout @('NixOS-installtest', 'NixOS')
        Test-DistroImported | Should -BeTrue
    }

    It 'does not mistake a similar name for it' {
        Set-FakeWsl -Stdout @('NixOS-installtest')
        Test-DistroImported | Should -BeFalse
    }
}

Describe 'installing WSL' {
    # On a new machine the WSL features bring only a placeholder wsl.exe, and
    # running it installs the real one and closes the console it ran from. So
    # the question "is WSL here" is asked of a file, and the real one comes from
    # the MSI on the payload. Here "WSL" is a one-line .cmd in the test drive, so
    # the check that it answers afterwards is real and this machine's WSL is
    # never touched.
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'WSL') | Out-Null
        $script:WslExe = Join-Path $script:root 'WSL\wsl.cmd'
        $script:msi = Join-Path $script:root 'wsl.msi'
        Set-Content -LiteralPath $script:msi -Value 'not really an msi'
        $script:stateDir = $script:root
        $script:calls = 0
        # What a successful install leaves behind: a wsl that answers.
        function script:New-FakeWsl([int]$Code = 0) {
            Set-Content -LiteralPath $script:WslExe -Value "@exit /b $Code"
        }
        Mock Write-Note { }
        Mock Start-Sleep { }
    }

    It 'leaves an installed WSL alone and never runs the installer' {
        New-FakeWsl
        Mock Start-Process { throw 'msiexec should not run' }
        { Install-WslPackage -Msi $script:msi } | Should -Not -Throw
        Should -Not -Invoke Start-Process
    }

    It 'installs it quietly from the MSI on the payload' {
        Mock Start-Process { New-FakeWsl; [pscustomobject]@{ ExitCode = 0 } }
        Install-WslPackage -Msi $script:msi
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -like '*\msiexec.exe' -and $ArgumentList -like '/i "*wsl.msi" /qn /norestart /l`*v "*"'
        }
    }

    It 'waits out another installation holding the Windows Installer, then installs' {
        Mock Start-Process {
            $script:calls++
            if ($script:calls -lt 3) { return [pscustomobject]@{ ExitCode = 1618 } }
            New-FakeWsl
            [pscustomobject]@{ ExitCode = 0 }
        }
        Install-WslPackage -Msi $script:msi
        Should -Invoke Start-Process -Times 3
        Should -Invoke Start-Sleep -Times 2
    }

    It 'gives up on the Windows Installer eventually, and says why' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1618 } }
        { Install-WslPackage -Msi $script:msi } | Should -Throw '*kept the Windows Installer busy*'
        Should -Invoke Start-Process -Times 10
    }

    # The question the run exists to answer. If first logon's token is not
    # elevated, this is where it shows, and it should read as that.
    It 'says plainly when the run is not elevated' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1925 } }
        { Install-WslPackage -Msi $script:msi } | Should -Throw '*not elevated*'
    }

    It 'carries on from a requested restart, as long as WSL answers' {
        Mock Start-Process { New-FakeWsl; [pscustomobject]@{ ExitCode = 3010 } }
        { Install-WslPackage -Msi $script:msi } | Should -Not -Throw
    }

    It 'does not carry on from a WSL that was installed but does not answer' {
        Mock Start-Process { New-FakeWsl -Code 1; [pscustomobject]@{ ExitCode = 3010 } }
        { Install-WslPackage -Msi $script:msi } | Should -Throw '*does not answer*'
    }

    It 'fails on any other installer answer, with its log' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1603 } }
        { Install-WslPackage -Msi $script:msi } | Should -Throw '*1603*wsl-msi.log*'
    }

    It 'does not trust a success that left no WSL behind' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        { Install-WslPackage -Msi $script:msi } | Should -Throw '*there is no*'
    }

    It 'is an error with neither WSL nor an MSI to install it from' {
        Mock Start-Process { throw 'msiexec should not run' }
        { Install-WslPackage -Msi (Join-Path $script:root 'missing.msi') } | Should -Throw '*no MSI*'
    }
}

Describe 'the WinGet client module' {
    # Not mocked: Program Files is pointed at the test drive and the files are
    # really copied.
    BeforeEach {
        $script:realProgramFiles = $env:ProgramFiles
        $env:ProgramFiles = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:source = Join-Path $TestDrive 'payload\modules\Microsoft.WinGet.Client'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:source '1.29.280\net48') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:source '1.29.280\Microsoft.WinGet.Client.psd1') -Value '@{}'
        Set-Content -LiteralPath (Join-Path $script:source '1.29.280\net48\engine.dll') -Value 'x'
        Mock Write-Note { }
    }
    AfterEach { $env:ProgramFiles = $script:realProgramFiles }

    # Both applies have to find it and they are not the same session: the
    # system one elevated, the home one after a reboot as an ordinary user.
    It 'installs it machine-wide, for Windows PowerShell and for PowerShell 7' {
        Install-WinGetClientModule -Source $script:source
        foreach ($root in 'WindowsPowerShell\Modules', 'PowerShell\Modules') {
            $version = Join-Path $env:ProgramFiles "$root\Microsoft.WinGet.Client\1.29.280"
            Join-Path $version 'Microsoft.WinGet.Client.psd1' | Should -Exist
            Join-Path $version 'net48\engine.dll' | Should -Exist
        }
    }

    It 'is not an error when the payload carries none' {
        { Install-WinGetClientModule -Source (Join-Path $TestDrive 'nowhere') } | Should -Not -Throw
        Join-Path $env:ProgramFiles 'WindowsPowerShell' | Should -Not -Exist
    }
}

Describe 'reading PATH again' {
    # Real registry, real environment; PATH is put back afterwards.
    It 'takes PATH from the machine and the user, with WindowsApps on it' {
        $realPath = $env:Path
        try {
            $env:Path = 'C:\nowhere'
            Update-SessionPath
            @($env:Path -split ';') | Should -Not -Contain 'C:\nowhere'
            @($env:Path -split ';') | Should -Contain (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
            @($env:Path -split ';') | Should -Contain (Join-Path $env:SystemRoot 'System32')
        } finally {
            $env:Path = $realPath
        }
    }
}

Describe 'waiting for winget' {
    BeforeAll {
        # The module is not on a test machine to mock, so these stand in for it.
        function Assert-WinGetPackageManager { [CmdletBinding()] param([switch]$Latest) }
        function Get-WinGetPackage { [CmdletBinding()] param([string]$Id, [string]$MatchOption) }
        function Repair-WinGetPackageManager { [CmdletBinding()] param([switch]$AllUsers, [switch]$Force, [switch]$Latest) }
        function Get-WinGetVersion { 'v1.11.510' }
    }
    BeforeEach {
        $script:repaired = $false
        $script:asks = 0
        Mock Write-Note { }
        Mock Start-Sleep { }
        Mock Update-SessionPath { }
        Mock Import-Module { } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' }
        Mock Repair-WinGetPackageManager { $script:repaired = $true }
    }

    # What the first run to reach this phase showed: the ISO's winget worked for
    # everything the runtime does, elevated or not, while Assert refused it for
    # over half an hour. Ready is the runtime's own question answering.
    It 'asks what the runtime asks, not Assert-WinGetPackageManager' {
        Mock Assert-WinGetPackageManager { throw 'Unable to execute winget command.' }
        Mock Get-WinGetPackage { }
        Wait-WinGetReady -WaitSeconds 600
        Should -Not -Invoke Assert-WinGetPackageManager
        Should -Not -Invoke Repair-WinGetPackageManager
        Should -Invoke Get-WinGetPackage -ParameterFilter { $MatchOption -eq 'Equals' }
    }

    It 'waits for it to answer' {
        Mock Get-WinGetPackage { $script:asks++; if ($script:asks -lt 3) { throw 'not registered yet' } }
        Wait-WinGetReady -WaitSeconds 600
        Should -Invoke Get-WinGetPackage -Times 3
        Should -Not -Invoke Repair-WinGetPackageManager
    }

    It 'repairs it for every user when it does not come by itself' {
        Mock Get-WinGetPackage { if (-not $script:repaired) { throw 'not registered' } }
        Wait-WinGetReady -WaitSeconds 0
        Should -Invoke Repair-WinGetPackageManager -Times 1 -ParameterFilter { $AllUsers -and $Force }
    }

    # -Latest is what made the repair refuse the winget it had just installed.
    It 'repairs to the winget the module was built for, not the newest' {
        Mock Get-WinGetPackage { if (-not $script:repaired) { throw 'not registered' } }
        Wait-WinGetReady -WaitSeconds 0
        Should -Not -Invoke Repair-WinGetPackageManager -ParameterFilter { $Latest }
    }

    It 'does not accept a repair that left it broken' {
        Mock Get-WinGetPackage { throw 'still not registered' }
        { Wait-WinGetReady -WaitSeconds 0 } | Should -Throw '*still not registered*'
    }
}
