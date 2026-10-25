import Foundation

/// Промпты и стандартные стили из shared/*.json — общие для macOS- и Windows-версий.
/// Формат описан в shared/README.md. Файлы лежат в ресурсах приложения.
enum Shared {
    static let prompts: PromptFile = load("prompts")
    static let styles: StyleFile = load("styles")

    /// Набор промптов на языке интерфейса.
    static var pack: PromptPack { prompts.locales[Lang.code] ?? prompts.locales["en"]! }

    private static func load<T: Decodable>(_ name: String) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            fatalError("В ресурсах приложения нет \(name).json — соберите приложение через build.sh")
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { fatalError("\(name).json: \(error)") }
    }

    /// Подставляет значения вместо `{имя}` за один проход: текст пользователя,
    /// попавший в подстановку, сам уже не разбирается (в нём тоже могут быть фигурные скобки).
    /// Неизвестные плейсхолдеры остаются как есть.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }
}

/// Многострочный промпт в JSON — массив строк (удобно читать и сравнивать в git), короткий — строка.
struct PromptText: Codable, Hashable {
    var value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let lines = try? c.decode([String].self) { value = lines.joined(separator: "\n") }
        else { value = try c.decode(String.self) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

struct PromptFile: Decodable {
    let format: Int
    /// Как текст пользователя оборачивается в сообщение модели: `<text>{text}</text>`.
    let input: String
    let languages: [String]
    let locales: [String: PromptPack]
}

struct PromptPack: Decodable {
    struct Example: Decodable { let input: String; let output: String }
    struct Fix: Decodable { let system: PromptText; let examples: [Example] }
    struct StylePrompts: Decodable {
        let system: PromptText
        let custom: String
        let customEmpty: String
        let newStyle: String
    }
    struct Dictionary: Decodable { let note: String; let word: String; let separator: String }
    struct Translate: Decodable { let system: PromptText; let keepTone: String; let styledTone: String }
    struct Explain: Decodable { let system: PromptText; let user: PromptText; let edit: String; let empty: String }
    /// Правило по частоте привычки: ≥70% — often, ≥25% — sometimes, иначе rarely.
    struct Tiers: Decodable { let often: String; let sometimes: String; let rarely: String }
    struct Voice: Decodable {
        let analysis: PromptText
        let neutralize: PromptText
        let moderation: PromptText
        let stats: PromptText
        let capitalRule: Tiers
        let periodRule: Tiers
    }

    let fix: Fix
    let style: StylePrompts
    let dictionary: Dictionary
    let translate: Translate
    let explain: Explain
    let voice: Voice
}

struct StyleFile: Decodable {
    let format: Int
    let locales: [String: [Style]]
}
