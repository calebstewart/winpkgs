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

    # Top-level values the functions close over, taken from the file rather than
    # restated here, so a change to either is a test failure and not a drift.
    foreach ($assignment in $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false)) {
        if ($assignment.Left.Extent.Text -in '$nix', '$outputMarker') {
            . ([scriptblock]::Create($assignment.Extent.Text))
        }
    }

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

Describe 'New-DistroPreamble' {
    It 'is separate lines, and fails on the first error' {
        $lines = New-DistroPreamble
        $lines.Count | Should -BeGreaterThan 1
        $lines[0] | Should -Be 'set -euo pipefail'
    }

    It 'supplies git from nixpkgs only when the distro has none' {
        # The NixOS-WSL image has no git, and nix executes git to lock a
        # git+file flake -- which is what a cloned configuration is.
        $script = (New-DistroPreamble) -join "`n"
        $script | Should -BeLike '*command -v git*'
        $script | Should -BeLike '*shell nixpkgs#git -c*'
    }

    It 'runs the command as given when git is already there' {
        (New-DistroPreamble) -join "`n" | Should -BeLike "*then`n    `"`$@`"*"
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

Describe 'New-CloneScript' {
    # PowerShell's comma binds tighter than its plus, so an array of
    # concatenations collapses into one string unless every element is
    # parenthesised -- and a shell script on one line is a syntax error.
    It 'is a script of separate lines, not one long one' {
        $lines = New-CloneScript -Url 'https://example.com/c.git' -Destination '/mnt/c/src/c'
        $lines.Count | Should -Be 7
        $lines | ForEach-Object { $_ | Should -Not -Match "`n" }
    }

    It 'quotes the url and the destination for the shell' {
        $lines = New-CloneScript -Url 'https://example.com/c.git' -Destination '/mnt/c/Users/Some One/c'
        $lines[0] | Should -Be "url='https://example.com/c.git'"
        $lines[1] | Should -Be "dest='/mnt/c/Users/Some One/c'"
    }

    It 'falls back to nix for git, because neither the image nor Windows has one' {
        $lines = New-CloneScript -Url 'u' -Destination 'd'
        ($lines -join "`n") | Should -BeLike '*if command -v git*'
        ($lines -join "`n") | Should -BeLike '*run nixpkgs#git -- clone*'
    }

    It 'passes a ref to both branches of the fallback' {
        $lines = New-CloneScript -Url 'u' -Destination 'd' -Ref 'develop'
        @($lines | Where-Object { $_ -like "*--branch 'develop' *" }).Count | Should -Be 2
    }

    It 'omits --branch when no ref was asked for' {
        (New-CloneScript -Url 'u' -Destination 'd') -join "`n" | Should -Not -BeLike '*--branch*'
    }
}

Describe 'Select-MarkedOutput' {
    # NixOS-WSL greets every login shell until the system is first rebuilt, and
    # a login shell is the only thing that puts nix on PATH. The greeting has
    # blank lines in it, which a mandatory [string[]] would refuse outright.
    BeforeAll {
        $Motd = @(
            'Welcome to your new NixOS-WSL system!'
            ''
            'Please run `sudo nix-channel --update` now.'
            ''
        )
    }

    It 'returns only what came after the marker' {
        $lines = $Motd + @($outputMarker, '["desktop"]')
        Select-MarkedOutput -Lines $lines | Should -Be '["desktop"]'
    }

    It 'keeps a multi-line answer whole' {
        $lines = $Motd + @($outputMarker, 'one', 'two')
        Select-MarkedOutput -Lines $lines | Should -Be "one`ntwo"
    }

    It 'takes the last marker, so an echo of it in the greeting cannot win' {
        $lines = @($outputMarker, 'stale') + @($outputMarker, 'fresh')
        Select-MarkedOutput -Lines $lines | Should -Be 'fresh'
    }

    It 'is empty when the command printed nothing after the marker' {
        Select-MarkedOutput -Lines ($Motd + @($outputMarker)) | Should -Be ''
    }

    It 'falls back to everything when the marker never arrived' {
        Select-MarkedOutput -Lines @('a', 'b') | Should -Be "a`nb"
    }

    It 'accepts an empty collection' {
        Select-MarkedOutput -Lines @() | Should -Be ''
    }
}

Describe 'ConvertFrom-ChecksumText' {
    It 'reads the format NixOS-WSL publishes: digest, two spaces, filename' {
        ConvertFrom-ChecksumText "e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9  nixos.wsl`n" |
            Should -Be 'e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9'
    }

    It 'reads a bare digest' {
        ConvertFrom-ChecksumText "  abc123`r`n" | Should -Be 'abc123'
    }

    It 'answers nothing for an empty file' {
        ConvertFrom-ChecksumText '' | Should -BeNullOrEmpty
        ConvertFrom-ChecksumText "  `n" | Should -BeNullOrEmpty
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
