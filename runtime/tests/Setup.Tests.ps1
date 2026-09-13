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
            Should -Be 'payload,wsl,winget,system,home,finalize'
    }

    It 'has winget ready before the first apply that needs it' {
        $names = @(Get-SetupPhases -State @{ } | ForEach-Object { $_.Name })
        $names.IndexOf('winget') | Should -BeLessThan $names.IndexOf('system')
    }

    # Not "the system apply asked for a reboot" -- it is where the run stops
    # being elevated. Everything before it needs first logon's administrator
    # token; everything after it must not have one.
    It 'reboots after the system configuration and nowhere else' {
        $rebooting = @(Get-SetupPhases -State @{ } | Where-Object { $_.RebootAfter } | ForEach-Object { $_.Name })
        $rebooting | Should -Be @('system')
    }

    It 'puts the home configuration after that reboot, never before it' {
        $names = @(Get-SetupPhases -State @{ } | ForEach-Object { $_.Name })
        $names.IndexOf('home') | Should -BeGreaterThan $names.IndexOf('system')
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
}

Describe 'retiring the setup credential' {
    BeforeEach {
        Mock Write-Note { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
    }

    It 'turns off the automatic logon rather than letting a count run out' {
        Invoke-FinalizePhase -State @{ }
        Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter {
            $Name -eq 'AutoAdminLogon' -and $Value -eq '0'
        }
        Should -Invoke Remove-ItemProperty -ParameterFilter { $Name -eq 'DefaultPassword' }
        Should -Invoke Remove-ItemProperty -ParameterFilter { $Name -eq 'AutoLogonCount' }
    }

    It 'leaves the account alone when the run never recorded one' {
        # Nothing to retire is not the same as retiring nothing: this must not
        # invent a user name and lock somebody out of a machine.
        { Invoke-FinalizePhase -State @{ } } | Should -Not -Throw
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

Describe 'waiting for winget' {
    BeforeAll {
        # The module is not on a test machine to mock, so these stand in for it.
        function Assert-WinGetPackageManager { [CmdletBinding()] param([switch]$Latest) }
        function Repair-WinGetPackageManager { [CmdletBinding()] param([switch]$AllUsers, [switch]$Force, [switch]$Latest) }
        function Get-WinGetVersion { 'v1.29.290' }
    }
    BeforeEach {
        $script:repaired = $false
        $script:asserts = 0
        Mock Write-Note { }
        Mock Start-Sleep { }
        Mock Import-Module { } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' }
        Mock Repair-WinGetPackageManager { $script:repaired = $true }
    }

    It 'goes straight on when winget already answers' {
        Mock Assert-WinGetPackageManager { }
        Wait-WinGetReady
        Should -Not -Invoke Repair-WinGetPackageManager
    }

    It 'waits for the Store to register it' {
        Mock Assert-WinGetPackageManager { $script:asserts++; if ($script:asserts -lt 3) { throw 'not registered yet' } }
        Wait-WinGetReady -WaitSeconds 600
        Should -Invoke Assert-WinGetPackageManager -Times 3
        Should -Not -Invoke Repair-WinGetPackageManager
    }

    It 'repairs it for every user when it does not come by itself' {
        Mock Assert-WinGetPackageManager { if (-not $script:repaired) { throw 'not registered' } }
        Wait-WinGetReady -WaitSeconds 0
        Should -Invoke Repair-WinGetPackageManager -Times 1 -ParameterFilter { $AllUsers -and $Force -and $Latest }
    }

    It 'does not accept a repair that left it broken' {
        Mock Assert-WinGetPackageManager { throw 'still not registered' }
        { Wait-WinGetReady -WaitSeconds 0 } | Should -Throw '*still not registered*'
    }

    # A working winget that is simply not the newest is not a reason to stop.
    It 'never demands the latest winget to call it ready' {
        Mock Assert-WinGetPackageManager { }
        Wait-WinGetReady
        Should -Not -Invoke Assert-WinGetPackageManager -ParameterFilter { $Latest }
    }
}
