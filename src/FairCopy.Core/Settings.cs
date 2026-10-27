using System.Text.Json;

namespace FairCopy;

/// Сочетание клавиш для RegisterHotKey: виртуальный код клавиши и модификаторы MOD_*.
public sealed record HotKeySpec(int Key, int Modifiers)
{
    public const int Alt = 0x1, Control = 0x2, Shift = 0x4, Win = 0x8;
    const int VK_R = 0x52;

    public static readonly HotKeySpec EditorDefault = new(VK_R, Control | Alt);
    public static readonly HotKeySpec QuickDefault = new(VK_R, Control | Alt | Shift);

    /// Без Ctrl/Alt/Win сочетание перехватывало бы обычный набор текста.
    public bool IsUsable => (Modifiers & (Control | Alt | Win)) != 0;
}

/// Что запомнили для приложения: в каком режиме и стиле открывать редактор.
public sealed class AppPref
{
    public string Name { get; set; } = "";
    public string Mode { get; set; } = EditMode.Fix.Key();
    public string? StyleID { get; set; }
    public string? TranslateStyleID { get; set; }
    public string? Language { get; set; }

    public EditMode EditMode => EditModes.FromKey(Mode);
}

/// Настройки: %APPDATA%\FairCopy\settings.json (на macOS — UserDefaults, здесь — файл).
public sealed class AppSettings
{
    public static readonly AppSettings Shared = Load();

    static string FilePath => Path.Combine(AppPaths.Data, "settings.json");

    public string? Model { get; set; }
    /// Другой OpenAI-совместимый сервер вместо LM Studio на этом компьютере.
    public string? BaseURL { get; set; }
    public string DictionaryText { get; set; } = "";
    /// Ключ — имя exe активного окна в нижнем регистре (telegram.exe).
    public Dictionary<string, AppPref> AppPrefs { get; set; } = [];
    public bool RememberPerApp { get; set; } = true;
    public bool ExplainEdits { get; set; } = true;
    public bool Prewarm { get; set; } = true;
    public int Ttl { get; set; } = 3600;
    /// Последнее описание «Своего стиля» и язык перевода в окне редактора.
    public string CustomStyle { get; set; } = "";
    public string Language { get; set; } = "English";
    public HotKeySpec EditorHotKey { get; set; } = HotKeySpec.EditorDefault;
    public HotKeySpec QuickHotKey { get; set; } = HotKeySpec.QuickDefault;

    public static readonly (int Seconds, string Title)[] TtlOptions =
    [
        (900, Lang.T("15 минут", "15 minutes")), (1800, Lang.T("30 минут", "30 minutes")), (3600, Lang.T("1 час", "1 hour")),
        (4 * 3600, Lang.T("4 часа", "4 hours")), (7 * 24 * 3600, Lang.T("Не выгружать", "Never unload")),
    ];

    public List<string> Dictionary =>
        DictionaryText.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim(' ', '\t')).Where(s => s.Length > 0).ToList();

    static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), FairCopy.Shared.Json) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.Data);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, FairCopy.Shared.Json));
        File.Move(tmp, FilePath, overwrite: true);
    }
}
