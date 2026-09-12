<#
    Files that are in use when winpkgs has to replace or delete them.

    A running program's image cannot be deleted or overwritten, but it can be
    renamed -- into another directory of the same volume, too -- which is how
    updaters replace a running program. So a file that cannot be deleted is
    moved into the kind's trash directory (beside its state), and whatever
    takes its place is written. The trash is emptied at the end of every apply
    and rollback, by which time a service restarted onto its new binary has let
    go of the old one. What is still in use then -- another session running
    the old program, say -- is deleted when the machine next starts if this
    process is elevated (MoveFileEx's MOVEFILE_DELAY_UNTIL_REBOOT needs it),
    and otherwise waits for a later apply.
#>

function Get-WinPkgsTrashDir {
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)
    return Join-Path (Get-WinPkgsStateDir -Kind $Kind) 'trash'
}

function Remove-WinPkgsPath {
    <#
        Delete a file or a directory tree. Given a trash directory, a file in
        it that cannot be deleted is moved there instead and the rest deleted;
        without one, or when the move fails too (another volume), the deletion's
        own error is what is thrown.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$Trash)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        if (-not $Trash) { throw }
        $failure = $_
    }
    $item = Get-Item -LiteralPath $Path -Force
    $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force) } else { @($item) }
    New-Item -ItemType Directory -Force -Path $Trash | Out-Null
    foreach ($f in $files) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; continue } catch { }
        $aside = Join-Path $Trash ('{0}-{1}' -f [guid]::NewGuid().ToString('N').Substring(0, 12), $f.Name)
        try { [IO.File]::Move($f.FullName, $aside) } catch { throw $failure }
        Write-Host "    $($f.FullName) is in use; moved aside to be deleted once it is not"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Register-WinPkgsDeleteAtRestart {
    # The file goes when Windows next starts, before anything can open it.
    param([Parameter(Mandatory)][string]$Path)
    Initialize-WinPkgsKernel32
    # A null new name (IntPtr.Zero, not a PowerShell $null, which would arrive
    # as ""): delete. 4 = MOVEFILE_DELAY_UNTIL_REBOOT.
    if (-not [WinPkgs.Native.Kernel32]::MoveFileExW($Path, [IntPtr]::Zero, 4)) {
        throw (New-Object System.ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
}

function Clear-WinPkgsTrash {
    # Delete what is in the trash and no longer in use. What still is is
    # scheduled for deletion at the next restart when this process can do
    # that -- renamed first, so a later apply knows it is taken care of -- and
    # otherwise left for a later apply. Never fails the apply.
    param([Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)
    $trash = Get-WinPkgsTrashDir -Kind $Kind
    if (-not (Test-Path -LiteralPath $trash)) { return }
    $elevated = Test-WinPkgsElevated
    foreach ($f in @(Get-ChildItem -LiteralPath $trash -File -Force)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; continue } catch { }
        if (-not $elevated -or $f.Name.EndsWith('.at-restart')) { continue }
        try {
            $scheduled = "$($f.FullName).at-restart"
            [IO.File]::Move($f.FullName, $scheduled)
            Register-WinPkgsDeleteAtRestart -Path $scheduled
            Write-Host "[$Kind] $($f.Name) is still in use; it is deleted when Windows next starts"
        } catch {
            Write-Warning "Could not schedule $($f.FullName) for deletion: $($_.Exception.GetBaseException().Message). A later apply tries again."
        }
    }
}
