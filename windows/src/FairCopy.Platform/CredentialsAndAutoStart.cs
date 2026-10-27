using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using static FairCopy.Platform.Native;

namespace FairCopy.Platform;

/// Токен LM Studio — в Диспетчере учётных данных Windows (аналог Связки ключей), а не в settings.json.
public static class Credentials
{
    const string Target = "FairCopy/lmstudio-token";

    public static string? ReadToken()
    {
        if (!CredRead(Target, CRED_TYPE_GENERIC, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            if (c.CredentialBlobSize == 0) return null;
            var bytes = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally { CredFree(p); }
    }

    /// Пустое значение удаляет токен. false — Windows не дала сохранить.
    public static bool WriteToken(string? token)
    {
        if (string.IsNullOrEmpty(token))
        {
            CredDelete(Target, CRED_TYPE_GENERIC, 0);
            return true;
        }
        var bytes = Encoding.UTF8.GetBytes(token);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var c = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC, TargetName = Target, UserName = "lmstudio",
                CredentialBlob = blob, CredentialBlobSize = (uint)bytes.Length, Persist = CRED_PERSIST_LOCAL_MACHINE,
            };
            return CredWrite(ref c, 0);
        }
        finally { Marshal.FreeHGlobal(blob); }
    }
}

/// «Запускать при входе»: значение в HKCU\...\Run.
public static class AutoStart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "FairCopy";

    static string Command => $"\"{Environment.ProcessPath}\"";

    public static bool Enabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(Name) is string v && v == Command;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            if (value) k.SetValue(Name, Command);
            else k.DeleteValue(Name, throwOnMissingValue: false);
        }
    }
}
