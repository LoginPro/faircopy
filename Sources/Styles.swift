import Foundation

/// Стиль переписывания. Хранится в JSON, поэтому стандартные стили можно править и удалять,
/// а свои — создавать в «Настройки → Стили».
struct Style: Codable, Identifiable, Hashable {
    struct Example: Codable, Hashable, Identifiable {
        var id = UUID().uuidString
        var input: String
        var output: String

        init(input: String, output: String) { self.input = input; self.output = output }

        /// В shared/styles.json у примеров нет id — выдаём новый.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            input = try c.decode(String.self, forKey: .input)
            output = try c.decode(String.self, forKey: .output)
        }
    }

    var id: String
    var emoji: String
    var name: String
    /// Инструкция для модели: как именно переписать текст.
    var prompt: String
    /// Пары «до → после» (few-shot). Необязательны, но заметно повышают точность.
    var examples: [Example] = []

    init(id: String, emoji: String, name: String, prompt: String, examples: [Example] = []) {
        self.id = id; self.emoji = emoji; self.name = name; self.prompt = prompt; self.examples = examples
    }

    /// В shared/styles.json длинная инструкция записана массивом строк, примеров может не быть.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        emoji = try c.decode(String.self, forKey: .emoji)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(PromptText.self, forKey: .prompt).value
        examples = try c.decodeIfPresent([Example].self, forKey: .examples) ?? []
    }

    /// Разовый стиль из поля «Свой стиль» в окне редактора.
    static let customID = "custom"
    static func adHoc(_ description: String) -> Style {
        Style(id: customID, emoji: "✍️", name: String(localized: "Свой стиль"),
              prompt: description.isEmpty
                ? Shared.pack.style.customEmpty
                : Shared.fill(Shared.pack.style.custom, ["description": description]))
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
                               prompt: Self.newStylePrompt)
        styles.append(s)
        return s
    }

    static var newStylePrompt: String { Shared.pack.style.newStyle }

    func delete(id: String) { styles.removeAll { $0.id == id } }

    func move(id: String, by offset: Int) {
        guard let i = styles.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard styles.indices.contains(j) else { return }
        styles.swapAt(i, j)
    }

    func isBuiltin(_ id: String) -> Bool { Self.allDefaults.contains { $0.id == id } }

    /// Стандартный стиль не «изменён», если совпадает с исходником на любом из языков
    /// (стили, созданные при русском интерфейсе, остаются русскими после смены языка).
    func isModified(_ style: Style) -> Bool {
        let originals = Self.allDefaults.filter { $0.id == style.id }
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

    // MARK: стандартный набор (shared/styles.json, на языке интерфейса)

    static var defaults: [Style] { Shared.styles.locales[Lang.code] ?? Shared.styles.locales["en"] ?? [] }

    /// Стандартные стили на всех языках: стиль, созданный при русском интерфейсе,
    /// остаётся «стандартным» и после переключения на английский.
    static var allDefaults: [Style] { Shared.styles.locales.values.flatMap { $0 } }
}
