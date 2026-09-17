<#
    Not the runtime: this is the text `programs.powershell` inlines into a
    user's profile when `sudoForWindows.enableWrapper` is on. It lives under
    runtime/ so that CI parses it on Windows PowerShell 5.1, lints it, and can
    test it like anything else here -- a profile is the one file whose syntax
    errors greet the user at every prompt.

    A `sudo` for PowerShell, over Sudo for Windows (`security.sudo`). Derived
    from Microsoft's scripts/sudo.ps1 (github.com/microsoft/sudo, MIT), which
    answers the same question: sudo.exe resolves a command the way CreateProcess
    does -- PATH x PATHEXT -- so an alias, a cmdlet or a function is a name it
    cannot find, and `sudo ls` fails before anything elevates. The answer in
    both is to hand sudo.exe *this* PowerShell with the command encoded, and to
    pass a real program through untouched.

    What is different here:

      - Aliases resolve. Microsoft's classifies with `Get-Command -Type
        Application` and then `-Type Cmdlet,ExternalScript`; an alias is
        neither, so `sudo ls` throws "Cannot find 'ls'" there too.
      - Functions travel. One from a module is re-imported in the elevated
        session; one defined in the session (a profile function) is sent as its
        own source, so it does not need the profile loaded.
      - Only the arguments are elevated. Microsoft's reads $MyInvocation.Line
        and cuts it at a fixed offset, so `sudo Stop-Service x; Get-Service x`
        elevates both commands.
      - The profile is not loaded unless asked, which is the open question in
        Microsoft's header.
      - The mode is read per run: in forceNewWindow the elevated console closes
        with the command and takes the output with it, so the command goes
        through PowerShell with -NoExit even when it is a program.

    What does not cross the boundary, because the elevated command is another
    process: pipeline input, `$using:`, variables a function closed over, and
    objects -- output comes back as text. `programs.gsudo` (`Invoke-Gsudo`) is
    the way to elevate something that needs any of them.
#>

function Get-WinPkgsSudoExe {
    # System32's by full path, never `sudo` from the PATH: with gsudo ahead of
    # System32 that name is gsudo, a function named sudo would recurse into
    # itself, and a writable directory earlier on the PATH must not be able to
    # choose what gets elevated. The suite points WINPKGS_SUDO at a shim.
    if ($env:WINPKGS_SUDO) { return $env:WINPKGS_SUDO }
    return (Join-Path $env:SystemRoot 'System32\sudo.exe')
}

function Get-WinPkgsSudoMode {
    <#
        What `sudo config` set, as sudo.exe reads it per run: 0 disabled,
        1 forceNewWindow, 2 disableInput, 3 normal. $null when the value is
        absent -- a machine where sudo was never turned on.
    #>
    $key = if ($env:WINPKGS_SUDO_KEY) { $env:WINPKGS_SUDO_KEY } else { 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' }
    $value = (Get-ItemProperty -LiteralPath $key -Name Enabled -ErrorAction SilentlyContinue).Enabled
    if ($null -eq $value) { return $null }
    return [int]$value
}

function ConvertTo-WinPkgsSudoLiteral {
    <#
        One argument as PowerShell source. Everything crosses as text: a
        parameter name stays syntax, a number and a boolean keep their shape,
        and anything else becomes a single-quoted string -- which is what a
        value the caller's parser already expanded should be.
    #>
    param($Value)
    if ($Value -is [scriptblock]) { return "{$($Value.ToString())}" }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    $text = [string]$Value
    # -Parameter, -Parameter:$true and --flag are syntax, not data.
    if ($text -match '^-{1,2}[A-Za-z][-A-Za-z0-9:$.]*$') { return $text }
    return "'" + $text.Replace("'", "''") + "'"
}

function New-WinPkgsSudoPayload {
    <#
        The script the elevated PowerShell runs, as source. The working
        directory comes along (a file-system one only: another provider's drive
        may not exist over there), LASTEXITCODE starts clean so a cmdlet-only
        run does not inherit a stale code, and the last line carries the
        command's own code back out.
    #>
    param([string]$Call, [string[]]$Literals, [string]$Definitions)
    $lines = @()
    if ($PWD.Provider.Name -eq 'FileSystem') {
        $lines += "Set-Location -LiteralPath '" + $PWD.ProviderPath.Replace("'", "''") + "'"
    }
    if ($Definitions) { $lines += $Definitions }
    $lines += '$global:LASTEXITCODE = 0'
    $lines += (@($Call) + $Literals) -join ' '
    $lines += 'exit $LASTEXITCODE'
    return ($lines -join "`n")
}

