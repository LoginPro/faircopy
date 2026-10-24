import Foundation

/// Стиль переписывания. Хранится в JSON, поэтому стандартные стили можно править и удалять,
/// а свои — создавать в «Настройки → Стили».
struct Style: Codable, Identifiable, Hashable {
    struct Example: Codable, Hashable, Identifiable {
        var id = UUID().uuidString
        var input: String
        var output: String
    }

    var id: String
    var emoji: String
    var name: String
    /// Инструкция для модели: как именно переписать текст.
    var prompt: String
    /// Пары «до → после» (few-shot). Необязательны, но заметно повышают точность.
    var examples: [Example] = []

    /// Разовый стиль из поля «Свой стиль» в окне редактора.
    static let customID = "custom"
    static func adHoc(_ description: String) -> Style {
        Style(id: customID, emoji: "✍️", name: String(localized: "Свой стиль"),
              prompt: description.isEmpty
                ? Lang.pick("Перепиши в другом стиле.", "Rewrite it in a different style.")
                : Lang.pick("Перепиши в таком стиле: ", "Rewrite it in this style: ") + description)
    }
}

@MainActor
final class StyleStore: ObservableObject {
    static let shared = StyleStore()

    @Published var styles: [Style] { didSet { save() } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FairCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("styles.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Style].self, from: data) {
            styles = saved
        } else {
            styles = Self.defaults
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(styles).write(to: url, options: .atomic)
    }

    func style(id: String?) -> Style? { styles.first { $0.id == id } }

    func style(named name: String) -> Style? {
        styles.first { $0.name.lowercased() == name.lowercased() }
    }

    @discardableResult
    func add(_ style: Style? = nil) -> Style {
        let s = style ?? Style(id: UUID().uuidString, emoji: "✨", name: String(localized: "Новый стиль"),
                               prompt: Lang.pick("Перепиши так, чтобы…", "Rewrite it so that…"))
        styles.append(s)
        return s
    }

    func delete(id: String) { styles.removeAll { $0.id == id } }

    func move(id: String, by offset: Int) {
        guard let i = styles.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard styles.indices.contains(j) else { return }
        styles.swapAt(i, j)
    }

    func isBuiltin(_ id: String) -> Bool { (Self.defaultsRu + Self.defaultsEn).contains { $0.id == id } }

    /// Стандартный стиль не «изменён», если совпадает с исходником на любом из языков
    /// (стили, созданные при русском интерфейсе, остаются русскими после смены языка).
    func isModified(_ style: Style) -> Bool {
        let originals = (Self.defaultsRu + Self.defaultsEn).filter { $0.id == style.id }
        guard !originals.isEmpty else { return false }
        return !originals.contains { d in
            d.emoji == style.emoji && d.name == style.name && d.prompt == style.prompt
                && d.examples.map { [$0.input, $0.output] } == style.examples.map { [$0.input, $0.output] }
        }
    }

    /// Возвращает один стандартный стиль к исходному виду.
    func reset(id: String) {
        guard let d = Self.defaults.first(where: { $0.id == id }),
              let i = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[i] = d
    }

    /// Восстанавливает все стандартные стили (в том числе удалённые); свои стили остаются в конце.
    func restoreDefaults() {
        let custom = styles.filter { !isBuiltin($0.id) }
        styles = Self.defaults + custom
    }

    // MARK: стандартный набор (на языке интерфейса)

    static var defaults: [Style] { Lang.isEnglish ? defaultsEn : defaultsRu }

    static let defaultsRu: [Style] = [
        Style(id: "no-fillers", emoji: "🧹", name: "Без паразитов", prompt: """
            Исправь орфографию, пунктуацию и грамматику, расставь заглавные буквы, раздели текст на предложения.
            Убери слова-паразиты и речевые тики: «короче», «типа», «как бы», «ну», «вот», «это самое», «в общем», \
            «значит», «так сказать», «чисто», «по факту», «реально», «просто» и «вообще», если они ничего не значат, \
            повторы вроде «да да да» и лишние «а» в начале фразы. После удаления поправь фразу, чтобы она звучала естественно.
            Сохрани смысл, факты, эмоции и разговорный тон — не делай текст официальным. Слова, которые несут смысл, \
            оставь («это просто» в значении «легко»). Мат, эмодзи и «))» — это тон, а не паразиты: оставь их.
            """, examples: [
                .init(input: "ну короче я типа вчера как бы зашёл к ним а там вот это самое никого нет прикинь",
                      output: "Я вчера зашёл к ним, а там никого нет, прикинь."),
                .init(input: "слушай ну в общем значит такая ситуация я чисто по факту не успеваю к пятнице реально нужна ещё неделя",
                      output: "Слушай, такая ситуация: я не успеваю к пятнице, нужна ещё неделя."),
                .init(input: "да да да короче поняла всё сделаю просто это не так просто как кажется))",
                      output: "Да, поняла, всё сделаю. Это не так просто, как кажется))"),
            ]),
        Style(id: "formal", emoji: "🎩", name: "Официальный",
              prompt: "Перепиши в официальном, нейтрально-формальном стиле, как в письме незнакомому человеку."),
        Style(id: "short", emoji: "✂️", name: "Краткий",
              prompt: "Перепиши максимально кратко: убери воду, повторы и вводные слова, оставь только суть, но в тоне автора."),
        Style(id: "friendly", emoji: "😊", name: "Дружеский",
              prompt: "Перепиши в тёплом, дружеском, разговорном стиле, как пишут близкому другу."),
        Style(id: "polite", emoji: "🌷", name: "Вежливый",
              prompt: "Перепиши вежливее и мягче: без грубостей и резкости, но не подобострастно."),
        Style(id: "corp", emoji: "💼", name: "Корпоративный",
              prompt: "Перепиши густым корпоративным языком айти-офиса: «коллеги», «синкануться», «зафиналить», «апдейт», «таска», «дедлайн», «на нашей стороне», «по итогам», «эскалировать», «в моменте»."),
        Style(id: "tribal", emoji: "🪶", name: "Племенной",
              prompt: "Перепиши так, как говорит вождь древнего племени: простые короткие фразы, образы природы, духов предков, огня и охоты."),
        Style(id: "zen", emoji: "🧘", name: "Дзен",
              prompt: "Перепиши в стиле дзен-мастера: спокойно, отстранённо, коротко, с лёгкой мудростью и метафорами природы."),
        Style(id: "biblical", emoji: "📜", name: "Библейский",
              prompt: "Перепиши в библейском стиле: торжественно, архаично, «и было так», «ибо», «воистину», как в Синодальном переводе."),
        Style(id: "viking", emoji: "🪓", name: "Викинг",
              prompt: "Перепиши как суровый викинг из саги: громко, воинственно, с упоминанием Одина, Вальхаллы, драккаров и топоров."),
    ]

    static let defaultsEn: [Style] = [
        Style(id: "no-fillers", emoji: "🧹", name: "No Fillers", prompt: """
            Fix spelling, punctuation and grammar, capitalize properly, split the text into sentences.
            Remove filler words and verbal tics: "like", "um", "uh", "you know", "I mean", "basically", "literally", \
            "actually", "kind of", "sort of", "just", "so" and "well" when they carry no meaning, repeats like \
            "yeah yeah yeah" and a stray "so" or "and" at the start. After removing them, smooth the phrase so it reads naturally.
            Keep the meaning, facts, emotion and casual tone — don't make it formal. Keep words that carry meaning \
            ("it's just two minutes away"). Swearing, emoji and ":)" are tone, not fillers: keep them.
            """, examples: [
                .init(input: "so like i basically went over there yesterday and um you know nobody was home lol",
                      output: "I went over there yesterday and nobody was home lol"),
                .init(input: "ok so i mean the thing is i literally can't finish by friday i kind of need another week",
                      output: "Ok, the thing is, I can't finish by Friday. I need another week."),
                .init(input: "yeah yeah yeah got it i'll do it it's just not as easy as it looks :)",
                      output: "Yeah, got it, I'll do it. It's just not as easy as it looks :)"),
            ]),
        Style(id: "formal", emoji: "🎩", name: "Formal",
              prompt: "Rewrite it in a formal, neutral style, as in a letter to a stranger."),
        Style(id: "short", emoji: "✂️", name: "Short",
              prompt: "Rewrite it as briefly as possible: drop fluff, repeats and filler, keep only the point, in the author's tone."),
        Style(id: "friendly", emoji: "😊", name: "Friendly",
              prompt: "Rewrite it in a warm, friendly, casual style, the way you'd text a close friend."),
        Style(id: "polite", emoji: "🌷", name: "Polite",
              prompt: "Rewrite it more politely and softly: no rudeness or harshness, but not servile."),
        Style(id: "corp", emoji: "💼", name: "Corporate",
              prompt: "Rewrite it in thick corporate office speak: \"circle back\", \"sync up\", \"action items\", \"bandwidth\", \"deliverables\", \"touch base\", \"leverage\", \"going forward\", \"per my last email\"."),
        Style(id: "tribal", emoji: "🪶", name: "Tribal",
              prompt: "Rewrite it the way an ancient tribal chief speaks: short simple phrases, images of nature, ancestor spirits, fire and the hunt."),
        Style(id: "zen", emoji: "🧘", name: "Zen",
              prompt: "Rewrite it like a zen master: calm, detached, brief, with gentle wisdom and nature metaphors."),
        Style(id: "biblical", emoji: "📜", name: "Biblical",
              prompt: "Rewrite it in a biblical style: solemn and archaic — \"and it came to pass\", \"for\", \"verily\", \"thou\", like the King James Bible."),
        Style(id: "viking", emoji: "🪓", name: "Viking",
              prompt: "Rewrite it like a fierce viking from a saga: loud and warlike, with Odin, Valhalla, longships and axes."),
    ]
}
