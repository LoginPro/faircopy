import AppKit
import ServiceManagement
import SwiftUI

/// Настройки в духе Системных настроек macOS 26: плавающая стеклянная боковая панель
/// с разделами и заголовок раздела в стеклянной панели инструментов. Раньше были вкладки-сегменты.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    var onToken: () -> Void
    var onAccess: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { settings.tab }, set: { if let t = $0 { settings.tab = t } })) {
                ForEach(SettingsTab.allCases) { tab in
                    Label {
                        Text(tab.title)
                    } icon: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.tint.gradient))
                    }
                    .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch settings.tab {
                case .general: GeneralTab(onToken: onToken, onAccess: onAccess)
                case .styles: StylesTab()
                case .apps: AppsTab()
                case .dictionary: DictionaryTab()
                }
            }
            .navigationTitle(settings.tab.title)
        }
        .frame(minWidth: 880, minHeight: 600)
    }
}

// MARK: - Основное

private struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared
    var onToken: () -> Void
    var onAccess: () -> Void
    // CLT-сборка без Xcode: макрос @State недоступен, поэтому локальное состояние — в ObservableObject
    @StateObject private var st = GeneralState()

    var body: some View {
        Form {
            Section("Горячие клавиши") {
                LabeledContent("Окно редактора") {
                    HotKeyRecorder(spec: $settings.editorHotKey, failed: settings.hotKeyFailures.contains("editor"))
                }
                LabeledContent("Исправить сразу, без окна") {
                    HotKeyRecorder(spec: $settings.quickHotKey, failed: settings.hotKeyFailures.contains("quick"))
                }
                Text("Нажми на сочетание и введи новое. Нужен хотя бы один из ⌃ ⌥ ⌘. Esc — отмена.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Модель") {
                Picker("Модель LM Studio", selection: $st.currentModel) {
                    if st.models.isEmpty { Text(st.currentModel.isEmpty ? String(localized: "Авто") : st.currentModel).tag(st.currentModel) }
                    ForEach(st.models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: st.currentModel) { _, new in if !new.isEmpty { LLMClient.shared.model = new } }
                Picker("Выгружать из памяти после простоя", selection: $settings.ttl) {
                    ForEach(AppSettings.ttlOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Прогревать модель при запуске и после сна", isOn: $settings.prewarm)
                HStack {
                    Text("Первая правка без прогрева ждёт 10–12 с, пока загружаются 9 ГБ весов.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(st.warming ? String(localized: "Прогреваю…") : String(localized: "Прогреть сейчас")) {
                        st.warming = true
                        Task { await LLMClient.shared.prewarm(); st.warming = false }
                    }
                    .disabled(st.warming)
                }
            }

            Section("Редактор") {
                Toggle("Пояснять правки при наведении", isOn: $settings.explainEdits)
                Toggle("Запоминать режим и стиль для каждого приложения", isOn: $settings.rememberPerApp)
            }

            Section("Система") {
                Toggle("Запускать при входе", isOn: $st.loginItem)
                    .onChange(of: st.loginItem) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        st.loginItem = SMAppService.mainApp.status == .enabled
                    }
                LabeledContent("Универсальный доступ") {
                    if st.trusted {
                        Label("выдан", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Выдать…", action: onAccess)
                    }
                }
                LabeledContent("Токен LM Studio") { Button("Изменить…", action: onToken) }
            }
        }
        .formStyle(.grouped)
        .task {
            st.models = (try? await LLMClient.shared.listModels()) ?? []
            if let m = try? await LLMClient.shared.resolveModel() { st.currentModel = m }
            st.trusted = TextBridge.isTrusted(prompt: false)
        }
    }
}

/// Поле записи сочетания: ловит следующее нажатие клавиш, пока глобальные хоткеи сняты.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec
    var failed: Bool
    @StateObject private var st = RecorderState()

    var body: some View {
        HStack(spacing: 6) {
            if failed && !st.recording {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Сочетание занято системой или другим приложением")
            }
            Button(st.recording ? String(localized: "Нажми сочетание…") : spec.display) { st.recording ? stop() : start() }
                .frame(minWidth: 130)
                .buttonStyle(.bordered)
                .tint(st.recording ? .accentColor : nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        st.recording = true
        AppSettings.shared.recordingHotKey = true
        st.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            let new = HotKeySpec(event: event)
            if new.isUsable { spec = new; stop() } else { NSSound.beep() }
            return nil
        }
    }

    private func stop() {
        if let m = st.monitor { NSEvent.removeMonitor(m) }
        st.monitor = nil
        if st.recording { AppSettings.shared.recordingHotKey = false }
        st.recording = false
    }
}

// MARK: - Стили

private struct StylesTab: View {
    @ObservedObject var store = StyleStore.shared
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var st = StylesTabState()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $settings.selectedStyleID) {
                    ForEach(store.styles) { s in
                        HStack {
                            Text(s.emoji)
                            Text(s.name).lineLimit(1)
                            Spacer()
                            if store.isBuiltin(s.id), store.isModified(s) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Изменён")
                            }
                        }
                        .tag(s.id)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button { settings.selectedStyleID = store.add().id } label: { Image(systemName: "plus") }
                        .help("Новый стиль")
                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .help("Удалить стиль").disabled(settings.selectedStyleID == nil)
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Выше").disabled(settings.selectedStyleID == nil)
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .help("Ниже").disabled(settings.selectedStyleID == nil)
                    Spacer()
                    Menu {
                        Button("Создать «Мой стиль» по моим сообщениям…") { settings.showVoiceSheet = true }
                        Divider()
                        Button("Восстановить стандартные стили…") { st.confirmRestore = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 230)

            Divider()

            if let id = settings.selectedStyleID, let index = store.styles.firstIndex(where: { $0.id == id }) {
                StyleDetail(style: $store.styles[index], isBuiltin: store.isBuiltin(id),
                            isModified: store.isModified(store.styles[index])) { store.reset(id: id) }
                    .id(id)
            } else {
                VStack(spacing: 12) {
                    Text("Выбери стиль слева или создай новый").foregroundStyle(.secondary)
                    Button("🗣️ Создать «Мой стиль» по моим сообщениям…") { settings.showVoiceSheet = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if settings.selectedStyleID == nil { settings.selectedStyleID = store.styles.first?.id } }
        .sheet(isPresented: $settings.showVoiceSheet) {
            VoiceStyleSheet { style in
                store.add(style)
                settings.selectedStyleID = style.id
            }
        }
        .alert("Восстановить стандартные стили?", isPresented: $st.confirmRestore) {
            Button("Восстановить", role: .destructive) { store.restoreDefaults() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалённые стандартные стили вернутся, изменённые — примут исходный вид. Твои собственные стили останутся.")
        }
    }

    private func deleteSelected() {
        guard let id = settings.selectedStyleID, let i = store.styles.firstIndex(where: { $0.id == id }) else { return }
        store.delete(id: id)
        settings.selectedStyleID = store.styles.isEmpty ? nil : store.styles[min(i, store.styles.count - 1)].id
    }

    private func move(_ offset: Int) {
        if let id = settings.selectedStyleID { store.move(id: id, by: offset) }
    }
}

private struct StyleDetail: View {
    @Binding var style: Style
    let isBuiltin: Bool
    let isModified: Bool
    var onReset: () -> Void

    @StateObject private var st = StyleTestState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("", text: $style.emoji)
                        .frame(width: 44).multilineTextAlignment(.center).font(.title2)
                    TextField("Название", text: $style.name).font(.title3)
                }
                if isBuiltin {
                    HStack {
                        Text(isModified ? String(localized: "Стандартный стиль, изменён") : String(localized: "Стандартный стиль"))
                            .font(.caption).foregroundStyle(.secondary)
                        if isModified { Button("Вернуть исходный", action: onReset).controlSize(.small) }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Инструкция для модели").font(.headline)
                    Text("Опиши, как переписывать текст. Чем конкретнее — тем точнее.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $style.prompt)
                        .font(.body)
                        .frame(height: 130)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Примеры «было → стало»").font(.headline)
                    Text("Необязательно, но 2–5 примеров заметно повышают точность стиля.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($style.examples) { $ex in
                        HStack(alignment: .top) {
                            VStack(spacing: 4) {
                                TextField("Было", text: $ex.input, axis: .vertical).lineLimit(1...4)
                                TextField("Стало", text: $ex.output, axis: .vertical).lineLimit(1...4)
                            }
                            .textFieldStyle(.roundedBorder)
                            Button {
                                style.examples.removeAll { $0.id == ex.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                    Button { style.examples.append(.init(input: "", output: "")) } label: {
                        Label("Добавить пример", systemImage: "plus")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Проверка").font(.headline)
                    HStack {
                        TextField("Текст для проверки", text: $st.sample).textFieldStyle(.roundedBorder)
                        Button(st.testing ? "…" : String(localized: "Проверить")) { test() }.disabled(st.testing || st.sample.isEmpty)
                    }
                    if !st.result.isEmpty {
                        Text(st.result)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    }
                }
            }
            .padding(18)
        }
    }

    private func test() {
        st.testing = true
        st.result = ""
        let msgs = Prompts.messages(mode: .style, style: style, language: "", text: st.sample,
                                    dictionary: AppSettings.shared.dictionary)
        Task {
            do { st.result = try await LLMClient.shared.complete(msgs) }
            catch { st.result = String(localized: "Ошибка: \(error.localizedDescription)") }
            st.testing = false
        }
    }
}

private struct VoiceStyleSheet: View {
    @StateObject private var builder = VoiceStyleBuilder()
    @Environment(\.dismiss) private var dismiss
    var onCreate: (Style) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🗣️ Мой стиль").font(.title2.weight(.semibold))
            Text("Дай свои сообщения — модель опишет твою манеру и соберёт примеры твоей речи. Потом этот стиль переписывает любой текст так, как сказал бы ты. Всё считается на этом Mac, ничего не уходит в сеть.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $builder.source) {
                Text("Вставить текст").tag(0)
                Text("Экспорт из Telegram").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: builder.source) { _, s in if s == 0 { builder.clearImport() } }

            if builder.source == 0 {
                Text("Каждое сообщение — с новой строки. Лучше 50–300 сообщений из разных переписок.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $builder.pastedText)
                    .font(.body)
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            } else {
                Text("Telegram Desktop → чат → ⋮ → Экспорт истории чата (HTML или JSON, медиа не нужны). Выбери папку экспорта или result.json.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Выбрать экспорт…") { pickFile() }
                    if let f = builder.importedFile { Text(f).foregroundStyle(.secondary) }
                }
                if !builder.senders.isEmpty {
                    Picker("Чьи сообщения — твои", selection: $builder.senderID) {
                        ForEach(builder.senders) { s in Text("\(s.name) — \(s.count) сообщ.").tag(Optional(s.id)) }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                Text("Сообщений для анализа: \(builder.messages.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Название стиля", text: $builder.name).frame(width: 200).textFieldStyle(.roundedBorder)
            }

            if let p = builder.progress {
                HStack { ProgressView().controlSize(.small); Text(p).font(.callout) }
            }
            if let e = builder.error { Text(e).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(builder.building)
                Button("Создать стиль") {
                    Task {
                        if let style = await builder.build() {
                            onCreate(style)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(builder.building || builder.messages.count < 15)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .html]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Выбери папку экспорта Telegram (ChatExport_…) или result.json")
        if panel.runModal() == .OK, let url = panel.url { builder.importExport(from: url) }
    }
}

// MARK: - Приложения

private struct AppsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var store = StyleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Запоминать режим и стиль для каждого приложения", isOn: $settings.rememberPerApp)
            Text("Запоминается автоматически при «Применить». Быстрая замена (\(settings.quickHotKey.display)) тоже берёт стиль приложения, если для него выбран режим «Стилизация».")
                .font(.caption).foregroundStyle(.secondary)

            if settings.appPrefs.isEmpty {
                Spacer()
                Text("Пока пусто — примени правку в любом приложении, и оно появится здесь.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(settings.appPrefs.keys.sorted { settings.appPrefs[$0]!.name < settings.appPrefs[$1]!.name },
                            id: \.self) { id in
                        AppRow(bundleID: id, pref: Binding(
                            get: { settings.appPrefs[id] ?? AppPref(name: id, mode: EditMode.fix.rawValue) },
                            set: { settings.appPrefs[id] = $0 }),
                               styles: store.styles) { settings.appPrefs[id] = nil }
                    }
                }
            }
        }
        .padding(18)
    }
}

private struct AppRow: View {
    let bundleID: String
    @Binding var pref: AppPref
    let styles: [Style]
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            Text(pref.name).frame(width: 140, alignment: .leading).lineLimit(1)
            Picker("", selection: $pref.mode) {
                ForEach(EditMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden().frame(width: 140)
            switch pref.editMode {
            case .style:
                Picker("", selection: $pref.styleID) {
                    ForEach(styles) { Text("\($0.emoji) \($0.name)").tag(Optional($0.id)) }
                }
                .labelsHidden()
            case .translate:
                Picker("", selection: Binding(get: { pref.language ?? "English" }, set: { pref.language = $0 })) {
                    ForEach(Prompts.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            case .fix:
                Text("только ошибки").foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Забыть")
        }
        .padding(.vertical, 2)
    }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Словарь

private struct DictionaryTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Личный словарь").font(.headline)
            Text("Имена, ники, названия и термины, которые написаны правильно и не должны «исправляться». По одному на строку. Склонять их модель может — менять написание нет.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.dictionaryText)
                .font(.body.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Слов: \(settings.dictionary.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
    }
}

// MARK: - локальное состояние вью (вместо @State, см. комментарий в GeneralTab)

@MainActor private final class GeneralState: ObservableObject {
    @Published var models: [String] = []
    @Published var currentModel = LLMClient.shared.model ?? ""
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var trusted = TextBridge.isTrusted(prompt: false)
    @Published var warming = false
}

@MainActor private final class RecorderState: ObservableObject {
    @Published var recording = false
    var monitor: Any?
}

@MainActor private final class StylesTabState: ObservableObject {
    @Published var confirmRestore = false
}

@MainActor private final class StyleTestState: ObservableObject {
    @Published var sample = "ну короче я щас не смогу подойти давай попозже созвонимся"
    @Published var result = ""
    @Published var testing = false
}
