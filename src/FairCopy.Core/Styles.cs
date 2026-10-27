using System.Text.Json;
using System.Text.Json.Serialization;

namespace FairCopy;

/// Стиль переписывания. Хранится в JSON, поэтому стандартные стили можно править и удалять,
/// а свои — создавать в «Настройки → Стили».
public sealed class Style
{
    public sealed class Example
    {
        /// В shared/styles.json у примеров нет id — выдаём новый.
        public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
        public string Input { get; set; } = "";
        public string Output { get; set; } = "";
    }

    public string Id { get; set; } = "";
    public string Emoji { get; set; } = "";
    public string Name { get; set; } = "";
    /// Инструкция для модели: как именно переписать текст.
    /// В shared/styles.json длинная инструкция записана массивом строк.
    [JsonConverter(typeof(PromptTextConverter))] public string Prompt { get; set; } = "";
    /// Пары «до → после» (few-shot). Необязательны, но заметно повышают точность.
    public List<Example> Examples { get; set; } = [];

    /// Разовый стиль из поля «Свой стиль» в окне редактора.
    public const string CustomID = "custom";

    public static Style AdHoc(string description) => new()
    {
        Id = CustomID,
        Emoji = "✍️",
        Name = Lang.T("Свой стиль", "Custom"),
        Prompt = description.Length == 0
            ? Shared.Pack.Style.CustomEmpty
            : Shared.Fill(Shared.Pack.Style.Custom, new Dictionary<string, string> { ["description"] = description }),
    };

    public Style Clone() => new()
    {
        Id = Id, Emoji = Emoji, Name = Name, Prompt = Prompt,
        Examples = Examples.Select(e => new Example { Id = e.Id, Input = e.Input, Output = e.Output }).ToList(),
    };
}

/// Стили пользователя: %APPDATA%\FairCopy\styles.json. Пока файла нет — стандартный набор.
public sealed class StyleStore
{
    public static readonly StyleStore Shared = new();

    /// Любое изменение списка (интерфейс подписывается и перерисовывается).
    public event Action? Changed;

    List<Style> styles;
    public IReadOnlyList<Style> Styles => styles;

    readonly string path = Path.Combine(AppPaths.Data, "styles.json");

    StyleStore()
    {
        try { styles = JsonSerializer.Deserialize<List<Style>>(File.ReadAllText(path), FairCopy.Shared.Json) ?? Defaults; }
        catch { styles = Defaults; }
    }

    void Save()
    {
        Directory.CreateDirectory(AppPaths.Data);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(styles, FairCopy.Shared.Json));
        File.Move(tmp, path, overwrite: true);
        Changed?.Invoke();
    }

    public Style? Find(string? id) => styles.FirstOrDefault(s => s.Id == id);

    public Style? FindByName(string name) =>
        styles.FirstOrDefault(s => string.Equals(s.Name, name, StringComparison.CurrentCultureIgnoreCase));

    public Style Add(Style? style = null)
    {
        var s = style ?? new Style
        {
            Id = Guid.NewGuid().ToString().ToUpperInvariant(), Emoji = "✨",
            Name = Lang.T("Новый стиль", "New Style"), Prompt = NewStylePrompt,
        };
        styles.Add(s);
        Save();
        return s;
    }

    /// Сохраняет правку стиля (стиль ищется по id).
    public void Update(Style style)
    {
        int i = styles.FindIndex(s => s.Id == style.Id);
        if (i < 0) return;
        styles[i] = style;
        Save();
    }

    public static string NewStylePrompt => FairCopy.Shared.Pack.Style.NewStyle;

    public void Delete(string id) { styles.RemoveAll(s => s.Id == id); Save(); }

    public void Move(string id, int offset)
    {
        int i = styles.FindIndex(s => s.Id == id), j = i + offset;
        if (i < 0 || j < 0 || j >= styles.Count) return;
        (styles[i], styles[j]) = (styles[j], styles[i]);
        Save();
    }

    public static bool IsBuiltin(string id) => AllDefaults.Any(d => d.Id == id);

    /// Стандартный стиль не «изменён», если совпадает с исходником на любом из языков
    /// (стили, созданные при русском интерфейсе, остаются русскими после смены языка).
    public static bool IsModified(Style style)
    {
        var originals = AllDefaults.Where(d => d.Id == style.Id).ToList();
        if (originals.Count == 0) return false;
        return !originals.Any(d => d.Emoji == style.Emoji && d.Name == style.Name && d.Prompt == style.Prompt
            && d.Examples.Select(e => (e.Input, e.Output)).SequenceEqual(style.Examples.Select(e => (e.Input, e.Output))));
    }

    /// Возвращает один стандартный стиль к исходному виду.
    public void Reset(string id)
    {
        var d = Defaults.FirstOrDefault(s => s.Id == id);
        int i = styles.FindIndex(s => s.Id == id);
        if (d is null || i < 0) return;
        styles[i] = d;
        Save();
    }

    /// Восстанавливает все стандартные стили (в том числе удалённые); свои стили остаются в конце.
    public void RestoreDefaults()
    {
        styles = [.. Defaults, .. styles.Where(s => !IsBuiltin(s.Id))];
        Save();
    }

    // стандартный набор (shared/styles.json, на языке интерфейса); копия — чтобы правки не портили исходник

    public static List<Style> Defaults =>
        (FairCopy.Shared.Styles.Locales.GetValueOrDefault(Lang.Code) ?? FairCopy.Shared.Styles.Locales.GetValueOrDefault("en") ?? [])
            .Select(s => s.Clone()).ToList();

    /// Стандартные стили на всех языках: стиль, созданный при русском интерфейсе,
    /// остаётся «стандартным» и после переключения на английский.
    public static IEnumerable<Style> AllDefaults => FairCopy.Shared.Styles.Locales.Values.SelectMany(l => l);
}

public static class AppPaths
{
    /// %APPDATA%\FairCopy (на macOS при проверке ядра — ~/.config/FairCopy).
    /// `FAIRCOPY_DATA` подменяет папку — для тестов, чтобы не трогать настройки пользователя.
    public static readonly string Data = Environment.GetEnvironmentVariable("FAIRCOPY_DATA")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FairCopy");
}
