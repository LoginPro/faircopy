using System.Text;

namespace FairCopy;

/// `--dump-prompts` — все промпты в том виде, в каком они уходят модели, на фиксированных
/// входных данных. Две реализации (macOS и Windows) с одинаковыми shared/*.json должны давать
/// байт-в-байт одинаковый вывод — так проверяется совместимость (эталон — tests/reference).
public static class PromptDump
{
    public static string Run()
    {
        var out_ = new StringBuilder();
        void Section(string title, List<ChatMessage> msgs)
        {
            out_.Append($"=== {title}\n");
            foreach (var m in msgs) out_.Append($"--- {m.Role}\n{m.Content}\n");
        }
        const string text = "привет как дела";
        string[] dict = ["FairCopy", "Гоша"];
        var defaults = StyleStore.Defaults;
        Section("fix", Prompts.Messages(EditMode.Fix, null, "", text));
        Section("fix+dictionary", Prompts.Messages(EditMode.Fix, null, "", text, dictionary: dict));
        foreach (var s in defaults)
        {
            out_.Append($"=== style {s.Id}: {s.Emoji} {s.Name}\n");
            Section($"style {s.Id}", Prompts.Messages(EditMode.Style, s, "", text));
        }
        Section("style adHoc", Prompts.Messages(EditMode.Style, Style.AdHoc("как пират"), "", text));
        Section("style adHoc empty", Prompts.Messages(EditMode.Style, Style.AdHoc(""), "", text));
        Section("translate", Prompts.Messages(EditMode.Translate, null, "Deutsch", text));
        Section("translate+style", Prompts.Messages(EditMode.Translate, null, "Deutsch", text,
                                                    translateStyle: defaults[1], dictionary: dict));
        Section("explain", Prompts.ExplainMessages("its ok", "It's ok.", [("its", "It's"), ("", "."), (" ", "")]));
        Section("voice analysis", VoiceStyleBuilder.AnalysisMessages(["раз", "два"]));
        Section("voice neutralize", VoiceStyleBuilder.NeutralizeMessages("ну чё как"));
        out_.Append($"=== voice moderation\n{VoiceStyleBuilder.Moderation}\n");
        string[] samples = ["Привет)) как ты", "ок.", "Норм 👍", "ну да...", "Слушай, а давай завтра"];
        out_.Append($"=== voice stats\n{new VoiceStats(samples).Rules}\n");
        out_.Append($"=== new style\n{StyleStore.NewStylePrompt}\n");
        out_.Append($"=== languages\n{string.Join(", ", Prompts.Languages)}\n");
        return out_.ToString();
    }
}
