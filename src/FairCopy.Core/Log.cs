namespace FairCopy;

/// Журнал в %APPDATA%\FairCopy\log.txt (аналог NSLog Mac-версии): по нему разбираем,
/// что случилось на ПК, не видя экрана. Старый журнал при запуске уезжает в log.old.txt.
public static class Log
{
    static readonly object gate = new();
    static readonly string path = Path.Combine(AppPaths.Data, "log.txt");
    static bool rotated;

    public static void Write(string message)
    {
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(AppPaths.Data);
                if (!rotated)
                {
                    rotated = true;
                    if (File.Exists(path)) File.Move(path, Path.Combine(AppPaths.Data, "log.old.txt"), overwrite: true);
                }
                File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
            }
            catch { }
        }
    }
}
