using System.Runtime.InteropServices;
using Microsoft.Win32;
using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Пункт меню значка. Title null — разделитель.
public sealed record MenuItem(string? Title, Action? Click = null, bool Enabled = true, bool Checked = false,
                              IReadOnlyList<MenuItem>? Submenu = null)
{
    public static readonly MenuItem Separator = new((string?)null);
}

/// Значок в области уведомлений (аналог значка в строке меню macOS) с системным меню и уведомлениями.
/// Иконки — tray-white/black(-busy).ico рядом с exe: белая для тёмной панели задач, чёрная — для светлой.
public sealed class TrayIcon : IDisposable
{
    const uint CallbackMessage = WM_APP + 1;
    readonly MessageWindow window;
    readonly Func<IReadOnlyList<MenuItem>> menu;
    readonly string iconDir;
    readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    IntPtr icon;
    bool busy;
    string tooltip = "FairCopy";

    public TrayIcon(MessageWindow window, string iconDir, Func<IReadOnlyList<MenuItem>> menu)
    {
        this.window = window;
        this.iconDir = iconDir;
        this.menu = menu;
        window.On(CallbackMessage, (_, lParam) =>
        {
            uint ev = (uint)lParam & 0xFFFF;
            if (ev is WM_CONTEXTMENU or NIN_SELECT or NIN_KEYSELECT) ShowMenu();
        });
        // Проводник перезапустился — значок надо добавить заново
        window.On(taskbarCreated, (_, _) => Add());
        // сменилась тема панели задач — перекрашиваем значок
        window.On(WM_SETTINGCHANGE, (_, lParam) =>
        {
            if (lParam != IntPtr.Zero && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet") Update();
        });
        Add();
    }

    NOTIFYICONDATA Data(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd = window.Handle,
        uID = 1,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = icon,
        szTip = tooltip,
        szInfo = "",
        szInfoTitle = "",
    };

    void Add()
    {
        LoadIcon();
        var d = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIcon(NIM_ADD, ref d);
        d.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIcon(NIM_SETVERSION, ref d);
    }

    void LoadIcon()
    {
        var old = icon;
        var theme = TaskbarIsLight() ? "black" : "white";
        var file = Path.Combine(iconDir, $"tray-{theme}{(busy ? "-busy" : "")}.ico");
        int size = GetSystemMetrics(SM_CXSMICON);
        icon = LoadImage(IntPtr.Zero, file, IMAGE_ICON, size, size, LR_LOADFROMFILE);
        if (icon == IntPtr.Zero) Log.Write($"не загрузить иконку {file}: {Marshal.GetLastWin32Error()}");
        if (old != IntPtr.Zero) DestroyIcon(old);
    }

    static bool TaskbarIsLight()
    {
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    void Update()
    {
        LoadIcon();
        var d = Data(NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIcon(NIM_MODIFY, ref d);
    }

    /// Полупрозрачный значок, пока модель работает.
    public bool Busy
    {
        get => busy;
        set { if (busy != value) { busy = value; Update(); } }
    }

    public string Tooltip
    {
        get => tooltip;
        set { tooltip = value.Length > 127 ? value[..127] : value; Update(); }
    }

    /// Системное уведомление от имени значка.
    public void Notify(string title, string text, bool error = false)
    {
        var d = Data(NIF_INFO);
        d.szInfoTitle = title.Length > 63 ? title[..63] : title;
        d.szInfo = text.Length > 255 ? text[..255] : text;
        d.dwInfoFlags = error ? NIIF_WARNING : NIIF_INFO;
        Shell_NotifyIcon(NIM_MODIFY, ref d);
    }

    void ShowMenu()
    {
        var items = menu();
        var actions = new Dictionary<int, Action>();
        int nextId = 1;
        IntPtr Build(IReadOnlyList<MenuItem> list)
        {
            var h = CreatePopupMenu();
            foreach (var item in list)
            {
                if (item.Title is null) { AppendMenu(h, MF_SEPARATOR, UIntPtr.Zero, null); continue; }
                uint flags = (item.Enabled ? 0 : MF_GRAYED) | (item.Checked ? MF_CHECKED : 0);
                if (item.Submenu is { } sub)
                {
                    AppendMenu(h, flags | MF_POPUP, (UIntPtr)(ulong)Build(sub), item.Title);
                    continue;
                }
                int id = nextId++;
                if (item.Click is { } click) actions[id] = click;
                AppendMenu(h, flags | MF_STRING, (UIntPtr)id, item.Title);
            }
            return h;
        }
        var root = Build(items);
        GetCursorPos(out var p);
        // без этого меню не закрывается щелчком мимо него
        SetForegroundWindow(window.Handle);
        int chosen = TrackPopupMenuEx(root, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_BOTTOMALIGN, p.X, p.Y, window.Handle, IntPtr.Zero);
        PostMessage(window.Handle, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(root); // вложенные меню уничтожаются вместе с родительским
        if (chosen != 0 && actions.TryGetValue(chosen, out var action)) action();
    }

    public void Dispose()
    {
        var d = Data(0);
        Shell_NotifyIcon(NIM_DELETE, ref d);
        if (icon != IntPtr.Zero) DestroyIcon(icon);
    }
}
