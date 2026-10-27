using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Невидимое окно приложения: получает хоткеи, события значка в трее, выход из сна и смену темы.
/// Обычное верхнеуровневое, а не message-only (HWND_MESSAGE): широковещательные сообщения —
/// WM_POWERBROADCAST, TaskbarCreated после перезапуска Проводника — до message-only окон не доходят.
/// Создавать на потоке интерфейса: сообщения приходят туда же.
public sealed class MessageWindow : IDisposable
{
    public IntPtr Handle { get; }

    readonly WndProc proc; // держим ссылку, иначе сборщик мусора уберёт делегат из-под Windows
    readonly Dictionary<uint, Action<IntPtr, IntPtr>> handlers = [];

    public MessageWindow()
    {
        proc = WindowProc;
        var cls = new WNDCLASSEX
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = proc,
            hInstance = GetModuleHandle(null),
            lpszClassName = "FairCopyMessageWindow",
        };
        RegisterClassEx(ref cls);
        Handle = CreateWindowEx(WS_EX_TOOLWINDOW, cls.lpszClassName, "FairCopy", WS_POPUP, 0, 0, 0, 0,
                                IntPtr.Zero, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (Handle == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx: " + System.Runtime.InteropServices.Marshal.GetLastWin32Error());
    }

    /// Обработчик сообщения (один на сообщение; повторный вызов заменяет прежний).
    public void On(uint message, Action<IntPtr, IntPtr> handler) => handlers[message] = handler;

    /// Компьютер вышел из сна.
    public void OnResume(Action action) =>
        On(WM_POWERBROADCAST, (wParam, _) => { if ((int)wParam == PBT_APMRESUMEAUTOMATIC) action(); });

    IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (handlers.TryGetValue(msg, out var h))
        {
            try { h(wParam, lParam); }
            catch (Exception e) { Log.Write($"сообщение 0x{msg:X}: {e}"); }
            if (msg != WM_POWERBROADCAST && msg != WM_SETTINGCHANGE) return IntPtr.Zero;
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public void Dispose() => DestroyWindow(Handle);
}

/// Глобальные сочетания клавиш (RegisterHotKey). Коды клавиш виртуальные: Ctrl+Alt+R срабатывает
/// и в русской раскладке.
public sealed class HotKeys
{
    readonly MessageWindow window;
    readonly Dictionary<int, Action> actions = [];

    public HotKeys(MessageWindow window)
    {
        this.window = window;
        window.On(WM_HOTKEY, (wParam, _) =>
        {
            if (actions.TryGetValue((int)wParam, out var action)) action();
        });
    }

    /// false — сочетание занято другим приложением.
    public bool Register(int id, HotKeySpec spec, Action action)
    {
        Unregister(id);
        if (!spec.IsUsable || !RegisterHotKey(window.Handle, id, (uint)spec.Modifiers | MOD_NOREPEAT, (uint)spec.Key)) return false;
        actions[id] = action;
        return true;
    }

    public void Unregister(int id)
    {
        if (actions.Remove(id)) UnregisterHotKey(window.Handle, id);
    }

    public void UnregisterAll()
    {
        foreach (var id in actions.Keys.ToList()) Unregister(id);
    }
}
