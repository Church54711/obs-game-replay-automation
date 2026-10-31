local cdef_ok, cdef_error = pcall(ffi.cdef, [[
typedef void *HWND;
typedef void *HANDLE;
typedef void *HMONITOR;
typedef int BOOL;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef long LONG;
typedef struct tagRECT {
	long left;
	long top;
	long right;
	long bottom;
} RECT;
typedef struct tagMONITORINFO {
	DWORD cbSize;
	RECT rcMonitor;
	RECT rcWork;
	DWORD dwFlags;
} MONITORINFO;

HWND GetForegroundWindow(void);
BOOL IsWindowVisible(HWND hWnd);
BOOL IsIconic(HWND hWnd);
int GetWindowTextLengthW(HWND hWnd);
int GetWindowTextW(HWND hWnd, wchar_t *lpString, int nMaxCount);
int GetClassNameW(HWND hWnd, wchar_t *lpClassName, int nMaxCount);
DWORD GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);
BOOL GetWindowRect(HWND hWnd, RECT *lpRect);
int GetSystemMetrics(int nIndex);
HMONITOR MonitorFromWindow(HWND hwnd, DWORD dwFlags);
BOOL GetMonitorInfoW(HMONITOR hMonitor, MONITORINFO *lpmi);

HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
BOOL CloseHandle(HANDLE hObject);
BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, wchar_t *lpExeName, DWORD *lpdwSize);
BOOL GetExitCodeProcess(HANDLE hProcess, DWORD *lpExitCode);
DWORD GetLastError(void);
unsigned long long GetTickCount64(void);
DWORD GetFileAttributesW(const wchar_t *lpFileName);
DWORD ExpandEnvironmentStringsW(const wchar_t *lpSrc, wchar_t *lpDst, DWORD nSize);
int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t *lpWideCharStr, int cchWideChar, char *lpMultiByteStr, int cbMultiByte, const char *lpDefaultChar, BOOL *lpUsedDefaultChar);
]])

if not cdef_ok and not tostring(cdef_error):find("attempt to redefine", 1, true) then
	error(cdef_error)
end

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local null = ffi.cast("void *", 0)

local CP_UTF8 = 65001
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local STILL_ACTIVE = 259
local MONITOR_DEFAULTTONEAREST = 2
local SM_CXSCREEN = 0
local SM_CYSCREEN = 1
