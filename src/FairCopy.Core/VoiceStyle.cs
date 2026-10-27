using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace FairCopy;

/// «Мой стиль»: стиль, собранный из сообщений самого пользователя.
/// Модель не дообучается — вместо этого она (1) описывает манеру автора как инструкцию
/// и (2) получает примеры «нейтральный пересказ → как написал автор» (обратный перевод),
/// по которым копирует его речь в новых текстах. Всё считается локально.
public sealed partial class VoiceStyleBuilder
{
    public sealed record Sender(string Id, string Name, int Count);

    public string PastedText { get; set; } = "";
    public string? ImportedFile { get; private set; }
    public List<Sender> Senders { get; private set; } = [];
    public string? SenderID { get; set; }
    public string Name { get; set; } = Lang.T("Мой стиль", "My Voice");
    public string? Error { get; private set; }

    /// Ход построения для интерфейса (null — закончили).
    public event Action<string?>? Progress;

    List<(string Sender, string Text)> importedMessages = [];

    /// Сообщения, по которым будет строиться стиль.
    public List<string> Messages
    {
        get
        {
            IEnumerable<string> source = ImportedFile is not null
                ? importedMessages.Where(m => m.Sender == SenderID).Select(m => m.Text)
                // вставленный текст: каждое сообщение с новой строки (или абзацами)
                : PastedText.Split(["\r\n", "\n", "\r"], StringSplitOptions.None);
            var seen = new HashSet<string>();
            return source.Select(s => s.Trim()).Where(s => Graphemes(s) >= 3 && seen.Add(s)).ToList();
        }
    }

    static int Graphemes(string s) => new StringInfo(s).LengthInTextElements;

    // импорт экспорта Telegram (Telegram Desktop → Экспорт истории чата → JSON или HTML)

    /// Принимает result.json, любой messages*.html или саму папку экспорта.
    public void ImportExport(string path)
    {
        bool isDir = Directory.Exists(path);
        var dir = isDir ? path : Path.GetDirectoryName(path)!;
        if (Path.GetExtension(path).Equals(".json", StringComparison.OrdinalIgnoreCase))
            ImportTelegram(path);
        else if (isDir && File.Exists(Path.Combine(dir, "result.json")))
            ImportTelegram(Path.Combine(dir, "result.json"));
        else
            ImportTelegramHTML(dir);
    }

