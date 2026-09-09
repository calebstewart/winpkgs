# install.ps1 is a script, not a module: it runs top to bottom and ends in a
# reboot or an apply, so it cannot be dot-sourced. Its functions are lifted out
# of the parsed file instead, which is also what keeps these tests honest -- they
# run the same text CI parses under both hosts.
BeforeAll {
    $InstallScript = (Resolve-Path (Join-Path $PSScriptRoot '..\..\install.ps1')).Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallScript, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "install.ps1 does not parse: $($errors[0].Message)" }
    $definitions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $false)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

    # What the state functions close over in the script.
    $stateDir = Join-Path $TestDrive 'install'
    $statePath = Join-Path $stateDir 'state.json'
}

Describe 'Test-GitSource' {
    It 'recognises <Source> as a repository' -ForEach @(
        @{ Source = 'https://github.com/you/config' }
        @{ Source = 'https://github.com/you/config.git' }
        @{ Source = 'ssh://git@example.com/you/config' }
        @{ Source = 'git://example.com/config' }
        @{ Source = 'git@github.com:you/config.git' }
        @{ Source = 'github:you/config' }
        @{ Source = 'gitlab:you/config' }
    ) {
        Test-GitSource $Source | Should -BeTrue
    }

    It 'leaves <Source> to be a path' -ForEach @(
        @{ Source = 'C:\src\config' }
        @{ Source = 'D:/src/config' }
        @{ Source = '.\config' }
        @{ Source = '..\config' }
        @{ Source = 'config' }
        @{ Source = '\\server\share\config' }
        @{ Source = '%USERPROFILE%\git\config' }
    ) {
        Test-GitSource $Source | Should -BeFalse
    }
}

Describe 'ConvertTo-CloneUrl' {
    It 'expands nix flake shorthands' {
        ConvertTo-CloneUrl 'github:you/config' | Should -Be 'https://github.com/you/config'
        ConvertTo-CloneUrl 'gitlab:group/config' | Should -Be 'https://gitlab.com/group/config'
    }

    It 'leaves a real URL alone' {
        ConvertTo-CloneUrl 'https://example.com/config.git' | Should -Be 'https://example.com/config.git'
        ConvertTo-CloneUrl 'git@example.com:you/config' | Should -Be 'git@example.com:you/config'
    }
}

Describe 'Get-RepositoryName' {
    It 'names the clone directory for <Url>' -ForEach @(
        @{ Url = 'https://github.com/you/config'; Expected = 'config' }
        @{ Url = 'https://github.com/you/config.git'; Expected = 'config' }
        @{ Url = 'https://github.com/you/config/'; Expected = 'config' }
        @{ Url = 'https://github.com/you/config.git/'; Expected = 'config' }
        @{ Url = 'git@github.com:you/config.git'; Expected = 'config' }
        @{ Url = 'ssh://git@example.com/you/my-config'; Expected = 'my-config' }
    ) {
        Get-RepositoryName $Url | Should -Be $Expected
    }
}

Describe 'ConvertTo-ShellArgument' {
    It 'quotes a path with a space' {
        ConvertTo-ShellArgument '/mnt/c/Users/Some One/git/cfg' |
            Should -Be "'/mnt/c/Users/Some One/git/cfg'"
    }

    It 'survives a single quote' {
        # bash: close, escape, reopen -- the only way through single quotes.
        ConvertTo-ShellArgument "it's" | Should -Be "'it'\''s'"
    }

    It 'leaves the flake attribute of a home configuration intact' {
        # windowsHomeConfigurations."Some One@host" is why the distro is driven
        # through a script file rather than a command line.
        ConvertTo-ShellArgument '/mnt/c/cfg#windowsHomeConfigurations."Some One@host".config' |
            Should -Be "'/mnt/c/cfg#windowsHomeConfigurations.`"Some One@host`".config'"
    }
}

Describe 'Resolve-ConfigurationName' {
    It 'takes what was asked for' {
        Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names @('desktop', 'laptop') -Requested 'laptop' |
            Should -Be 'laptop'
    }

    It 'names the alternatives when what was asked for is not there' {
        { Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names @('desktop', 'laptop') -Requested 'server' } |
            Should -Throw '*desktop, laptop*'
    }

    It 'takes the only one' {
        Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names @('desktop') | Should -Be 'desktop'
    }

    It 'prefers the one named after this machine, whatever its case' {
        Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names @('desktop', 'laptop') -Preferred 'LAPTOP' |
            Should -Be 'laptop'
    }

    It 'refuses to guess between several' {
        { Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names @('desktop', 'laptop') -Preferred 'server' } |
            Should -Throw '*desktop, laptop*'
    }

    It 'answers nothing when the flake has none of that kind' {
        Resolve-ConfigurationName -Kind 'windowsHomeConfiguration' -Names @() -Preferred 'me@desktop' |
            Should -BeNullOrEmpty
    }
}

Describe 'New-DistroScript' {
    It 'writes a LF, BOM-less script that fails on the first error' {
        $path = New-DistroScript -Lines @('echo one', 'echo two')
        try {
            $bytes = [IO.File]::ReadAllBytes($path)
            # A BOM would reach bash as part of the first line.
            $bytes[0] | Should -Be ([byte]0x73)   # 's' of "set"
            $bytes -contains [byte]13 | Should -BeFalse
            $text = [IO.File]::ReadAllText($path)
            $text.Split("`n")[0] | Should -Be 'set -euo pipefail'
            $text | Should -BeLike "*echo one`necho two*"
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-DefaultImageUrl' {
    BeforeAll { $SavedArch = $env:PROCESSOR_ARCHITECTURE }
    AfterAll { $env:PROCESSOR_ARCHITECTURE = $SavedArch }

    It 'picks the image for this architecture' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Get-DefaultImageUrl | Should -BeLike '*/latest/download/nixos.wsl'
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        Get-DefaultImageUrl | Should -BeLike '*/latest/download/nixos.aarch64.wsl'
    }
}

