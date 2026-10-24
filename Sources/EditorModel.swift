import Foundation

@MainActor
final class EditorModel: ObservableObject {
    let styles = StyleStore.shared
    let settings = AppSettings.shared

    @Published var original = ""
    @Published var result = ""
    @Published var mode: EditMode = .fix { didSet { if oldValue != mode { autoRun() } } }
    @Published var styleID: String = StyleStore.shared.styles.first?.id ?? Style.customID {
        didSet { if oldValue != styleID, styleID != Style.customID { autoRun() } }
    }
    /// Стиль поверх перевода (как «добавить стиль при переводе» в Telegram); nil — без стиля.
    @Published var translateStyleID: String? {
        didSet { if oldValue != translateStyleID, translateStyleID != Style.customID { autoRun() } }
    }
    @Published var customStyle = UserDefaults.standard.string(forKey: "customStyle") ?? "" {
        didSet { UserDefaults.standard.set(customStyle, forKey: "customStyle") }
    }
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "English" {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            if oldValue != language { autoRun() }
        }
    }
    @Published var running = false
    @Published var error: String?
    @Published var showOriginal = false
    @Published var stats = ""

    /// Ручная правка результата перед «Применить».
    @Published var editing = false { didSet { if oldValue && !editing { refreshDiff() } } }
    @Published var segments: [DiffSegment] = []
    @Published var explanations: [String: String] = [:]
    @Published var explaining = false
    @Published var hoverKey: String?
    /// Сколько места по высоте можно отдать результату на текущем экране (задаёт панель).
    @Published var maxResultHeight: CGFloat = 320

    /// Приложение, из которого вызвали редактор (bundle id) — для запоминания стиля.
    private(set) var appID: String?

    var onApply: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onOpenSettings: (SettingsTab) -> Void = { _ in }

    private var task: Task<Void, Never>?
    private var explainTask: Task<Void, Never>?
    private var suppressRun = false

    var currentStyle: Style? {
        styleID == Style.customID ? Style.adHoc(customStyle) : styles.style(id: styleID)
    }
    var currentTranslateStyle: Style? {
        translateStyleID == Style.customID ? Style.adHoc(customStyle) : styles.style(id: translateStyleID)
    }
    var changeCount: Int { segments.filter(\.isChange).count }

    func start(text: String, appID: String?) {
        suppressRun = true
        original = text
        self.appID = appID
        showOriginal = false
        let pref = appID.flatMap { settings.rememberPerApp ? settings.appPrefs[$0] : nil }
        mode = pref?.editMode ?? .fix
        if let id = pref?.styleID { styleID = id }
        translateStyleID = pref?.translateStyleID
        if let lang = pref?.language { language = lang }
        validateStyles()
        suppressRun = false
        run()
    }

    /// Стиль могли удалить в настройках — тогда откатываемся на первый доступный.
    private func validateStyles() {
        if styleID != Style.customID, styles.style(id: styleID) == nil {
            styleID = styles.styles.first?.id ?? Style.customID
        }
        if let t = translateStyleID, t != Style.customID, styles.style(id: t) == nil { translateStyleID = nil }
    }

    private func autoRun() { if !suppressRun { run() } }

    func run() {
        task?.cancel(); explainTask?.cancel()
        result = ""; error = nil; stats = ""; running = true; editing = false
        segments = []; explanations = [:]; explaining = false; hoverKey = nil
        suppressRun = true; validateStyles(); suppressRun = false

        let msgs = Prompts.messages(mode: mode, style: currentStyle, language: language,
                                    translateStyle: currentTranslateStyle, text: original,
                                    dictionary: settings.dictionary)
        let started = Date()
        task = Task { [weak self] in
            do {
                let out = try await LLMClient.shared.complete(msgs) { text in
                    Task { @MainActor in self?.result = text }
                }
                guard let self, !Task.isCancelled else { return }
                self.result = out
                self.stats = String(format: String(localized: "%.1f с"), Date().timeIntervalSince(started))
                self.running = false
                self.refreshDiff()
                if self.mode == .fix, self.settings.explainEdits { self.explain() }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.error = error.localizedDescription
                self.running = false
            }
        }
    }

    func refreshDiff() {
        segments = mode == .fix && !result.isEmpty ? WordDiff.segments(original, result) : []
    }

    /// Второй, фоновый запрос: короткое объяснение каждой правки для подсказок при наведении.
    func explain() {
        let changes = Array(segments.filter { $0.isChange && explanations[$0.key] == nil }.prefix(15))
        guard !changes.isEmpty else { return }
        explaining = true
        let msgs = Prompts.explainMessages(original: original, result: result,
                                           changes: changes.map { ($0.removed, $0.added) })
        let keys = changes.map(\.key)
        explainTask = Task { [weak self] in
            let raw = try? await LLMClient.shared.complete(msgs, maxTokens: 70 * keys.count + 60)
            guard let self, !Task.isCancelled else { return }
            if let raw, let list = Prompts.parseExplanations(raw, count: keys.count) {
                for (k, e) in zip(keys, list) { self.explanations[k] = e }
            }
            self.explaining = false
        }
    }

    func finishEditing() {
        editing = false
        if mode == .fix, settings.explainEdits { explain() }
    }

    /// Превращает разовое описание из «Свой стиль» в постоянный стиль.
    func saveCustomAsStyle() {
        let text = customStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let s = styles.add(Style(id: UUID().uuidString, emoji: "✍️", name: String(text.prefix(24)),
                                 prompt: Style.adHoc(text).prompt))
        if mode == .translate { translateStyleID = s.id } else { styleID = s.id }
    }

    /// Запоминаем, в каком режиме и стиле применили текст в этом приложении.
    func rememberForApp(name: String?) {
        guard settings.rememberPerApp, let appID else { return }
        settings.appPrefs[appID] = AppPref(name: name ?? appID, mode: mode.rawValue,
                                           styleID: styleID == Style.customID ? nil : styleID,
                                           translateStyleID: translateStyleID == Style.customID ? nil : translateStyleID,
                                           language: language)
    }

    func cancel() {
        task?.cancel(); explainTask?.cancel()
        running = false; explaining = false; editing = false
    }
}
