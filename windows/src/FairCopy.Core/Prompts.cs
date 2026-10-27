using System.Text.Json;
using System.Text.RegularExpressions;

namespace FairCopy;

public enum EditMode { Fix, Style, Translate }

public static class EditModes
{
    /// Ключ хранения (в настройках приложений) — как у macOS-версии.
    public static string Key(this EditMode m) => m switch
    {
        EditMode.Fix => "Исправление",
        EditMode.Style => "Стилизация",
        _ => "Перевод",
    };

    public static EditMode FromKey(string? key) => key switch
    {
        "Стилизация" => EditMode.Style,
        "Перевод" => EditMode.Translate,
        _ => EditMode.Fix,
    };

    public static string Title(this EditMode m) => m switch
    {
        EditMode.Fix => Lang.T("Исправление", "Fix"),
        EditMode.Style => Lang.T("Стилизация", "Style"),
        _ => Lang.T("Перевод", "Translate"),
    };
}

public sealed record ChatMessage(string Role, string Content);

/// Сборка сообщений для модели. Тексты промптов — в shared/prompts.json, здесь только логика.
public static partial class Prompts
{
    public static IReadOnlyList<string> Languages => Shared.Prompts.Languages;

    static PromptPack Pack => Shared.Pack;

    /// Общая обёртка для любого стиля: сама инструкция стиля задаётся пользователем,
    /// а неизменные правила (не отвечать на текст, выводить только результат) — в шаблоне.
    public static string StyleSystem(Style style) =>
        Shared.Fill(Pack.Style.System, new Dictionary<string, string> { ["instruction"] = style.Prompt });

    /// Личный словарь: имена, ники, термины, которые модель не должна «исправлять».
    public static string DictionaryNote(IReadOnlyList<string> words)
    {
        if (words.Count == 0) return "";
        var d = Pack.Dictionary;
        var list = string.Join(d.Separator, words.Select(w => Shared.Fill(d.Word, new Dictionary<string, string> { ["word"] = w })));
        return "\n\n" + Shared.Fill(d.Note, new Dictionary<string, string> { ["words"] = list });
    }

    /// Примеры для few-shot: маленькие модели гораздо точнее держат формат,
    /// когда видят пару «до → после», а не только инструкцию.
    static List<ChatMessage> FewShot(string system, IEnumerable<(string, string)> examples, string text)
    {
        string Wrap(string t) => Shared.Fill(Shared.Prompts.Input, new Dictionary<string, string> { ["text"] = t });
        var m = new List<ChatMessage> { new("system", system) };
        foreach (var (src, dst) in examples)
        {
            m.Add(new("user", Wrap(src)));
            m.Add(new("assistant", dst));
        }
        m.Add(new("user", Wrap(text)));
        return m;
    }

    public static List<ChatMessage> Messages(EditMode mode, Style? style, string language, string text,
                                             Style? translateStyle = null, IReadOnlyList<string>? dictionary = null)
    {
        var dict = DictionaryNote(dictionary ?? []);
        switch (mode)
        {
            case EditMode.Fix:
                return FewShot(Pack.Fix.System + dict, Pack.Fix.Examples.Select(e => (e.Input, e.Output)), text);
            case EditMode.Style:
                var s = style ?? Style.AdHoc("");
                return FewShot(StyleSystem(s) + dict, s.Examples.Select(e => (e.Input, e.Output)), text);
            default:
                var t = Pack.Translate;
                var tone = translateStyle is { } ts
                    ? Shared.Fill(t.StyledTone, new Dictionary<string, string> { ["instruction"] = ts.Prompt })
                    : t.KeepTone;
                var sys = Shared.Fill(t.System, new Dictionary<string, string> { ["language"] = language, ["tone"] = tone });
                return FewShot(sys + dict, [], text);
        }
    }

    /// Просьба коротко объяснить каждую правку — для подсказок при наведении в окне редактора.
    /// Объяснения — на языке интерфейса, правила — того языка, на котором текст.
    public static List<ChatMessage> ExplainMessages(string original, string result, IReadOnlyList<(string From, string To)> changes)
    {
        var e = Pack.Explain;
        var list = string.Join("\n", changes.Select((c, i) =>
        {
            var from = TrimSpaces(c.From);
            var to = TrimSpaces(c.To);
            return Shared.Fill(e.Edit, new Dictionary<string, string>
            {
                ["n"] = (i + 1).ToString(),
                ["from"] = from.Length == 0 ? e.Empty : from,
                ["to"] = to.Length == 0 ? e.Empty : to,
            });
        }));
        var user = Shared.Fill(e.User, new Dictionary<string, string> { ["original"] = original, ["result"] = result, ["edits"] = list });
        return [new("system", e.System), new("user", user)];
    }

    /// Пробелы и табуляции по краям, но не переводы строк (как `.whitespaces` в Swift).
    static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && char.IsWhiteSpace(s[a]) && s[a] is not ('\n' or '\r')) a++;
        while (b > a && char.IsWhiteSpace(s[b - 1]) && s[b - 1] is not ('\n' or '\r')) b--;
        return s[a..b];
    }

    public static List<string>? ParseExplanations(string raw, int count)
    {
        int a = raw.IndexOf('['), b = raw.LastIndexOf(']');
        if (a < 0 || b <= a) return null;
        try { return JsonSerializer.Deserialize<List<string>>(raw[a..(b + 1)])?.Take(count).ToList(); }
        catch (JsonException) { return null; }
    }

    [GeneratedRegex(@"<\|?[a-z_]+\|?>")]
    private static partial Regex ServiceToken();

    /// Убирает рассуждения (<think>…</think>) и случайно повторённые моделью теги.
    public static string Clean(string raw)
    {
        var s = raw;
        int open;
        while ((open = s.IndexOf("<think>", StringComparison.Ordinal)) >= 0)
        {
            int close = s.IndexOf("</think>", open + 7, StringComparison.Ordinal);
            s = close >= 0 ? s.Remove(open, close + 8 - open) : s[..open]; // без закрывающего — ещё «думает»
        }
        s = s.Replace("<text>", "").Replace("</text>", "");
        // служебные токены модели вроде «<audio|>» или «<|channel>», изредка просачивающиеся в текст
        s = ServiceToken().Replace(s, "");
        return s.Trim();
    }
}
