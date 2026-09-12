function Invoke-WinPkgsRollback {
    <#
    .SYNOPSIS
        Go to a generation of one kind: by default the one before the current.

    .DESCRIPTION
        What NixOS and home-manager mean by it. Generation N's own runtime
        applies the closure generation N keeps, and N becomes the current
        generation again; nothing new is recorded. It is an apply of N's
        configuration, pruning included, so it does what applying that
        configuration would do and no more: a registry value that only a later
        generation set stays as it is. No WSL is involved. A system generation
        elevates once, like applying one.

        N's runtime runs in a child process of this host -- it is another
        version of this module -- as `winpkgs.ps1 apply -Config <its config.json>
        -Generation N`. Returns its exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [int]$Generation = 0,
        [switch]$NoRestartExplorer
    )

    if ($Generation -lt 1) {
        $current = Get-WinPkgsCurrentGeneration -Kind $Kind
        if ($current -lt 1) { throw "No current $Kind generation to go back from; see: winpkgs $Kind generations" }
        $earlier = @(Get-WinPkgsGeneration -Kind $Kind | Where-Object { $_.Generation -lt $current })
        if ($earlier.Count -eq 0) { throw "No $Kind generation before generation $current; see: winpkgs $Kind generations" }
        $Generation = $earlier[-1].Generation
    }

    $dir = Get-WinPkgsGenerationDir -Kind $Kind -Number $Generation
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'journal.json'))) {
        throw "No $Kind generation $Generation; see: winpkgs $Kind generations"
    }
    $config = Join-Path $dir 'closure\config.json'
    $entry = Join-Path $dir 'closure\runtime\winpkgs.ps1'
    if (-not (Test-Path -LiteralPath $config)) {
        throw "$Kind generation $Generation was recorded before winpkgs kept each generation's closure, so there is nothing to go back to"
    }
    if (-not (Test-Path -LiteralPath $entry)) {
        throw "$Kind generation $Generation keeps no runtime to apply it with"
    }
    if ($Kind -eq 'system') {
        foreach ($p in $dir, (Join-Path $dir 'closure')) { Assert-WinPkgsAdministratorOwned -Path $p }
    }

    $arguments = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', $entry,
        'apply', '-Config', $config, '-Generation', "$Generation")
    if ($NoRestartExplorer) { $arguments += '-NoRestartExplorer' }
    # The exit code is the answer, 3010 included, not an exception.
    $PSNativeCommandUseErrorActionPreference = $false
    & (Get-Process -Id $PID).Path @arguments | Out-Host
    return $LASTEXITCODE
}

function Assert-WinPkgsAdministratorOwned {
    # A system generation's runtime runs elevated. What it runs from must have
    # been made by an administrator -- SYSTEM, Administrators, or this user, who
    # approves the elevation anyway -- and not by another user, as %ProgramData%
    # allowed before the state directory was protected.
    param([Parameter(Mandatory)][string]$Path)
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $trusted = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($owner -notin $trusted) {
        throw "Refusing to run $Path elevated: its owner is $owner, not an administrator"
    }
}