    public void ImportTelegram(string path)
    {
        Error = null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = doc.RootElement;
            // один чат: {messages: [...]}; полный экспорт: {chats: {list: [{messages: [...]}]}}
            var raw = new List<JsonElement>();
            if (root.TryGetProperty("messages", out var ms) && ms.ValueKind == JsonValueKind.Array) raw.AddRange(ms.EnumerateArray());
            if (root.TryGetProperty("chats", out var chats) && chats.TryGetProperty("list", out var list))
                foreach (var chat in list.EnumerateArray())
                    if (chat.TryGetProperty("messages", out var cm)) raw.AddRange(cm.EnumerateArray());
            var msgs = new List<(string, string)>();
            var names = new Dictionary<string, string>();
            foreach (var m in raw)
            {
                if (Str(m, "type") != "message" || m.TryGetProperty("forwarded_from", out _)) continue;
                if (Str(m, "from_id") is not { } from) continue;
                var text = PlainText(m.TryGetProperty("text", out var t) ? t : default);
                if (text.Length == 0) continue;
                msgs.Add((from, text));
                if (Str(m, "from") is { } n) names[from] = n;
            }
            if (msgs.Count == 0) throw new InvalidDataException();
            importedMessages = msgs;
            ImportedFile = Path.GetFileName(path);
            Senders = Count(msgs, id => names.GetValueOrDefault(id) ?? id);
            // в полном экспорте Telegram сам говорит, кто владелец аккаунта
            if (root.TryGetProperty("personal_information", out var me) && me.TryGetProperty("user_id", out var uid))
                SenderID = "user" + uid.ToString();
            if (SenderID is null || !Senders.Any(s => s.Id == SenderID)) SenderID = Senders.FirstOrDefault()?.Id;
        }
        catch
        {
            Error = Lang.T("Не удалось прочитать экспорт. Нужен файл result.json из Telegram Desktop (формат JSON).",
                           "Couldn't read the export. Telegram Desktop's result.json (JSON format) is required.");
        }
    }

    static string? Str(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static List<Sender> Count(List<(string Sender, string Text)> msgs, Func<string, string> name) =>
        msgs.GroupBy(m => m.Sender).Select(g => new Sender(g.Key, name(g.Key), g.Count()))
            .OrderByDescending(s => s.Count).ToList();

    /// HTML-экспорт: messages.html, messages2.html … Сообщение — блок «message default clearfix»;
    /// подряд идущие сообщения одного автора помечены «joined» и имени не содержат.
    public void ImportTelegramHTML(string folder)
    {
        Error = null;
        var files = (Directory.Exists(folder) ? Directory.GetFiles(folder, "messages*.html") : [])
            .Select(Path.GetFileName).OrderBy(n => PageNumber(n!)).ToList();
        var msgs = new List<(string, string)>();
        string? chatTitle = null;
        foreach (var name in files)
        {
            string html;
            try { html = File.ReadAllText(Path.Combine(folder, name!), Encoding.UTF8); } catch { continue; }
            chatTitle ??= FirstMatch(@"<div class=""text bold"">(.*?)</div>", html);
            string? sender = null;
            foreach (var chunk in html.Split("<div class=\"message ").Skip(1))
            {
                if (!chunk.StartsWith("default clearfix")) continue; // служебные сообщения
                if (!chunk.StartsWith("default clearfix joined") &&
                    FirstMatch(@"<div class=""from_name"">(.*?)</div>", chunk) is { } from)
                    sender = from;
                // пересланное — чужая речь, а не автора
                if (sender is null || chunk.Contains("class=\"forwarded body\"")) continue;
                if (FirstMatch(@"<div class=""text"">(.*?)</div>", chunk, keepLines: true) is not { Length: > 0 } text) continue;
                msgs.Add((sender, text));
            }
        }
        if (msgs.Count == 0)
        {
            Error = Lang.T("В папке не нашлось сообщений. Нужна папка экспорта Telegram с файлами messages*.html.",
                           "No messages found in the folder. A Telegram export folder with messages*.html files is required.");
            return;
        }
        importedMessages = msgs;
        ImportedFile = Path.GetFileName(folder.TrimEnd('/', '\\'));
        Senders = Count(msgs, id => id);
        // в заголовке страницы — имя собеседника; значит, твои сообщения — от другого отправителя
        SenderID = Senders.FirstOrDefault(s => s.Name != chatTitle)?.Id ?? Senders.FirstOrDefault()?.Id;
    }

    static int PageNumber(string name) =>
        int.TryParse(name["messages".Length..^".html".Length], out var n) ? n : 1;

    /// Первое совпадение группы, очищенное от тегов и HTML-сущностей.
    static string? FirstMatch(string pattern, string text, bool keepLines = false)
    {
        var m = Regex.Match(text, pattern, RegexOptions.Singleline);
        if (!m.Success) return null;
        var s = BrTag().Replace(m.Groups[1].Value, keepLines ? "\n" : " ");
        s = AnyTag().Replace(s, "");
        return WebUtility.HtmlDecode(s).Replace(' ', ' ').Trim();
    }

    [GeneratedRegex(@"<br\s*/?>")] private static partial Regex BrTag();
    [GeneratedRegex("<[^>]+>")] private static partial Regex AnyTag();

    public void ClearImport()
    {
        ImportedFile = null;
        importedMessages = [];
        Senders = [];
        SenderID = null;
    }

    /// Текст сообщения в экспорте — строка или массив из строк и объектов {type, text}.
    static string PlainText(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString()!,
        JsonValueKind.Array => string.Concat(v.EnumerateArray().Select(p =>
            p.ValueKind == JsonValueKind.String ? p.GetString() : Str(p, "text") ?? "")),
        _ => "",
    };

    // построение стиля

    public async Task<Style?> BuildAsync(LLMClient llm, CancellationToken ct = default)
    {
        var all = Messages;
        if (all.Count < 15)
        {
            Error = Lang.T($"Нужно хотя бы 15 сообщений — сейчас {all.Count}. Чем больше, тем точнее стиль.",
                           $"At least 15 messages are needed — there are {all.Count}. The more, the more accurate the style.");
            return null;
        }
        Error = null;
        try
        {
            // равномерная выборка по всей переписке, чтобы стиль не зависел от одного дня
            var analysisSample = SpreadByBudget(all, 9000);
            // формальные привычки считаем сами по всем сообщениям — на глаз модель в них ошибается
            var stats = new VoiceStats(all);
            Progress?.Invoke(Lang.T($"Изучаю манеру письма по {analysisSample.Count} сообщениям…",
                                    $"Studying the writing manner from {analysisSample.Count} messages…"));
            // описание должно быть полным списком; если модель оборвалась — пробуем ещё раз
            var description = "";
            for (int attempt = 0; attempt < 3; attempt++)
            {
                description = (await llm.CompleteAsync(AnalysisMessages(analysisSample), maxTokens: 1200,
                                                       temperature: attempt == 0 ? 0.2 : 0.4, ct: ct)).Replace("**", "");
                if (IsComplete(description)) break;
                Progress?.Invoke(Lang.T("Уточняю описание манеры…", "Refining the description…"));
            }
            description = DropRareQuotes(description, all);

            var candidates = all.Where(m => Graphemes(m) is >= 40 and <= 260).ToList();
            var picks = SpreadEven(candidates.Count == 0 ? all : candidates, 8);
            var examples = new List<Style.Example>();
            for (int i = 0; i < picks.Count; i++)
            {
                Progress?.Invoke(Lang.T($"Готовлю примеры речи: {i + 1} из {picks.Count}…",
                                        $"Preparing voice examples: {i + 1} of {picks.Count}…"));
                var neutral = await llm.CompleteAsync(NeutralizeMessages(picks[i]), maxTokens: 400, ct: ct);
                if (neutral.Length > 0 && neutral != picks[i])
                    examples.Add(new Style.Example { Input = neutral, Output = picks[i] });
            }
            var title = Name.Trim();
            return new Style
            {
                Id = Guid.NewGuid().ToString().ToUpperInvariant(), Emoji = "🗣️",
                Name = title.Length == 0 ? Lang.T("Мой стиль", "My Voice") : title,
                Prompt = description + "\n\n" + stats.Rules + "\n\n" + Moderation,
                Examples = examples,
            };
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Error = e.Message;
            return null;
        }
        finally { Progress?.Invoke(null); }
    }

    [GeneratedRegex("«([^»]+)»|\"([^\"]+)\"|“([^”]+)”")] private static partial Regex Quote();

    /// Модель иногда «находит» словечко в одном сообщении или выдумывает ему значение.
    /// Оставляем пункт с цитатой, только если цитата — короткий оборот, встречающийся хотя бы в 3 сообщениях.
    public static string DropRareQuotes(string text, IReadOnlyList<string> messages)
    {
        var lowered = messages.Select(m => m.ToLower()).ToList();
        // «ёлочки» в русском описании, "прямые" и “фигурные” — в английском
        return string.Join("\n", text.Split('\n').Where(line =>
            Quote().Matches(line).All(m =>
            {
                var q = (m.Groups[1].Success ? m.Groups[1] : m.Groups[2].Success ? m.Groups[2] : m.Groups[3]).Value.ToLower();
                return q.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 3
                    && lowered.Where(l => l.Contains(q)).Take(3).Count() == 3;
            })));
    }

    /// Полное описание — хотя бы 6 пунктов и законченное последнее предложение.
    static bool IsComplete(string text)
    {
        int points = text.Split('\n').Count(l => l.TrimStart().StartsWith('-'));
        var t = text.Trim();
        return points >= 6 && t.Length > 0 && ".!?»)\"”".Contains(t[^1]);
    }

    /// Берёт сообщения равномерно по всему списку, пока не кончится бюджет символов.
    static List<string> SpreadByBudget(List<string> items, int budgetChars)
    {
        int step = Math.Max(1, items.Count / Math.Max(1, budgetChars / 60));
        var out_ = new List<string>();
        int used = 0;
        for (int i = 0; i < items.Count; i += step)
        {
            var m = PrefixGraphemes(items[i], 300);
            int len = Graphemes(m);
            if (used + len > budgetChars) break;
            out_.Add(m); used += len;
        }
        return out_;
    }

    static string PrefixGraphemes(string s, int n)
    {
        var si = new StringInfo(s);
        return si.LengthInTextElements <= n ? s : si.SubstringByTextElements(0, n);
    }

    static List<string> SpreadEven(List<string> items, int count) =>
        items.Count <= count ? items : Enumerable.Range(0, count).Select(i => items[i * items.Count / count]).ToList();

    /// Без этого модель превращает стиль в пародию: вставляет все любимые словечки разом и дописывает мысли.
    public static string Moderation => Shared.Pack.Voice.Moderation;

    public static List<ChatMessage> AnalysisMessages(IEnumerable<string> sample) =>
        [new("system", Shared.Pack.Voice.Analysis), new("user", string.Join("\n", sample))];

    public static List<ChatMessage> NeutralizeMessages(string text) =>
        [new("system", Shared.Pack.Voice.Neutralize),
         new("user", Shared.Fill(Shared.Prompts.Input, new Dictionary<string, string> { ["text"] = text }))];
}

