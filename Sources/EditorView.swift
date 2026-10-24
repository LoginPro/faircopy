import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var store = StyleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // бренд — тихо, главное в окне — текст; раньше крупный заголовок спорил с результатом
            HStack(spacing: 8) {
                if let logo = Bundle.main.image(forResource: "MenuBarIcon") {
                    Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
                        .frame(height: 14).foregroundStyle(.secondary)
                }
                Text("FairCopy").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Text(model.stats).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                Button { model.onOpenSettings(.general) } label: { Image(systemName: "gearshape") }
                    .help("Настройки")
                Button { model.onClose() } label: { Image(systemName: "xmark") }
                    .help("Закрыть (esc)")
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)

            Picker("", selection: $model.mode) {
                ForEach(EditMode.allCases) { m in Label(m.title, systemImage: m.icon).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.mode == .style {
                StyleChips(styles: store.styles,
                           selection: Binding(get: { model.styleID }, set: { model.styleID = $0 ?? Style.customID }),
                           allowNone: false) { model.onOpenSettings(.styles) }
                if model.styleID == Style.customID { customField }
            } else if model.mode == .translate {
                Picker("Язык", selection: $model.language) {
                    ForEach(Prompts.languages, id: \.self) { Text($0).tag($0) }
                }
                StyleChips(styles: store.styles, selection: $model.translateStyleID, allowNone: true) {
                    model.onOpenSettings(.styles)
                }
                if model.translateStyleID == Style.customID { customField }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.showOriginal.toggle()
                } label: {
                    HStack {
                        Text("Оригинал").font(.headline)
                        Spacer()
                        Image(systemName: model.showOriginal ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.showOriginal {
                    scrollIfTall(model.original, maxHeight: 160) {
                        Text(model.original).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Text(model.original).lineLimit(1).foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("Результат").font(.headline)
                    Spacer()
                    if !model.running, model.error == nil, !model.result.isEmpty {
                        Button {
                            model.editing ? model.finishEditing() : (model.editing = true)
                        } label: {
                            Label(model.editing ? String(localized: "Готово") : String(localized: "Изменить"),
                                  systemImage: model.editing ? "checkmark" : "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(model.editing ? String(localized: "Закончить правку") : String(localized: "Поправить результат вручную"))
                    }
                }
                resultBody
                hintLine
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack {
                applyButton
                Group {
                    Button { model.run() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Ещё раз (⌘R)")
                        .keyboardShortcut("r", modifiers: .command)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.result, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Скопировать")
                        .disabled(model.result.isEmpty)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(width: EditorPanel.width)
        // Liquid Glass: окно без рамки, форму и материал задаёт сам контент
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(EditorPanel.margin)
    }

    /// Пока идёт ручная правка, ↩ должен переносить строку, поэтому «Применить» — по ⌘↩.
    @ViewBuilder private var applyButton: some View {
        let button = Button {
            model.onApply(model.result)
        } label: {
            HStack(spacing: 6) {
                Text("Применить")
                Text(model.editing ? "⌘↩" : "↩").font(.callout).opacity(0.65)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        // на стекле обычная «синяя» кнопка серела, когда панель не в фокусе; glassProminent держит акцент
        .buttonStyle(.glassProminent)
        .disabled(model.running || model.result.isEmpty)
        if model.editing {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }

    private var customField: some View {
        HStack {
            TextField("Опиши стиль: «как пират», «с сарказмом»… и нажми ↩", text: $model.customStyle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.run() }
            Button("Сохранить") { model.saveCustomAsStyle() }
                .help("Сохранить как постоянный стиль")
                .disabled(model.customStyle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var resultBody: some View {
        if let err = model.error {
            // ошибка с выходом: раньше был только красный текст, и было непонятно, что делать дальше
            VStack(alignment: .leading, spacing: 8) {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Ещё раз") { model.run() }
                    Button("Настройки…") { model.onOpenSettings(.general) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        } else if model.result.isEmpty {
            HStack(spacing: 6) {
                if model.running { ProgressView().controlSize(.mini) }
                Text(model.running ? String(localized: "Думаю…") : "").foregroundStyle(.secondary)
            }
        } else if model.editing {
            TextEditor(text: $model.result)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: editorHeight)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6)))
        } else if !model.segments.isEmpty {
            // в диффе есть и удалённый текст — он длиннее результата
            scrollIfTall(model.result, extra: 1.2, maxHeight: model.maxResultHeight) { DiffFlowView(model: model) }
        } else {
            scrollIfTall(model.result, maxHeight: model.maxResultHeight) { Text(model.result).textSelection(.enabled) }
        }
    }

    private var editorHeight: CGFloat {
        let lines = model.result.count / 55 + model.result.filter { $0 == "\n" }.count + 2
        return min(model.maxResultHeight, max(60, CGFloat(lines) * 17))
    }

    /// Примерная высота текста в окне шириной 460 pt: ~58 символов в строке, ~17 pt на строку.
    /// Точно измерить до раскладки нельзя, а ScrollView без явной высоты схлопывается в ноль.
    private func estimatedHeight(_ text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 57) / 58) }
        return CGFloat(lines) * 17
    }

    /// `extra` — запас для диффа: зачёркнутый текст стоит рядом с новым и удлиняет строки.
    @ViewBuilder private func scrollIfTall<C: View>(_ text: String, extra: CGFloat = 1, maxHeight: CGFloat,
                                                    @ViewBuilder _ content: () -> C) -> some View {
        let estimate = estimatedHeight(text) * extra
        if estimate > maxHeight {
            ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }.frame(height: maxHeight)
        } else {
            content().fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var hintLine: some View {
        if model.mode == .fix, !model.editing, !model.running, model.changeCount > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text(hintText)
                    .font(.callout)
                    .foregroundStyle(model.hoverKey != nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var hintText: String {
        if let key = model.hoverKey {
            return model.explanations[key] ?? (model.explaining ? String(localized: "Готовлю пояснение…")
                                                                    : String(localized: "Пояснения к этой правке нет"))
        }
        if model.explaining { return String(localized: "Готовлю пояснения к правкам…") }
        if !model.settings.explainEdits {
            return String(localized: "Правок: \(model.changeCount). Пояснения выключены в настройках")
        }
        return String(localized: "Правок: \(model.changeCount). Наведи на правку — объясню, почему так")
    }
}

/// Результат с подсветкой правок: каждая правка — отдельный элемент, на который можно навести.
struct DiffFlowView: View {
    @ObservedObject var model: EditorModel

    private enum Item: Identifiable {
        case word(Int, String), lineBreak(Int), change(Int, DiffSegment)
        var id: Int {
            switch self { case .word(let i, _), .lineBreak(let i), .change(let i, _): i }
        }
    }

    /// Неизменный текст режем на слова (вместе с пробелами после них), чтобы перенос шёл по словам.
    private var items: [Item] {
        var out: [Item] = []
        for seg in model.segments {
            guard let same = seg.same else {
                // переносы строк внутри правки («\n\nмы» → «\n\nМы») делаем настоящими разрывами,
                // иначе правка рисуется высоким блоком посреди строки
                let lead = seg.added.prefix { $0.isWhitespace }.filter(\.isNewline).count
                let total = seg.added.filter(\.isNewline).count
                for _ in 0..<lead { out.append(.lineBreak(out.count)) }
                let trail = total - lead
                // пробелы срезаем только по краям, где был перенос, — иначе пропадёт пробел в «— это»
                func flat(_ t: String) -> String {
                    var r = t.replacingOccurrences(of: "\n", with: " ")
                    if lead > 0 { r = String(r.drop { $0.isWhitespace }) }
                    if trail > 0 { while r.last?.isWhitespace == true { r.removeLast() } }
                    return r
                }
                out.append(.change(out.count, DiffSegment(id: seg.id, same: nil, removed: flat(seg.removed),
                                                          added: flat(seg.added), key: seg.key)))
                for _ in 0..<trail { out.append(.lineBreak(out.count)) }
                continue
            }
            var word = ""
            for ch in same {
                if ch == "\n" {
                    if !word.isEmpty { out.append(.word(out.count, word)); word = "" }
                    out.append(.lineBreak(out.count))
                } else if ch.isWhitespace {
                    word.append(ch)
                } else {
                    if let last = word.last, last.isWhitespace { out.append(.word(out.count, word)); word = "" }
                    word.append(ch)
                }
            }
            if !word.isEmpty { out.append(.word(out.count, word)) }
        }
        return out
    }

    var body: some View {
        FlowLayout {
            ForEach(items) { item in
                switch item {
                case .word(_, let w):
                    Text(w)
                case .lineBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: FlowLayout.LineBreak.self, value: true)
                case .change(_, let seg):
                    change(seg)
                }
            }
        }
    }

    private func change(_ seg: DiffSegment) -> some View {
        let hovered = model.hoverKey == seg.key
        return HStack(spacing: 0) {
            if !seg.removed.isEmpty { Text(seg.removed).strikethrough().foregroundColor(.red) }
            if !seg.added.isEmpty { Text(seg.added).underline().foregroundColor(.accentColor) }
        }
        .padding(.horizontal, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(hovered ? 0.22 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoverKey = seg.key } else if model.hoverKey == seg.key { model.hoverKey = nil }
        }
        .help(model.explanations[seg.key] ?? "")
    }
}

/// Стили — стеклянные капсулы с переносом по строкам. Раньше была сетка 4×3 плиток по 44 pt:
/// она занимала больше места, чем сам результат, а длинные названия ужимались.
struct StyleChips: View {
    let styles: [Style]
    @Binding var selection: String?
    let allowNone: Bool
    var onManage: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if allowNone { chip(nil, "🚫", String(localized: "Без стиля")) }
                ForEach(styles) { chip($0.id, $0.emoji, $0.name) }
                chip(Style.customID, "✍️", String(localized: "Свой стиль"))
                Button(action: onManage) { label(Text(Image(systemName: "slider.horizontal.3")), String(localized: "Стили…"), on: false) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .help("Редактор стилей")
            }
        }
    }

    private func chip(_ id: String?, _ emoji: String, _ title: String) -> some View {
        let on = selection == id
        return Button { selection = id } label: { label(Text(emoji), title, on: on) }
            .buttonStyle(.plain)
            .glassEffect(on ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
            .animation(.snappy(duration: 0.2), value: on)
    }

    private func label(_ icon: Text, _ title: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            icon
            Text(title).fontWeight(on ? .semibold : .regular)
        }
        .font(.callout)
        .foregroundStyle(on ? Color.white : Color.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .contentShape(Capsule())
    }
}
