using System.Runtime.InteropServices;

namespace FairCopy.App;

/// Немного Win32 для окна редактора: перетаскивание за шапку, масштаб монитора, скругление.
static class WindowNative
{
    [DllImport("user32")] static extern bool ReleaseCapture();
    [DllImport("user32")] static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("dwmapi")] static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    /// Окно без заголовка тащится за любое место шапки, как за заголовок.
    public static void BeginDrag(IntPtr hWnd)
    {
        ReleaseCapture();
        SendMessage(hWnd, 0xA1 /* WM_NCLBUTTONDOWN */, 2 /* HTCAPTION */, IntPtr.Zero);
    }

    /// Масштаб монитора в точке (1.0 = 96 dpi).
    public static double ScaleAt(int x, int y)
    {
        var m = MonitorFromPoint(new POINT { X = x, Y = y }, 2 /* MONITOR_DEFAULTTONEAREST */);
        return GetDpiForMonitor(m, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1.0;
    }

    /// Скругление углов Windows 11 и для окна без заголовка.
    public static void RoundCorners(IntPtr hWnd)
    {
        int round = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(hWnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
    }
}