/// Точные формальные привычки, посчитанные по всем сообщениям автора.
public sealed class VoiceStats
{
    public int Count { get; }
    public int UpperStart { get; }
    public int PeriodEnd { get; }
    public int Bracket { get; }
    public int DoubleBracket { get; }
    public int Emoji { get; }
    public int Ellipsis { get; }
    public int MedianWords { get; }

    public VoiceStats(IReadOnlyList<string> messages)
    {
        // округление «от нуля», как .rounded() в Swift (Math.Round по умолчанию — банковское)
        static int Pct(int n, int total) =>
            total == 0 ? 0 : (int)Math.Round(n * 100.0 / total, MidpointRounding.AwayFromZero);
        Count = messages.Count;
        var lettered = messages.Select(FirstLetter).Where(r => r is not null).ToList();
        UpperStart = Pct(lettered.Count(r => Rune.IsUpper(r!.Value)), lettered.Count);
        var trimmed = messages.Select(m => m.Trim()).ToList();
        PeriodEnd = Pct(trimmed.Count(t => t.EndsWith('.') && !t.EndsWith("..")), Count);
        Bracket = Pct(trimmed.Count(t => t.Contains(')') && !t.Contains('(')), Count);
        DoubleBracket = Pct(trimmed.Count(t => t.Contains("))")), Count);
        Emoji = Pct(messages.Count(m => m.EnumerateRunes().Any(IsEmojiPresentation)), Count);
        Ellipsis = Pct(messages.Count(m => m.Contains("...") || m.Contains('…')), Count);
        var words = messages.Select(m => m.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length).Order().ToList();
        MedianWords = words.Count == 0 ? 0 : words[words.Count / 2];
    }

