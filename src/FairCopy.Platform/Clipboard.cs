using System.Runtime.InteropServices;
using System.Text;
using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Буфер обмена: снимок всего содержимого и восстановление, чтобы захват и вставка текста
/// не портили то, что пользователь скопировал сам.
public static class Clipboard
{
    /// Окно-владелец для OpenClipboard (MessageWindow приложения).
    public static IntPtr Owner { get; set; }

    public sealed class Snapshot
    {
        internal readonly List<(uint Format, byte[] Data)> Items = [];
    }

    /// Форматы, данные которых — не память (GlobalAlloc), а дескрипторы GDI. Их не скопировать байтами;
    /// картинки при этом не теряются — Windows хранит их ещё и как CF_DIB.
    static readonly HashSet<uint> handleFormats = [2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E];

    public static uint Sequence => GetClipboardSequenceNumber();

    static bool Open()
    {
        // буфер может быть ненадолго занят другим приложением
        for (int i = 0; i < 25; i++)
        {
            if (OpenClipboard(Owner)) return true;
            Thread.Sleep(10);
        }
        Log.Write("буфер обмена занят другим приложением");
        return false;
    }

    public static Snapshot Save()
    {
        var s = new Snapshot();
        if (!Open()) return s;
        try
        {
            for (uint f = EnumClipboardFormats(0); f != 0; f = EnumClipboardFormats(f))
            {
                if (handleFormats.Contains(f)) continue;
                var h = GetClipboardData(f);
                if (h == IntPtr.Zero) continue;
                var p = GlobalLock(h);
                if (p == IntPtr.Zero) continue;
                try
                {
                    var data = new byte[(int)GlobalSize(h)];
                    Marshal.Copy(p, data, 0, data.Length);
                    s.Items.Add((f, data));
                }
                finally { GlobalUnlock(h); }
            }
        }
        finally { CloseClipboard(); }
        return s;
    }

    public static void Restore(Snapshot s)
    {
        if (!Open()) return;
        try
        {
            EmptyClipboard();
            foreach (var (f, data) in s.Items) Put(f, data);
            if (s.Items.Count > 0) MarkPrivate();
        }
        finally { CloseClipboard(); }
    }

    public static void SetText(string text)
    {
        if (!Open()) return;
        try
        {
            EmptyClipboard();
            Put(CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0"));
            MarkPrivate();
        }
        finally { CloseClipboard(); }
    }

    public static string? GetText()
    {
        if (!Open()) return null;
        try
        {
            var h = GetClipboardData(CF_UNICODETEXT);
            if (h == IntPtr.Zero) return null;
            var p = GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(p); }
            finally { GlobalUnlock(h); }
        }
        finally { CloseClipboard(); }
    }

    static void Put(uint format, byte[] data)
    {
        var h = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)Math.Max(1, data.Length));
        var p = GlobalLock(h);
        Marshal.Copy(data, 0, p, data.Length);
        GlobalUnlock(h);
        if (SetClipboardData(format, h) == IntPtr.Zero) GlobalFree(h); // при успехе памятью владеет система
    }

    /// Наш временный текст и возвращённое содержимое не должны попадать в журнал буфера (Win+V),
    /// облачный буфер и менеджеры буфера обмена.
    static void MarkPrivate()
    {
        Put(RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing"), [0]);
        Put(RegisterClipboardFormat("CanIncludeInClipboardHistory"), BitConverter.GetBytes(0));
        Put(RegisterClipboardFormat("CanUploadToCloudClipboard"), BitConverter.GetBytes(0));
    }
}
