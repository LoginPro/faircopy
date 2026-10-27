using System.Runtime.InteropServices;
using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Синтетические нажатия (Ctrl+C, Ctrl+V, Ctrl+A) через SendInput.
/// Ограничение Windows (UIPI): в окно программы, запущенной от администратора, ввод не дойдёт.
public static class Keyboard
{
    public const ushort VK_A = 0x41, VK_C = 0x43, VK_V = 0x56;
    const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    static bool IsDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    /// Хоткей срабатывает, пока Ctrl/Alt ещё зажаты — ждём отпускания, иначе Ctrl+C превратится в Ctrl+Alt+C.
    public static async Task WaitForModifiersRelease()
    {
        for (int i = 0; i < 50; i++)
        {
            if (!IsDown(VK_CONTROL) && !IsDown(VK_MENU) && !IsDown(VK_SHIFT) && !IsDown(VK_LWIN) && !IsDown(VK_RWIN)) return;
            await Task.Delay(20);
        }
    }

    /// Ctrl + клавиша.
    public static void Ctrl(ushort key) => Send([Key(VK_CONTROL, false), Key(key, false), Key(key, true), Key(VK_CONTROL, true)]);

    static INPUT Key(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)MapVirtualKey(vk, 0), dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };

    static void Send(INPUT[] inputs)
    {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length) Log.Write($"SendInput: отправлено {sent} из {inputs.Length}, ошибка {Marshal.GetLastWin32Error()}");
    }

    public static void Beep() => MessageBeep(0x30); // MB_ICONWARNING — как NSSound.beep
}