Describe 'the recorded run' {
    BeforeEach {
        Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'starts with nothing done' {
        $state = Read-State
        @($state.completed).Count | Should -Be 0
        Test-PhaseDone -State $state -Name 'prereqs' | Should -BeFalse
    }

    It 'remembers a finished phase across a reboot' {
        $state = Read-State
        Set-PhaseDone -State $state -Name 'prereqs'
        Set-PhaseDone -State $state -Name 'wsl-feature'

        $resumed = Read-State
        Test-PhaseDone -State $resumed -Name 'prereqs' | Should -BeTrue
        Test-PhaseDone -State $resumed -Name 'wsl-feature' | Should -BeTrue
        Test-PhaseDone -State $resumed -Name 'distro' | Should -BeFalse
    }

    It 'records a phase once, however often it finishes' {
        $state = Read-State
        Set-PhaseDone -State $state -Name 'prereqs'
        Set-PhaseDone -State $state -Name 'prereqs'
        @((Read-State).completed).Count | Should -Be 1
    }

    It 'carries the arguments the run was started with' {
        $state = Read-State
        Set-StateValue -State $state -Name 'Source' -Value 'https://github.com/you/config'
        Set-StateValue -State $state -Name 'flake' -Value 'C:\Users\Some One\git\config'

        $resumed = Read-State
        Get-StateValue -State $resumed -Name 'Source' | Should -Be 'https://github.com/you/config'
        Get-StateValue -State $resumed -Name 'flake' | Should -Be 'C:\Users\Some One\git\config'
        Get-StateValue -State $resumed -Name 'Distro' | Should -BeNullOrEmpty
    }

    It 'overwrites a value the second run changed' {
        $state = Read-State
        Set-StateValue -State $state -Name 'Distro' -Value 'NixOS'
        Set-StateValue -State $state -Name 'Distro' -Value 'NixOS-test'
        Get-StateValue -State (Read-State) -Name 'Distro' | Should -Be 'NixOS-test'
    }

    It 'keeps a null (a flake with no home configuration to apply)' {
        $state = Read-State
        Set-StateValue -State $state -Name 'home' -Value $null
        $resumed = Read-State
        $resumed.parameters.PSObject.Properties.Name | Should -Contain 'home'
        Get-StateValue -State $resumed -Name 'home' | Should -BeNullOrEmpty
    }
}

Describe 'Restore-RecordedArguments' {
    BeforeEach {
        Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        $Names = @('Source', 'Distro', 'SkipHome')
    }

    It 'records what the first run was given' {
        $merged = Restore-RecordedArguments -State (Read-State) -Names $Names `
            -Given @{ Source = 'https://github.com/you/config'; Distro = 'NixOS-test' }
        $merged['Source'] | Should -Be 'https://github.com/you/config'
        Get-StateValue -State (Read-State) -Name 'Distro' | Should -Be 'NixOS-test'
    }

    It 'gives a resume back the arguments it was never passed' {
        Restore-RecordedArguments -State (Read-State) -Names $Names `
            -Given @{ Source = 'C:\src\config'; Distro = 'NixOS-test' } | Out-Null

        # What -Resume looks like: nothing bound at all.
        $merged = Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{}
        $merged['Source'] | Should -Be 'C:\src\config'
        $merged['Distro'] | Should -Be 'NixOS-test'
    }

    It 'lets the run in front change its mind' {
        Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{ Source = 'C:\one' } | Out-Null
        $merged = Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{ Source = 'C:\two' }
        $merged['Source'] | Should -Be 'C:\two'
        Get-StateValue -State (Read-State) -Name 'Source' | Should -Be 'C:\two'
    }

    It 'answers nothing for an argument no run has given' {
        $merged = Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{ Source = 'C:\one' }
        $merged['Distro'] | Should -BeNullOrEmpty
    }

    It 'carries a switch through JSON as a bool, both ways' {
        Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{ SkipHome = [switch]$true } | Out-Null
        Get-StateValue -State (Read-State) -Name 'SkipHome' | Should -BeOfType [bool]
        (Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{})['SkipHome'] | Should -BeTrue

        # And -SkipHome:$false is an argument that was given, not one left out.
        Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{ SkipHome = [switch]$false } | Out-Null
        (Restore-RecordedArguments -State (Read-State) -Names $Names -Given @{})['SkipHome'] | Should -BeFalse
    }
}

Describe 'Resolve-FullPath' {
    It 'leaves a rooted path rooted' {
        Resolve-FullPath 'C:\src\config' | Should -Be 'C:\src\config'
    }

    It 'expands environment variables' {
        Resolve-FullPath '%SystemRoot%\System32' | Should -Be (Join-Path $env:SystemRoot 'System32')
    }

    It 'anchors a relative path to the working directory, not to wherever RunOnce starts' {
        Push-Location $TestDrive
        try {
            Resolve-FullPath 'config' | Should -Be (Join-Path (Get-Location).ProviderPath 'config')
        } finally {
            Pop-Location
        }
    }
}
