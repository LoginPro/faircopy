import Foundation

/// `AIEditor --dump-prompts` — печатает все промпты в том виде, в каком они уходят модели,
/// на фиксированных входных данных. Две реализации (macOS и Windows) с одинаковыми
/// shared/*.json должны давать байт-в-байт одинаковый вывод — так проверяется совместимость.
@MainActor
enum PromptDump {
    static func run() -> Never {
        var out = ""
        func section(_ title: String, _ msgs: [ChatMessage]) {
            out += "=== \(title)\n"
            for m in msgs { out += "--- \(m.role)\n\(m.content)\n" }
        }
        let text = "привет как дела"
        let dict = ["FairCopy", "Гоша"]
        section("fix", Prompts.messages(mode: .fix, style: nil, language: "", text: text))
        section("fix+dictionary", Prompts.messages(mode: .fix, style: nil, language: "", text: text, dictionary: dict))
        for s in StyleStore.defaults {
            out += "=== style \(s.id): \(s.emoji) \(s.name)\n"
            section("style \(s.id)", Prompts.messages(mode: .style, style: s, language: "", text: text))
        }
        section("style adHoc", Prompts.messages(mode: .style, style: Style.adHoc("как пират"), language: "", text: text))
        section("style adHoc empty", Prompts.messages(mode: .style, style: Style.adHoc(""), language: "", text: text))
        section("translate", Prompts.messages(mode: .translate, style: nil, language: "Deutsch", text: text))
        section("translate+style", Prompts.messages(mode: .translate, style: nil, language: "Deutsch",
                                                    translateStyle: StyleStore.defaults[1], text: text, dictionary: dict))
        section("explain", Prompts.explainMessages(original: "its ok", result: "It's ok.",
                                                   changes: [("its", "It's"), ("", "."), (" ", "")]))
        section("voice analysis", VoiceStyleBuilder.analysisMessages(["раз", "два"]))
        section("voice neutralize", VoiceStyleBuilder.neutralizeMessages("ну чё как"))
        out += "=== voice moderation\n\(VoiceStyleBuilder.moderation)\n"
        let samples = ["Привет)) как ты", "ок.", "Норм 👍", "ну да...", "Слушай, а давай завтра"]
        out += "=== voice stats\n\(VoiceStats(samples).rules)\n"
        out += "=== new style\n\(StyleStore.newStylePrompt)\n"
        out += "=== languages\n\(Prompts.languages.joined(separator: ", "))\n"
        print(out, terminator: "")
        exit(0)
    }
}
