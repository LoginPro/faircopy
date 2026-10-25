import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Аргументы без системных пар вроде `-AppleLanguages (en)` — их macOS разбирает сама.
    static let args: [String] = {
        var out: [String] = [], skip = false
        for a in CommandLine.arguments {
            if skip { skip = false; continue }
            if a.hasPrefix("-Apple") || a.hasPrefix("-NS") { skip = true; continue }
            out.append(a)
        }
        return out
    }()

    static func main() {
        let args = Self.args
        if args.count > 1, args[1] != "--panel", args[1] != "--settings" { CLI.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private let model = EditorModel()
    private lazy var panel = EditorPanel(model: model)
    private var targetApp: NSRunningApplication?
    private let modelMenu = NSMenu()
    private let settings = AppSettings.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private lazy var settingsToolbar = SettingsToolbar()

    func applicationDidFinishLaunching(_ note: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(busy: false)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // доступность «Прогреть»/«Выгрузить» задаём сами по состоянию модели
        menu.addItem(withTitle: String(localized: "Редактор для выделенного"), action: #selector(openEditor), keyEquivalent: "").tag = 10
        menu.addItem(withTitle: String(localized: "Исправить сразу"), action: #selector(quickFix), keyEquivalent: "").tag = 11
        menu.addItem(.separator())
        // модель: состояние + «прогрев» (загрузить заранее) и «охлаждение» (выгрузить ~9 ГБ из памяти)
        let state = menu.addItem(withTitle: String(localized: "Модель: …"), action: nil, keyEquivalent: "")
        state.tag = 20
        state.isEnabled = false
        let warm = menu.addItem(withTitle: String(localized: "Прогреть модель"), action: #selector(warmModel), keyEquivalent: "")
        warm.tag = 21
        warm.image = NSImage(systemSymbolName: "flame", accessibilityDescription: nil)
        let cool = menu.addItem(withTitle: String(localized: "Выгрузить модель из памяти"), action: #selector(coolModel), keyEquivalent: "")
        cool.tag = 22
        cool.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Настройки…"), action: #selector(openSettingsMenu), keyEquivalent: ",")
        menu.addItem(withTitle: String(localized: "Редактор стилей…"), action: #selector(openStylesMenu), keyEquivalent: "")
        let modelItem = menu.addItem(withTitle: String(localized: "Модель"), action: nil, keyEquivalent: "")
        menu.setSubmenu(modelMenu, for: modelItem)
        menu.addItem(withTitle: String(localized: "Токен LM Studio…"), action: #selector(setToken), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Выдать доступ (Универсальный доступ)…"), action: #selector(askAccess), keyEquivalent: "").tag = 1
        menu.addItem(withTitle: String(localized: "Запускать при входе"), action: #selector(toggleLogin), keyEquivalent: "").tag = 2
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Выход"), action: #selector(NSApp.terminate), keyEquivalent: "q")
        statusItem.menu = menu

        model.onApply = { [weak self] text in self?.apply(text) }
        model.onClose = { [weak self] in self?.closePanel() }
        model.onOpenSettings = { [weak self] tab in self?.openSettings(tab) }

        // хоткеи регистрируем сразу, а потом — только когда сочетания реально поменялись
        // или началась/закончилась запись нового (на это время их надо снять)
        registerHotKeys()
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeysIfChanged() } }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.prewarmIfEnabled() }
        }

        // `--panel "текст"` — открыть редактор сразу, без хоткея и Accessibility (для отладки UI)
        let args = Self.args
        if args.count > 2, args[1] == "--panel" {
            model.start(text: args[2], appID: nil)
            if args.count > 3, let mode = EditMode(rawValue: args[3]) { model.mode = mode } // для скриншотов режимов
            panel.show(at: NSRect(origin: NSEvent.mouseLocation, size: .zero))
        } else if args.count > 1, args[1] == "--settings" {
            openSettings(args.count > 2 ? SettingsTab(rawValue: args[2]) ?? .general : .general)
        } else {
            _ = TextBridge.isTrusted(prompt: true)
        }
        Task {
            try? await LLMClient.shared.ensureServer() // заранее, чтобы первый запрос был быстрее
            prewarmIfEnabled()
        }
    }

    private var registeredState: (HotKeySpec, HotKeySpec, Bool)?

    private func registerHotKeysIfChanged() {
        let state = (settings.editorHotKey, settings.quickHotKey, settings.recordingHotKey)
        if let r = registeredState, r.0 == state.0, r.1 == state.1, r.2 == state.2 { return }
        registerHotKeys()
    }

    private func registerHotKeys() {
        registeredState = (settings.editorHotKey, settings.quickHotKey, settings.recordingHotKey)
        hotKeys = [] // deinit снимает старые регистрации до новых — иначе то же сочетание будет «занято»
        guard !settings.recordingHotKey else { return }
        let editor = HotKey(id: 1, spec: settings.editorHotKey) { [weak self] in
            NSLog("FairCopy: хоткей редактора")
            self?.openEditor()
        }
        let quick = HotKey(id: 2, spec: settings.quickHotKey) { [weak self] in
            NSLog("FairCopy: хоткей быстрой замены")
            self?.quickFix()
        }
        NSLog("FairCopy: хоткеи %@ %@, зарегистрированы: %d %d", settings.editorHotKey.display,
              settings.quickHotKey.display, editor.isRegistered ? 1 : 0, quick.isRegistered ? 1 : 0)
        hotKeys = [editor, quick]
        var failures: Set<String> = []
        if !editor.isRegistered { failures.insert("editor") }
        if !quick.isRegistered { failures.insert("quick") }
        if settings.hotKeyFailures != failures { settings.hotKeyFailures = failures }
    }

    private func prewarmIfEnabled() {
        guard settings.prewarm else { return }
        warmModel()
    }

    // MARK: прогрев и охлаждение модели

    private enum ModelState { case unknown, loaded(Int64?), unloaded, warming, cooling, offline }
    private var modelState: ModelState = .unknown { didSet { updateModelItems() } }

    @objc func warmModel() {
        if case .warming = modelState { return }
        modelState = .warming
        setIcon(busy: true)
        Task {
            await LLMClient.shared.prewarm()
            setIcon(busy: false)
            await refreshModelState()
        }
    }

    @objc func coolModel() {
        modelState = .cooling
        Task {
            await LLMClient.shared.unload()
            await refreshModelState()
        }
    }

    private func refreshModelState() async {
        guard let loaded = await LLMClient.shared.loadedModels() else { modelState = .offline; return }
        let ours = try? await LLMClient.shared.resolveModel()
        if let m = loaded.first(where: { ours == nil || $0.identifier == ours }) {
            modelState = .loaded(m.sizeBytes)
        } else {
            modelState = .unloaded
        }
    }

    private func updateModelItems() {
        guard let menu = statusItem?.menu else { return }
        let title: String
        var canWarm = true, canCool = false
        switch modelState {
        case .unknown: title = String(localized: "Модель: проверяю…")
        case .loaded(let size):
            let gb = size.map { String(format: String(localized: " · %.1f ГБ"), Double($0) / 1_000_000_000) } ?? ""
            title = String(localized: "Модель: в памяти, готова\(gb)")
            canWarm = false; canCool = true
        case .unloaded: title = String(localized: "Модель: выгружена — первая правка ~10 с")
        case .warming: title = String(localized: "Модель: прогреваю…"); canWarm = false
        case .cooling: title = String(localized: "Модель: выгружаю…"); canWarm = false
        case .offline: title = String(localized: "Модель: LM Studio не отвечает")
        }
        menu.item(withTag: 20)?.title = title
        menu.item(withTag: 21)?.isEnabled = canWarm
        menu.item(withTag: 22)?.isEnabled = canCool
    }

    // MARK: actions

    @objc func openEditor() {
        targetApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        // окно — у строки с текстом, а не у мыши: хоткей жмут с клавиатуры, мышь может быть где угодно
        let place = TextBridge.focusedTextRect() ?? NSRect(origin: mouse, size: .zero)
        Task {
            guard let text = await grab() else { return }
            model.start(text: text, appID: targetApp?.bundleIdentifier)
            panel.show(at: place)
        }
    }

    @objc func quickFix() {
        targetApp = NSWorkspace.shared.frontmostApplication
        let app = targetApp
        Task {
            guard let text = await grab() else { return }
            setIcon(busy: true)
            defer { setIcon(busy: false) }
            do {
                // берём стиль, запомненный для этого приложения (перевод без окна не делаем — это сюрприз)
                let pref = app?.bundleIdentifier.flatMap { settings.rememberPerApp ? settings.appPrefs[$0] : nil }
                let style = pref?.editMode == .style ? StyleStore.shared.style(id: pref?.styleID) : nil
                let msgs = Prompts.messages(mode: style == nil ? .fix : .style, style: style, language: "",
                                            text: text, dictionary: settings.dictionary)
                let fixed = try await LLMClient.shared.complete(msgs)
                guard !fixed.isEmpty else { NSSound.beep(); return }
                await TextBridge.paste(fixed, into: app)
            } catch {
                NSSound.beep()
                notify(error.localizedDescription)
            }
        }
    }

    private func grab() async -> String? {
        guard TextBridge.isTrusted(prompt: false) else {
            NSLog("FairCopy: нет доступа «Универсальный доступ» — текст не взять")
            _ = TextBridge.isTrusted(prompt: true)
            return nil
        }
        guard let text = await TextBridge.grabText() else {
            NSLog("FairCopy: в активном поле нет текста")
            NSSound.beep(); return nil
        }
        return text
    }

    private func apply(_ text: String) {
        model.rememberForApp(name: targetApp?.localizedName)
        closePanel()
        let app = targetApp
        Task { await TextBridge.paste(text, into: app) }
    }

    private func closePanel() {
        model.cancel()
        panel.orderOut(nil)
        targetApp?.activate()
    }

    @objc func openSettingsMenu() { openSettings(.general) }
    @objc func openStylesMenu() { openSettings(.styles) }

    func openSettings(_ tab: SettingsTab) {
        settings.tab = tab
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(
                onToken: { [weak self] in self?.setToken() },
                onAccess: { [weak self] in self?.askAccess() }))
            // заголовок и панель инструментов отдаём SwiftUI: боковая панель уходит под «светофор»,
            // а название раздела стоит в стеклянной панели инструментов, как в Системных настройках
            host.sceneBridgingOptions = [.title, .toolbars]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            // без панели инструментов боковая панель не «всплывает» стеклом и заголовок раздела некуда поставить
            w.toolbar = settingsToolbar.toolbar
            w.toolbarStyle = .unified
            w.title = settings.tab.title
            settings.$tab.receive(on: RunLoop.main)
                .sink { [weak w] tab in w?.title = tab.title }
                .store(in: &subscriptions)
            w.setContentSize(NSSize(width: 900, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func askAccess() {
        _ = TextBridge.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// LM Studio с включённой авторизацией требует Bearer-токен. Его создаёт пользователь
    /// в LM Studio → Developer → Server Settings → Manage Tokens и вставляет сюда.
    @objc func setToken() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Токен LM Studio")
        alert.informativeText = String(localized: "LM Studio → Developer → Server Settings → Manage Tokens → Create Token. Вставь токен сюда (⌘V); он хранится в Связке ключей.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = LLMClient.shared.token == nil ? String(localized: "не задан") : String(localized: "задан (оставь пустым, чтобы удалить)")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "Сохранить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Keychain.write("lmstudio-token", token)
        guard status == errSecSuccess else {
            notify(String(localized: "Не удалось сохранить токен в Связку ключей (код \(String(status)))."))
            return
        }
        guard !token.isEmpty else { notify(String(localized: "Токен удалён.")); return }
        // сразу проверяем, что сервер принимает токен, чтобы ошибка не всплыла посреди переписки
        Task {
            do {
                try await LLMClient.shared.ensureServer()
                notify(String(localized: "Токен принят, LM Studio отвечает ✓"))
            } catch {
                notify(error.localizedDescription)
            }
        }
    }

    /// У приложения из строки меню нет главного меню, а без пунктов «Правка» не работают
    /// ⌘V/⌘C/⌘A в полях ввода (в окне токена и в поле «Свой стиль»). Меню не видно,
    /// но его сочетания клавиш срабатывают.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = main.addItem(withTitle: String(localized: "Правка"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: String(localized: "Правка"))
        edit.addItem(withTitle: String(localized: "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Повторить"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.setSubmenu(edit, for: editItem)
        NSApp.mainMenu = main
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { notify(error.localizedDescription) }
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        LLMClient.shared.model = sender.representedObject as? String
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        if case .warming = modelState {} else if case .cooling = modelState {} else {
            Task { await refreshModelState() }
        }
        updateModelItems()
        menu.item(withTag: 1)?.isHidden = TextBridge.isTrusted(prompt: false)
        menu.item(withTag: 2)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.item(withTag: 10)?.title = String(localized: "Редактор для выделенного   \(settings.editorHotKey.display)")
        menu.item(withTag: 11)?.title = String(localized: "Исправить сразу   \(settings.quickHotKey.display)")
        modelMenu.removeAllItems()
        modelMenu.addItem(withTitle: String(localized: "Загрузка…"), action: nil, keyEquivalent: "")
        Task {
            let models = (try? await LLMClient.shared.listModels()) ?? []
            let current = try? await LLMClient.shared.resolveModel()
            modelMenu.removeAllItems()
            if models.isEmpty { modelMenu.addItem(withTitle: String(localized: "LM Studio не запущен"), action: nil, keyEquivalent: "") }
            for m in models {
                let item = modelMenu.addItem(withTitle: m, action: #selector(pickModel), keyEquivalent: "")
                item.target = self
                item.representedObject = m
                item.state = m == current ? .on : .off
            }
        }
    }

    private func setIcon(busy: Bool) {
        // фирменная запятая с искрой; шаблонное изображение macOS сам красит под светлую/тёмную строку меню
        let logo = Bundle.main.image(forResource: "MenuBarIcon")
        logo?.isTemplate = true
        statusItem.button?.image = busy || logo == nil
            ? NSImage(systemSymbolName: busy ? "hourglass" : "text.badge.checkmark", accessibilityDescription: "FairCopy")
            : logo
    }

    private func notify(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "FairCopy"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// `AIEditor --fix "текст"` / `--style "Без паразитов" "текст"` / `--translate English "текст"`;
/// без текста читает stdin. Удобно для проверки промптов и моделей из терминала.
@MainActor
enum CLI {
    static func run() -> Never {
        var args = Array(AppDelegate.args.dropFirst())
        var mode = EditMode.fix, lang = "English"
        var style: Style?
        var explain = false
        while let a = args.first, a.hasPrefix("--") {
            args.removeFirst()
            switch a {
            case "--fix": mode = .fix
            case "--style":
                mode = .style
                let name = args.removeFirst()
                style = StyleStore.shared.style(named: name)
                if style == nil {
                    FileHandle.standardError.write("Нет стиля «\(name)». Есть: \(StyleStore.shared.styles.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!)
                    exit(2)
                }
            case "--translate": mode = .translate; lang = args.removeFirst()
            case "--model": LLMClient.shared.model = args.removeFirst()
            case "--explain": explain = true
            case "--warm", "--cool", "--model-state": modelCommand(a)
            case "--voice": runVoice(path: args.removeFirst(), test: args.joined(separator: " "))
            case "--dump-prompts": PromptDump.run()
            default: break
            }
        }
        let input = args.isEmpty
            ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            : args.joined(separator: " ")
        Task {
            do {
                let t0 = Date()
                let out = try await LLMClient.shared.complete(
                    Prompts.messages(mode: mode, style: style, language: lang, text: input,
                                     dictionary: AppSettings.shared.dictionary))
                print(out)
                if explain {
                    let changes = WordDiff.segments(input, out).filter(\.isChange)
                    let raw = try await LLMClient.shared.complete(
                        Prompts.explainMessages(original: input, result: out, changes: changes.map { ($0.removed, $0.added) }),
                        maxTokens: 70 * changes.count + 60)
                    let list = Prompts.parseExplanations(raw, count: changes.count) ?? []
                    for (i, c) in changes.enumerated() {
                        print("  «\(c.removed)» → «\(c.added)»: \(i < list.count ? list[i] : "—")")
                    }
                }
                FileHandle.standardError.write(String(format: "[%.1f с]\n", Date().timeIntervalSince(t0)).data(using: .utf8)!)
                exit(0)
            } catch {
                FileHandle.standardError.write("Ошибка: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    }

    /// `--warm` / `--cool` / `--model-state` — то же, что пункты меню, для проверки из терминала.
    static func modelCommand(_ cmd: String) -> Never {
        Task {
            let t0 = Date()
            if cmd == "--warm" { await LLMClient.shared.prewarm() }
            if cmd == "--cool" { await LLMClient.shared.unload() }
            let loaded = await LLMClient.shared.loadedModels()
            let list = loaded?.map { "\($0.identifier) [\($0.status ?? "?")]" }.joined(separator: ", ") ?? "LM Studio не отвечает"
            print(String(format: "%@ за %.1f с → в памяти: %@", cmd, Date().timeIntervalSince(t0),
                         list.isEmpty ? "ничего" : list))
            exit(0)
        }
        dispatchMain()
    }

    /// `--voice файл` — собрать «Мой стиль» из файла (сообщение на строку или result.json) и вывести его.
    static func runVoice(path: String, test: String) -> Never {
        let b = VoiceStyleBuilder()
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "txt" { b.pastedText = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        else { b.importExport(from: url) }
        if !b.senders.isEmpty {
            let list = b.senders.map { "\($0.name): \($0.count)" }.joined(separator: ", ")
            FileHandle.standardError.write("Отправители — \(list). Беру: \(b.senderID ?? "?")\n".data(using: .utf8)!)
        }
        if let who = ProcessInfo.processInfo.environment["FAIRCOPY_SENDER"] { b.senderID = who }
        Task {
            let t0 = Date()
            guard let style = await b.build() else {
                FileHandle.standardError.write("Ошибка: \(b.error ?? "?")\n".data(using: .utf8)!); exit(1)
            }
            print(style.prompt)
            if ProcessInfo.processInfo.environment["FAIRCOPY_SAVE"] != nil {
                StyleStore.shared.add(style)
                FileHandle.standardError.write("Стиль «\(style.name)» сохранён в styles.json\n".data(using: .utf8)!)
            }
            for e in style.examples { print("\n• \(e.input)\n→ \(e.output)") }
            if !test.isEmpty, let out = try? await LLMClient.shared.complete(
                Prompts.messages(mode: .style, style: style, language: "", text: test)) {
                print("\n=== Проверка ===\n\(test)\n→ \(out)")
            }
            FileHandle.standardError.write(String(format: "[%.1f с, сообщений %d]\n", Date().timeIntervalSince(t0), b.messages.count).data(using: .utf8)!)
            exit(0)
        }
        dispatchMain()
    }
}
