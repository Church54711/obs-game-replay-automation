#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$LuaLibrary = $env:LUAJIT_DLL
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrWhiteSpace($LuaLibrary)) {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\lua51.dll'),
        (Join-Path $ProjectRoot '.tools\luajit\src\lua51.dll')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $LuaLibrary = $candidate; break }
    }
}
if ([string]::IsNullOrWhiteSpace($LuaLibrary) -or -not (Test-Path -LiteralPath $LuaLibrary -PathType Leaf)) {
    throw 'LuaJIT is required for behavioral tests. Set LUAJIT_DLL to an x64 lua51.dll or install OBS Studio.'
}
if (-not ('ReplayLuaTestRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ReplayLuaTestRunner {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryW(string path);
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr luaL_newstate();
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern void luaL_openlibs(IntPtr state);
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern int luaL_loadbuffer(IntPtr state, byte[] code, UIntPtr size, string name);
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern int lua_pcall(IntPtr state, int nargs, int results, int err);
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr size);
    [DllImport("lua51", CallingConvention=CallingConvention.Cdecl)] static extern void lua_close(IntPtr state);
    public static string Run(string library, string source) {
        if (LoadLibraryW(library) == IntPtr.Zero) throw new Exception("Cannot load LuaJIT: " + Marshal.GetLastWin32Error());
        IntPtr state = luaL_newstate();
        try {
            luaL_openlibs(state);
            byte[] code = Encoding.UTF8.GetBytes(source);
            int result = luaL_loadbuffer(state, code, (UIntPtr)code.Length, "@behavior-tests");
            if (result == 0) result = lua_pcall(state, 0, 1, 0);
            UIntPtr size;
            IntPtr text = lua_tolstring(state, -1, out size);
            byte[] bytes = new byte[checked((int)size.ToUInt64())];
            if (bytes.Length > 0) Marshal.Copy(text, bytes, 0, bytes.Length);
            string message = Encoding.UTF8.GetString(bytes);
            if (result != 0) throw new Exception(message);
            return message;
        } finally { lua_close(state); }
    }
}
'@
}
$source = "local automation_source = [====[`n" + [IO.File]::ReadAllText((Join-Path $ProjectRoot 'game-replay-auto.lua')) + "`n]====]`n" +
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'compatibility-tests.lua'))
Write-Host ([ReplayLuaTestRunner]::Run([IO.Path]::GetFullPath($LuaLibrary), $source))