    static Rune? FirstLetter(string s)
    {
        foreach (var r in s.EnumerateRunes())
            if (Rune.IsLetter(r)) return r;
        return null;
    }

    /// Свойство Unicode Emoji_Presentation (символ по умолчанию рисуется как эмодзи).
    /// В .NET его нет — таблица диапазонов из emoji-data.txt (Unicode 15.1).
    static bool IsEmojiPresentation(Rune r)
    {
        int c = r.Value;
        foreach (var (a, b) in EmojiRanges)
        {
            if (c < a) return false;
            if (c <= b) return true;
        }
        return false;
    }

    static readonly (int, int)[] EmojiRanges =
    [
        (0x231A, 0x231B), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3), (0x25FD, 0x25FE), (0x2614, 0x2615),
        (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693), (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE),
        (0x26C4, 0x26C5), (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3), (0x26F5, 0x26F5),
        (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705), (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C),
        (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0), (0x27BF, 0x27BF),
        (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF),
        (0x1F18E, 0x1F18E), (0x1F191, 0x1F19A), (0x1F1E6, 0x1F1FF), (0x1F201, 0x1F201), (0x1F21A, 0x1F21A),
        (0x1F22F, 0x1F22F), (0x1F232, 0x1F236), (0x1F238, 0x1F23A), (0x1F250, 0x1F251), (0x1F300, 0x1F320),
        (0x1F32D, 0x1F335), (0x1F337, 0x1F37C), (0x1F37E, 0x1F393), (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3),
        (0x1F3E0, 0x1F3F0), (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E), (0x1F440, 0x1F440), (0x1F442, 0x1F4FC),
        (0x1F4FF, 0x1F53D), (0x1F54B, 0x1F54E), (0x1F550, 0x1F567), (0x1F57A, 0x1F57A), (0x1F595, 0x1F596),
        (0x1F5A4, 0x1F5A4), (0x1F5FB, 0x1F64F), (0x1F680, 0x1F6C5), (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2),
        (0x1F6D5, 0x1F6D7), (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC), (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB),
        (0x1F7F0, 0x1F7F0), (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945), (0x1F947, 0x1F9FF), (0x1FA70, 0x1FA7C),
        (0x1FA80, 0x1FA88), (0x1FA90, 0x1FABD), (0x1FABF, 0x1FAC5), (0x1FACE, 0x1FADB), (0x1FAE0, 0x1FAE8),
        (0x1FAF0, 0x1FAF8),
    ];

    /// Частота → понятное правило для модели.
    static string Rule(int p, PromptPack.Tiers tiers) => p >= 70 ? tiers.Often : p >= 25 ? tiers.Sometimes : tiers.Rarely;

    public string Rules
    {
        get
        {
            var v = Shared.Pack.Voice;
            return Shared.Fill(v.Stats, new Dictionary<string, string>
            {
                ["count"] = Count.ToString(),
                ["capitalRule"] = Rule(UpperStart, v.CapitalRule), ["capitalStart"] = UpperStart.ToString(),
                ["periodRule"] = Rule(PeriodEnd, v.PeriodRule), ["periodEnd"] = PeriodEnd.ToString(),
                ["bracket"] = Bracket.ToString(), ["doubleBracket"] = DoubleBracket.ToString(),
                ["emoji"] = Emoji.ToString(), ["ellipsis"] = Ellipsis.ToString(), ["medianWords"] = MedianWords.ToString(),
            });
        }
    }
}
