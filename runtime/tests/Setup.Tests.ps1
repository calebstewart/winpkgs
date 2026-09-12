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
    It 'is the five phases, in order' {
        (Get-SetupPhases -State @{ } | ForEach-Object { $_.Name }) -join ',' |
            Should -Be 'payload,wsl,system,home,finalize'
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
