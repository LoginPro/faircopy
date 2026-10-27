using System.Diagnostics;
using System.Text;
using Interop.UIAutomationClient;
using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Окно, из которого взяли текст и куда его надо вернуть.
public sealed record TextTarget(IntPtr Window, uint ProcessId, string ExeName, string DisplayName);

/// Захват выделенного текста из активного поля и вставка результата обратно.
/// Сначала UI Automation (не трогает буфер обмена), затем Ctrl+C, затем Ctrl+A и Ctrl+C —
/// последнее нужно для поля ввода мессенджера, где ничего не выделено.
public static class TextBridge
{
    const int UIA_TextPatternId = 10014;

    // UI Automation — только с MTA-потоков пула: вызовы с потока интерфейса могут зависнуть
    static readonly Lazy<CUIAutomation8> uia = new(() => new CUIAutomation8());

    /// Активное окно (null — это окно самого FairCopy или окна нет).
    public static TextTarget? Foreground() => Describe(GetForegroundWindow());

    /// Окно и его приложение (null — окно самого FairCopy или окна нет).
    public static TextTarget? Describe(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == GetCurrentProcessId()) return null;
        var path = ProcessPath(pid);
        var exe = path is null ? "" : Path.GetFileName(path).ToLowerInvariant();
        string display = exe;
        try { if (path is not null && FileVersionInfo.GetVersionInfo(path).FileDescription is { Length: > 0 } d) display = d; }
        catch { }
        return new TextTarget(hwnd, pid, exe, display);
    }

    static string? ProcessPath(uint pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
        }
        finally { CloseHandle(h); }
    }

    /// Делает окно снова активным (после меню значка в трее).
    public static void Activate(TextTarget target) => SetForegroundWindow(target.Window);

    public static async Task<string?> GrabText()
    {
        await Keyboard.WaitForModifiersRelease();
        if (await WithTimeout(SelectedTextViaUIA) is { } s && s.Trim().Length > 0)
        {
            Log.Write($"текст взят через UI Automation ({s.Length} симв.)");
            return s;
        }
        if (await CopyViaClipboard() is { } copied) { Log.Write("текст взят через Ctrl+C"); return copied; }
        Keyboard.Ctrl(Keyboard.VK_A);
        await Task.Delay(80);
        var all = await CopyViaClipboard();
        Log.Write(all is null ? "текст не найден" : "текст взят через Ctrl+A, Ctrl+C");
        return all;
    }

    public static async Task Paste(string text, TextTarget? target)
    {
        if (target is not null && IsWindow(target.Window) && GetForegroundWindow() != target.Window)
            SetForegroundWindow(target.Window);
        await Task.Delay(150);
        var saved = Clipboard.Save();
        Clipboard.SetText(text);
        Keyboard.Ctrl(Keyboard.VK_V);
        // приложение читает буфер не сразу (Electron — с задержкой); раньше вернуть старое нельзя
        await Task.Delay(500);
        Clipboard.Restore(saved);
    }

    static async Task<string?> CopyViaClipboard()
    {
        var saved = Clipboard.Save();
        uint before = Clipboard.Sequence;
        Keyboard.Ctrl(Keyboard.VK_C);
        for (int i = 0; i < 20 && Clipboard.Sequence == before; i++) await Task.Delay(20);
        var text = Clipboard.Sequence != before ? Clipboard.GetText() : null;
        Clipboard.Restore(saved);
        return text is { } t && t.Trim().Length > 0 ? t : null;
    }

    /// Вызов UI Automation в пуле потоков с ограничением по времени: зависшее приложение
    /// не должно подвешивать FairCopy.
    static async Task<T?> WithTimeout<T>(Func<T?> f, int ms = 1500)
    {
        var task = Task.Run(() =>
        {
            try { return f(); }
            catch (Exception e) { Log.Write("UI Automation: " + e.Message); return default; }
        });
        return await Task.WhenAny(task, Task.Delay(ms)) == task ? task.Result : default;
    }

    static IUIAutomationTextRange? Selection(out IUIAutomationElement? element)
    {
        element = uia.Value.GetFocusedElement();
        if (element is null || element.CurrentIsPassword != 0) return null;
        if (element.GetCurrentPattern(UIA_TextPatternId) is not IUIAutomationTextPattern tp) return null;
        var ranges = tp.GetSelection();
        return ranges is { Length: > 0 } ? ranges.GetElement(0) : null;
    }

    static string? SelectedTextViaUIA() => Selection(out _)?.GetText(-1);

    /// Где на экране строка с курсором (физические пиксели). Сначала рамка выделения через UI Automation,
    /// затем системная каретка (GetGUIThreadInfo), затем рамка поля. null — ничего не нашлось.
    public static async Task<(int X, int Y, int Width, int Height)?> FocusedTextRect()
    {
        var viaUia = await WithTimeout<(int, int, int, int)?>(() =>
        {
            var range = Selection(out var element);
            if (range?.GetBoundingRectangles() is double[] { Length: >= 4 } r)
            {
                // по четыре числа на строку; берём последнюю — там курсор
                int i = r.Length - 4;
                return ((int)r[i], (int)r[i + 1], (int)r[i + 2], (int)r[i + 3]);
            }
            if (element is not null)
            {
                var b = element.CurrentBoundingRectangle;
                if (b.bottom > b.top) return (b.left, b.top, b.right - b.left, b.bottom - b.top);
            }
            return null;
        });
        if (viaUia is { } u && u.Item4 > 0) return u;

        var hwnd = GetForegroundWindow();
        var info = new GUITHREADINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<GUITHREADINFO>() };
        if (GetGUIThreadInfo(GetWindowThreadProcessId(hwnd, out _), ref info) && info.hwndCaret != IntPtr.Zero)
        {
            var p = new POINT { X = info.rcCaret.Left, Y = info.rcCaret.Top };
            ClientToScreen(info.hwndCaret, ref p);
            return (p.X, p.Y, Math.Max(1, info.rcCaret.Right - info.rcCaret.Left), info.rcCaret.Bottom - info.rcCaret.Top);
        }
        return null;
    }

    public static (int X, int Y) CursorPosition()
    {
        GetCursorPos(out var p);
        return (p.X, p.Y);
    }
}

/// Последнее активное окно другого приложения. Щелчок по значку в трее делает активной панель задач,
/// поэтому пункты меню «Исправить…» работают с окном, которое было активным до неё.
public sealed class ForegroundTracker : IDisposable
{
    readonly WinEventProc proc; // держим ссылку, иначе сборщик мусора уберёт делегат
    readonly IntPtr hook;
    public TextTarget? Last { get; private set; }

    /// Окна оболочки: панель задач, область уведомлений, меню «Пуск».
    static readonly HashSet<string> shellClasses =
        ["Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
         "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "#32768"];

    public ForegroundTracker()
    {
        proc = (_, _, hWnd, _, _, _, _) => Remember(hWnd);
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, WINEVENT_OUTOFCONTEXT);
        Remember(GetForegroundWindow());
    }

    void Remember(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return;
        var cls = new StringBuilder(256);
        GetClassName(hWnd, cls, cls.Capacity);
        if (shellClasses.Contains(cls.ToString())) return;
        if (TextBridge.Describe(hWnd) is { } t) Last = t;
    }

    public void Dispose() => UnhookWinEvent(hook);
}
