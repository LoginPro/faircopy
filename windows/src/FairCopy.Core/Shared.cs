using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FairCopy;

/// Язык промптов и стандартных стилей — тот же, что у интерфейса.
/// `FAIRCOPY_LANG=en|ru` переопределяет его (для проверки из терминала).
/// В отличие от macOS (запасной язык — русский), здесь русский только при русском интерфейсе Windows.
public static class Lang
{
    public static readonly bool IsEnglish =
        Environment.GetEnvironmentVariable("FAIRCOPY_LANG") is { } forced
            ? forced == "en"
            : CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "ru";

    /// Ключ набора в shared/prompts.json и shared/styles.json.
    public static string Code => IsEnglish ? "en" : "ru";

    /// Строка интерфейса ядра (ошибки, ход построения стиля) на нужном языке.
    public static string T(string ru, string en) => IsEnglish ? en : ru;
}

/// Промпты и стандартные стили из shared/*.json — общие для macOS- и Windows-версий.
/// Формат описан в shared/README.md. Файлы встроены в сборку как ресурсы.
public static class Shared
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    static readonly Lazy<PromptFile> prompts = new(() => Load<PromptFile>("prompts.json"));
    static readonly Lazy<StyleFile> styles = new(() => Load<StyleFile>("styles.json"));

    public static PromptFile Prompts => prompts.Value;
    public static StyleFile Styles => styles.Value;

    /// Набор промптов на языке интерфейса.
    public static PromptPack Pack => Prompts.Locales.GetValueOrDefault(Lang.Code) ?? Prompts.Locales["en"];

    static T Load<T>(string name)
    {
        using var s = typeof(Shared).Assembly.GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"В сборке нет ресурса {name}");
        return JsonSerializer.Deserialize<T>(s, Json) ?? throw new InvalidDataException(name);
    }

    /// Подставляет значения вместо `{имя}` за один проход: текст пользователя,
    /// попавший в подстановку, сам уже не разбирается (в нём тоже могут быть фигурные скобки).
    /// Неизвестные плейсхолдеры остаются как есть.
    public static string Fill(string template, IReadOnlyDictionary<string, string> values)
    {
        var out_ = new StringBuilder();
        int pos = 0;
        while (true)
        {
            int open = template.IndexOf('{', pos);
            if (open < 0) break;
            out_.Append(template, pos, open - pos);
            int after = open + 1;
            int close = template.IndexOf('}', after);
            if (close >= 0 && values.TryGetValue(template[after..close], out var value))
            {
                out_.Append(value);
                pos = close + 1;
            }
            else
            {
                out_.Append('{');
                pos = after;
            }
        }
        return out_.Append(template, pos, template.Length - pos).ToString();
    }
}

/// Многострочный промпт в JSON — массив строк (удобно читать и сравнивать в git), короткий — строка.
public sealed class PromptTextConverter : JsonConverter<string>
{
    public override string Read(ref Utf8JsonReader r, Type type, JsonSerializerOptions o)
    {
        if (r.TokenType == JsonTokenType.String) return r.GetString()!;
        return string.Join("\n", JsonSerializer.Deserialize<List<string>>(ref r, o)!);
    }

    public override void Write(Utf8JsonWriter w, string value, JsonSerializerOptions o) => w.WriteStringValue(value);
}

public sealed class PromptFile
{
    public int Format { get; init; }
    /// Как текст пользователя оборачивается в сообщение модели: `<text>{text}</text>`.
    public string Input { get; init; } = "";
    public List<string> Languages { get; init; } = [];
    public Dictionary<string, PromptPack> Locales { get; init; } = [];
}

public sealed class PromptPack
{
    public sealed class Example { public string Input { get; init; } = ""; public string Output { get; init; } = ""; }

    public sealed class FixPrompts
    {
        [JsonConverter(typeof(PromptTextConverter))] public string System { get; init; } = "";
        public List<Example> Examples { get; init; } = [];
    }

    public sealed class StylePrompts
    {
        [JsonConverter(typeof(PromptTextConverter))] public string System { get; init; } = "";
        public string Custom { get; init; } = "";
        public string CustomEmpty { get; init; } = "";
        public string NewStyle { get; init; } = "";
    }

    public sealed class DictionaryPrompts
    {
        public string Note { get; init; } = "";
        public string Word { get; init; } = "";
        public string Separator { get; init; } = "";
    }

    public sealed class TranslatePrompts
    {
        [JsonConverter(typeof(PromptTextConverter))] public string System { get; init; } = "";
        public string KeepTone { get; init; } = "";
        public string StyledTone { get; init; } = "";
    }

    public sealed class ExplainPrompts
    {
        [JsonConverter(typeof(PromptTextConverter))] public string System { get; init; } = "";
        [JsonConverter(typeof(PromptTextConverter))] public string User { get; init; } = "";
        public string Edit { get; init; } = "";
        public string Empty { get; init; } = "";
    }

    /// Правило по частоте привычки: ≥70% — often, ≥25% — sometimes, иначе rarely.
    public sealed class Tiers
    {
        public string Often { get; init; } = "";
        public string Sometimes { get; init; } = "";
        public string Rarely { get; init; } = "";
    }

    public sealed class VoicePrompts
    {
        [JsonConverter(typeof(PromptTextConverter))] public string Analysis { get; init; } = "";
        [JsonConverter(typeof(PromptTextConverter))] public string Neutralize { get; init; } = "";
        [JsonConverter(typeof(PromptTextConverter))] public string Moderation { get; init; } = "";
        [JsonConverter(typeof(PromptTextConverter))] public string Stats { get; init; } = "";
        public Tiers CapitalRule { get; init; } = new();
        public Tiers PeriodRule { get; init; } = new();
    }

    public FixPrompts Fix { get; init; } = new();
    public StylePrompts Style { get; init; } = new();
    public DictionaryPrompts Dictionary { get; init; } = new();
    public TranslatePrompts Translate { get; init; } = new();
    public ExplainPrompts Explain { get; init; } = new();
    public VoicePrompts Voice { get; init; } = new();
}

public sealed class StyleFile
{
    public int Format { get; init; }
    public Dictionary<string, List<Style>> Locales { get; init; } = [];
}
