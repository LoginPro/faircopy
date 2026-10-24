import AppKit
import SwiftUI
import Carbon

/// Сочетание клавиш в формате Carbon (коды клавиш физические — от раскладки не зависят).
struct HotKeySpec: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int

    static let editorDefault = HotKeySpec(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey)
    static let quickDefault = HotKeySpec(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | shiftKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = Int(event.keyCode)
        var m = 0
        let f = event.modifierFlags
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        modifiers = m
    }

    /// Без ⌃/⌥/⌘ сочетание перехватывало бы обычный набор текста.
    var isUsable: Bool { modifiers & (controlKey | optionKey | cmdKey) != 0 }

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "#\(keyCode)")
    }

    private static let keyNames: [Int: String] = {
        var n: [Int: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, String(localized: "Пробел")), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        for (k, v) in letters { n[k] = v }
        return n
    }()
}

/// Что запомнили для приложения: в каком режиме и стиле открывать редактор.
struct AppPref: Codable, Equatable {
    var name: String
    var mode: String
    var styleID: String?
    var translateStyleID: String?
    var language: String?

    var editMode: EditMode { EditMode(rawValue: mode) ?? .fix }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, styles, apps, dictionary
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "Основное")
        case .styles: String(localized: "Стили")
        case .apps: String(localized: "Приложения")
        case .dictionary: String(localized: "Словарь")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .styles: "wand.and.stars"
        case .apps: "square.grid.2x2"
        case .dictionary: "character.book.closed"
        }
    }

    /// Цвет плашки иконки в боковой панели — как в Системных настройках.
    var tint: Color {
        switch self {
        case .general: .gray
        case .styles: .purple
        case .apps: .blue
        case .dictionary: .orange
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var dictionaryText: String { didSet { d.set(dictionaryText, forKey: "dictionary") } }
    @Published var appPrefs: [String: AppPref] { didSet { store(appPrefs, "appPrefs") } }
    @Published var rememberPerApp: Bool { didSet { d.set(rememberPerApp, forKey: "rememberPerApp") } }
    @Published var explainEdits: Bool { didSet { d.set(explainEdits, forKey: "explainEdits") } }
    @Published var prewarm: Bool { didSet { d.set(prewarm, forKey: "prewarm") } }
    @Published var ttl: Int {
        didSet { d.set(ttl, forKey: "ttl"); LLMClient.shared.idleTTL = ttl }
    }
    @Published var editorHotKey: HotKeySpec { didSet { store(editorHotKey, "editorHotKey") } }
    @Published var quickHotKey: HotKeySpec { didSet { store(quickHotKey, "quickHotKey") } }

    /// Пока пользователь записывает новое сочетание, глобальные хоткеи сняты —
    /// иначе Carbon перехватит нажатие раньше, чем его увидит поле записи.
    @Published var recordingHotKey = false
    /// Какие хоткеи не удалось зарегистрировать (заняты другим приложением).
    @Published var hotKeyFailures: Set<String> = []
    @Published var tab: SettingsTab = .general
    /// Выбранный стиль в «Настройки → Стили» и показ мастера «Мой стиль» — общие, чтобы ими
    /// управляли и сам раздел, и кнопки в панели инструментов окна.
    @Published var selectedStyleID: String?
    @Published var showVoiceSheet = false

    static let ttlOptions: [(Int, String)] = [
        (900, String(localized: "15 минут")), (1800, String(localized: "30 минут")), (3600, String(localized: "1 час")), (4 * 3600, String(localized: "4 часа")), (7 * 24 * 3600, String(localized: "Не выгружать")),
    ]

    var dictionary: [String] {
        dictionaryText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private init() {
        dictionaryText = d.string(forKey: "dictionary") ?? ""
        rememberPerApp = d.object(forKey: "rememberPerApp") as? Bool ?? true
        explainEdits = d.object(forKey: "explainEdits") as? Bool ?? true
        prewarm = d.object(forKey: "prewarm") as? Bool ?? true
        ttl = d.object(forKey: "ttl") as? Int ?? 3600
        appPrefs = Self.load("appPrefs") ?? [:]
        editorHotKey = Self.load("editorHotKey") ?? .editorDefault
        quickHotKey = Self.load("quickHotKey") ?? .quickDefault
        LLMClient.shared.idleTTL = ttl
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        d.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
