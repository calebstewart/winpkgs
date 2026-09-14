<#
    Win32 calls the resources need to tell the running session about a change:
    a broadcast for the environment and for fonts, and GDI's font loading; and
    the file calls .NET lacks, for the state directory. One place, so each type
    is compiled once per process.
#>

function Initialize-WinPkgsKernel32 {
    if (-not ('WinPkgs.Native.Kernel32' -as [type])) {
        Add-Type -Namespace WinPkgs.Native -Name Kernel32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool MoveFileExW(string lpExistingFileName, System.IntPtr lpNewFileName, uint dwFlags);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, System.IntPtr lpSecurityAttributes);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
[return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.I1)]
public static extern bool CreateSymbolicLinkW(string lpSymlinkFileName, string lpTargetFileName, uint dwFlags);
'@
    }
}

function Initialize-WinPkgsNative {
    if (-not ('WinPkgs.Native.User32' -as [type])) {
        Add-Type -Namespace WinPkgs.Native -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetSysColors(int cElements, int[] lpaElements, int[] lpaRgbValues);
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

function Initialize-WinPkgsSqlite {
    <#
    .SYNOPSIS
        SQLite through winsqlite3.dll, the copy every Windows 10 and 11 ships in
        System32: enough to write the index winget keeps beside a portable
        package (WinGet.Offline.ps1), and to read one back.

    .DESCRIPTION
        Paths, SQL and text are UTF-8, as SQLite wants them, marshalled by hand:
        the default ANSI marshalling would mangle a user profile path outside
        the code page. C# 5, which Windows PowerShell's compiler takes.
    #>
    if ('WinPkgs.Native.Sqlite' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WinPkgs.Native {
    public static class Sqlite {
        const string Dll = "winsqlite3.dll";
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr stmt, IntPtr tail);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_text(IntPtr stmt, int index, byte[] value, int bytes, IntPtr destructor);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_blob(IntPtr stmt, int index, byte[] value, int bytes, IntPtr destructor);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_null(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_type(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_blob(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int index);

        const int ReadWriteCreate = 0x2 | 0x4;
        const int Row = 100, Done = 101, Null = 5;
        static readonly IntPtr Transient = new IntPtr(-1);

        static byte[] Terminated(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

        // A value PowerShell handed over still wrapped, as it can: bound as
        // what it wraps, not as the wrapper's ToString().
        static object Unwrap(object v) {
            if (v == null) return null;
            Type t = v.GetType();
            if (t.FullName == "System.Management.Automation.PSObject") return t.GetProperty("BaseObject").GetValue(v, null);
            return v;
        }

        static IntPtr Open(string path, int flags) {
            IntPtr db;
            if (sqlite3_open_v2(Terminated(path), out db, flags, IntPtr.Zero) != 0) {
                string message = Error(db);
                sqlite3_close(db);
                throw new InvalidOperationException("SQLite could not open " + path + ": " + message);
            }
            return db;
        }

        static string Error(IntPtr db) {
            IntPtr p = sqlite3_errmsg(db);
            if (p == IntPtr.Zero) return "unknown error";
            int n = 0;
            while (Marshal.ReadByte(p, n) != 0) n++;
            byte[] bytes = new byte[n];
            Marshal.Copy(p, bytes, 0, n);
            return Encoding.UTF8.GetString(bytes);
        }

        static IntPtr Prepare(IntPtr db, string sql, object[] values) {
            IntPtr stmt;
            if (sqlite3_prepare_v2(db, Terminated(sql), -1, out stmt, IntPtr.Zero) != 0) {
                throw new InvalidOperationException("SQLite could not prepare '" + sql + "': " + Error(db));
            }
            if (values == null) return stmt;
            for (int i = 0; i < values.Length; i++) {
                object v = Unwrap(values[i]);
                int rc;
                if (v == null) rc = sqlite3_bind_null(stmt, i + 1);
                else if (v is byte[]) { byte[] b = (byte[])v; rc = sqlite3_bind_blob(stmt, i + 1, b, b.Length, Transient); }
                else if (v is int || v is long) rc = sqlite3_bind_int64(stmt, i + 1, Convert.ToInt64(v));
                else { byte[] t = Encoding.UTF8.GetBytes(v.ToString()); rc = sqlite3_bind_text(stmt, i + 1, t, t.Length, Transient); }
                if (rc != 0) { sqlite3_finalize(stmt); throw new InvalidOperationException("SQLite could not bind value " + (i + 1) + ": " + Error(db)); }
            }
            return stmt;
        }

        // Each statement in turn, in one connection, with its own values; the
        // file is created if it is not there.
        public static void Run(string path, string[] statements, object[][] values) {
            IntPtr db = Open(path, ReadWriteCreate);
            try {
                for (int s = 0; s < statements.Length; s++) {
                    IntPtr stmt = Prepare(db, statements[s], values == null ? null : values[s]);
                    try {
                        int rc;
                        while ((rc = sqlite3_step(stmt)) == Row) { }
                        if (rc != Done) throw new InvalidOperationException("SQLite could not run '" + statements[s] + "': " + Error(db));
                    } finally { sqlite3_finalize(stmt); }
                }
            } finally { sqlite3_close(db); }
        }

        // Every row of a query, each column as text (a blob read as UTF-8),
        // null as null.
        public static List<string[]> Query(string path, string sql) {
            List<string[]> rows = new List<string[]>();
            IntPtr db = Open(path, 0x1);
            try {
                IntPtr stmt = Prepare(db, sql, null);
                try {
                    while (sqlite3_step(stmt) == Row) {
                        int count = sqlite3_column_count(stmt);
                        string[] row = new string[count];
                        for (int c = 0; c < count; c++) {
                            if (sqlite3_column_type(stmt, c) == Null) { row[c] = null; continue; }
                            IntPtr p = sqlite3_column_blob(stmt, c);
                            int n = sqlite3_column_bytes(stmt, c);
                            byte[] bytes = new byte[n];
                            if (n > 0) Marshal.Copy(p, bytes, 0, n);
                            row[c] = Encoding.UTF8.GetString(bytes);
                        }
                        rows.Add(row);
                    }
                } finally { sqlite3_finalize(stmt); }
            } finally { sqlite3_close(db); }
            return rows;
        }
    }
}
'@
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
