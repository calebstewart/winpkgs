<#
    Win32 calls the resources need to tell the running session about a change:
    a broadcast for the environment and for fonts, and GDI's font loading. One
    place, so each type is compiled once per process.
#>

function Initialize-WinPkgsNative {
    if (-not ('WinPkgs.Native.User32' -as [type])) {
        Add-Type -Namespace WinPkgs.Native -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    if (-not ('WinPkgs.Native.Gdi32' -as [type])) {
        Add-Type -Namespace WinPkgs.Native -Name Gdi32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("gdi32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int AddFontResourceW(string lpszFilename);
[System.Runtime.InteropServices.DllImport("gdi32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool RemoveFontResourceW(string lpszFilename);
'@
    }
}

function Send-WinPkgsBroadcast {
    # HWND_BROADCAST with SMTO_ABORTIFHUNG: a hung window cannot stall the apply.
    # Best effort; a failure is not the resource's failure.
    param([Parameter(Mandatory)][uint32]$Message, $Param)
    try {
        Initialize-WinPkgsNative
        $result = [System.UIntPtr]::Zero
        [void][WinPkgs.Native.User32]::SendMessageTimeout([IntPtr]0xffff, $Message, [UIntPtr]::Zero, $Param, 0x0002, 5000, [ref]$result)
    } catch {
        Write-Verbose "Broadcast of message $Message failed: $($_.Exception.Message)"
    }
}
