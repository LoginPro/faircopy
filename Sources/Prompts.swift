import Foundation

enum EditMode: String, CaseIterable, Identifiable {
    case fix = "Исправление"
    case style = "Стилизация"
    case translate = "Перевод"
    var id: String { rawValue }
    /// rawValue — ключ хранения (в настройках приложений), а это — подпись для интерфейса.
    var title: String {
        switch self {
        case .fix: String(localized: "Исправление")
        case .style: String(localized: "Стилизация")
        case .translate: String(localized: "Перевод")
        }
    }
    var icon: String {
        switch self {
        case .fix: "text.magnifyingglass"
        case .style: "wand.and.stars"
        case .translate: "character.bubble"
        }
    }
}

/// Язык промптов и стандартных стилей — тот же, что у интерфейса.
/// `FAIRCOPY_LANG=en|ru` переопределяет его (для проверки из терминала).
enum Lang {
    static let isEnglish: Bool = {
        if let forced = ProcessInfo.processInfo.environment["FAIRCOPY_LANG"] { return forced == "en" }
        return Bundle.main.preferredLocalizations.first == "en"
    }()

    /// Ключ набора в shared/prompts.json и shared/styles.json.
    static var code: String { isEnglish ? "en" : "ru" }
}

/// Сборка сообщений для модели. Тексты промптов — в shared/prompts.json, здесь только логика.
enum Prompts {
    static var languages: [String] { Shared.prompts.languages }

    private static var pack: PromptPack { Shared.pack }

    /// Общая обёртка для любого стиля: сама инструкция стиля задаётся пользователем,
    /// а неизменные правила (не отвечать на текст, выводить только результат) — в шаблоне.
    static func styleSystem(_ style: Style) -> String {
        Shared.fill(pack.style.system.value, ["instruction": style.prompt])
    }

    /// Личный словарь: имена, ники, термины, которые модель не должна «исправлять».
    static func dictionaryNote(_ words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let d = pack.dictionary
        let list = words.map { Shared.fill(d.word, ["word": $0]) }.joined(separator: d.separator)
        return "\n\n" + Shared.fill(d.note, ["words": list])
    }

    /// Примеры для few-shot: маленькие модели гораздо точнее держат формат,
    /// когда видят пару «до → после», а не только инструкцию.
    private static func fewShot(_ system: String, _ examples: [(String, String)], _ text: String) -> [ChatMessage] {
        func wrap(_ t: String) -> String { Shared.fill(Shared.prompts.input, ["text": t]) }
        var m = [ChatMessage(role: "system", content: system)]
        for (src, dst) in examples {
            m.append(.init(role: "user", content: wrap(src)))
            m.append(.init(role: "assistant", content: dst))
        }
        m.append(.init(role: "user", content: wrap(text)))
        return m
    }

    static func messages(mode: EditMode, style: Style?, language: String, translateStyle: Style? = nil,
                         text: String, dictionary: [String] = []) -> [ChatMessage] {
        let dict = dictionaryNote(dictionary)
        switch mode {
        case .fix:
            return fewShot(pack.fix.system.value + dict, pack.fix.examples.map { ($0.input, $0.output) }, text)
        case .style:
            let s = style ?? Style.adHoc("")
            return fewShot(styleSystem(s) + dict, s.examples.map { ($0.input, $0.output) }, text)
        case .translate:
            let t = pack.translate
            let tone = translateStyle.map { Shared.fill(t.styledTone, ["instruction": $0.prompt]) } ?? t.keepTone
            let sys = Shared.fill(t.system.value, ["language": language, "tone": tone])
            return fewShot(sys + dict, [], text)
        }
    }

    /// Просьба коротко объяснить каждую правку — для подсказок при наведении в окне редактора.
    /// Объяснения — на языке интерфейса, правила — того языка, на котором текст.
    static func explainMessages(original: String, result: String, changes: [(String, String)]) -> [ChatMessage] {
        let e = pack.explain
        let list = changes.enumerated().map { i, c in
            let from = c.0.trimmingCharacters(in: .whitespaces), to = c.1.trimmingCharacters(in: .whitespaces)
            return Shared.fill(e.edit, ["n": "\(i + 1)", "from": from.isEmpty ? e.empty : from,
                                        "to": to.isEmpty ? e.empty : to])
        }.joined(separator: "\n")
        let user = Shared.fill(e.user.value, ["original": original, "result": result, "edits": list])
        return [.init(role: "system", content: e.system.value), .init(role: "user", content: user)]
    }

    static func parseExplanations(_ raw: String, count: Int) -> [String]? {
        guard let a = raw.firstIndex(of: "["), let b = raw.lastIndex(of: "]"), a < b,
              let arr = try? JSONDecoder().decode([String].self, from: Data(raw[a...b].utf8)) else { return nil }
        return Array(arr.prefix(count))
    }

    /// Убирает рассуждения (<think>…</think>) и случайно повторённые моделью теги.
    static func clean(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex) // ещё «думает»
            }
        }
        s = s.replacingOccurrences(of: "<text>", with: "")
             .replacingOccurrences(of: "</text>", with: "")
        // служебные токены модели вроде «<audio|>» или «<|channel>», изредка просачивающиеся в текст
        s = s.replacingOccurrences(of: #"<\|?[a-z_]+\|?>"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
