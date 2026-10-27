using System.Runtime.InteropServices;
using System.Text;

namespace FairCopy.Platform;

/// Вызовы Win32, которые нужны приложению. Только то, что используется.
static class Native
{
    // окна и сообщения

    public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEX
    {
        public uint cbSize, style;
        public WndProc lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern ushort RegisterClassEx(ref WNDCLASSEX wc);

    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, uint style, int x, int y, int w, int h,
                                               IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32")] public static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32")] public static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);

    public const uint WS_POPUP = 0x80000000;
    public const int WS_EX_TOOLWINDOW = 0x80;
    public const uint WM_NULL = 0, WM_SETTINGCHANGE = 0x1A, WM_CONTEXTMENU = 0x7B, WM_HOTKEY = 0x312,
                      WM_POWERBROADCAST = 0x218, WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205, WM_APP = 0x8000;
    public const int PBT_APMRESUMEAUTOMATIC = 0x12;

    // хоткеи

    [DllImport("user32", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public const uint MOD_NOREPEAT = 0x4000;

    // клавиатура

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion u; }

    public const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 2;

    [DllImport("user32", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32")] public static extern uint MapVirtualKey(uint code, uint mapType);

    // буфер обмена

    [DllImport("user32", SetLastError = true)] public static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32")] public static extern bool CloseClipboard();
    [DllImport("user32")] public static extern bool EmptyClipboard();
    [DllImport("user32")] public static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32")] public static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32")] public static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32")] public static extern IntPtr GlobalLock(IntPtr mem);
    [DllImport("kernel32")] public static extern bool GlobalUnlock(IntPtr mem);
    [DllImport("kernel32")] public static extern UIntPtr GlobalSize(IntPtr mem);
    [DllImport("kernel32")] public static extern IntPtr GlobalFree(IntPtr mem);
    public const uint CF_UNICODETEXT = 13, GMEM_MOVEABLE = 2;

    // активное окно и его процесс

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize, flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32")] public static extern bool MessageBeep(uint type);
    [DllImport("kernel32")] public static extern uint GetCurrentProcessId();
    [DllImport("kernel32", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32", CharSet = CharSet.Unicode)]
    public static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    // слежение за активным окном

    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hWnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32")]
    public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32")] public static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
    public const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0;

    // значок в трее и его меню

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32", CharSet = CharSet.Unicode)] public static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATA data);
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_INFO = 0x10, NIF_SHOWTIP = 0x80;
    public const uint NIIF_INFO = 1, NIIF_WARNING = 2, NIIF_ERROR = 3;
    public const uint NOTIFYICON_VERSION_4 = 4, NIN_SELECT = 0x400, NIN_KEYSELECT = 0x401;

    [DllImport("user32")] public static extern IntPtr CreatePopupMenu();
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32")] public static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32")] public static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hWnd, IntPtr tpm);
    public const uint MF_STRING = 0, MF_GRAYED = 1, MF_CHECKED = 8, MF_POPUP = 0x10, MF_SEPARATOR = 0x800;
    public const uint TPM_RIGHTBUTTON = 2, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100, TPM_BOTTOMALIGN = 0x20;

    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32")] public static extern int GetSystemMetrics(int index);
    public const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10;
    public const int SM_CXSMICON = 49;

    // Диспетчер учётных данных

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);
    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32")] public static extern void CredFree(IntPtr buffer);
    public const uint CRED_TYPE_GENERIC = 1, CRED_PERSIST_LOCAL_MACHINE = 2;
}