function Resolve-WinPkgsSudoCommand {
    <#
        What `sudo` would run, without running it:
        @{ exe; arguments; command; error }. `command` is the source that was
        encoded, when there is one, which is what makes this testable without
        elevating anything.
    #>
    param([object[]]$Arguments, [int]$Mode, [bool]$LoadProfile)

    $exe = Get-WinPkgsSudoExe
    if (-not $Arguments -or $Arguments.Count -eq 0) {
        return @{ exe = $exe; arguments = @(); command = $null; error = $null }
    }

    $first = $Arguments[0]
    $rest = @()
    if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }
    $literals = @($rest | ForEach-Object { ConvertTo-WinPkgsSudoLiteral $_ })

    # The same host that is asking, so `sudo` in 5.1 elevates into 5.1.
    $psHost = (Get-Process -Id $PID).Path
    if (-not $psHost) {
        $psHost = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    }
    $hostArgs = @('-NoLogo')
    if (-not $LoadProfile) { $hostArgs += '-NoProfile' }
    # forceNewWindow: the new console closes with the command, so hold it open.
    if ($Mode -eq 1) { $hostArgs += '-NoExit' }

    $encode = {
        param([string]$Source)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Source))
        # A command line has a limit and the payload is one argument of it.
        # Spilling to a file would leave something writable on disk between the
        # write and the UAC prompt, for the elevated session to run; refuse instead.
        if ($encoded.Length -gt 30000) {
            return @{ exe = $exe; arguments = @(); command = $Source; error = "sudo: that command is too large to send across the elevation boundary ($($encoded.Length) characters). Put it in a script and run: sudo <script.ps1>" }
        }
        return @{
            exe       = $exe
            arguments = @($psHost) + $hostArgs + @('-EncodedCommand', $encoded)
            command   = $Source
            error     = $null
        }
    }

    # A scriptblock is the whole request, with anything after it as its $args.
    if ($first -is [scriptblock]) {
        $using = $first.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.UsingExpressionAst] }, $true)
        if ($using.Count -gt 0) {
            return @{ exe = $exe; arguments = @(); command = $null; error = 'sudo: $using: is not carried across the elevation boundary, because the elevated command runs in another process. Pass the value as an argument: sudo { param($x) ... } $value' }
        }
        return & $encode (New-WinPkgsSudoPayload -Call "& { $($first.ToString()) }" -Literals $literals -Definitions '')
    }

    $name = [string]$first
    $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
    $guard = 0
    while ($command -and $command.CommandType -eq 'Alias' -and $guard -lt 16) {
        $command = $command.ResolvedCommand
        $guard++
    }

    # Not a command in this session: hand the whole line to sudo.exe, whose own
    # words are better than ours. This is also how `sudo config --enable normal`
    # and `sudo --version` reach it.
    if (-not $command) {
        return @{ exe = $exe; arguments = @($Arguments); command = $null; error = $null }
    }

    if ($command.CommandType -eq 'Application') {
        # A program: sudo.exe finds it itself, which keeps its argument handling
        # rather than this one's. Except in forceNewWindow, where the window
        # would close on the last line of output.
        if ($Mode -ne 1) {
            return @{ exe = $exe; arguments = @(@($command.Source) + $rest); command = $null; error = $null }
        }
        $call = "& '" + $command.Source.Replace("'", "''") + "'"
        return & $encode (New-WinPkgsSudoPayload -Call $call -Literals $literals -Definitions '')
    }

    $call = if ($command.CommandType -eq 'ExternalScript') {
        "& '" + $command.Source.Replace("'", "''") + "'"
    } else {
        "& '" + $command.Name.Replace("'", "''") + "'"
    }

    $definitions = ''
    if ($command.CommandType -eq 'Function') {
        if ($command.Module) {
            $definitions = "Import-Module '" + $command.Module.Name.Replace("'", "''") + "'"
        } else {
            # Defined in this session -- a profile function, most likely. The
            # AST's own text is the definition with its header, param block and
            # attributes intact; .Definition is only the body.
            $ast = $null
            if ($command.ScriptBlock) { $ast = $command.ScriptBlock.Ast }
            if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $definitions = $ast.Extent.Text
            } else {
                $definitions = "New-Item -Path Function:\ -Name '" + $command.Name.Replace("'", "''") +
                    "' -Value {`n" + $command.Definition + "`n} | Out-Null"
            }
        }
    }

    return & $encode (New-WinPkgsSudoPayload -Call $call -Literals $literals -Definitions $definitions)
}

function Invoke-WinPkgsSudo {
    <#
        The body of the `sudo` function the profile defines. ExpectingInput is
        passed in because $MyInvocation.ExpectingInput answers for the function
        it is read in, and the one in the pipeline is `sudo` itself.

        An advanced function, so that a refusal honours -ErrorAction and a
        shell user gets a red line and a false $? rather than a stack trace.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Argument = @(),
        [switch]$ExpectingInput,
        [switch]$LoadProfile
    )

    if ($ExpectingInput) {
        Write-Error 'sudo: pipeline input is not carried across the elevation boundary, because the elevated command runs in another process. Put the whole pipeline in the elevated command: sudo { Get-Process foo | Stop-Process }'
        return
    }

    $mode = Get-WinPkgsSudoMode
    if ($null -eq $mode -or $mode -eq 0) {
        Write-Error 'sudo: Sudo for Windows is switched off on this machine. Set `security.sudo.enable = true` in the system configuration and apply it (System > Advanced in Settings is the same switch), or run gsudo instead (`security.gsudo`).'
        return
    }

    $invocation = Resolve-WinPkgsSudoCommand -Arguments $Argument -Mode $mode -LoadProfile:$LoadProfile.IsPresent
    if ($invocation.error) {
        Write-Error $invocation.error
        return
    }

    # Last statement, so $LASTEXITCODE and $? are the command's own.
    & $invocation.exe @($invocation.arguments)
}
