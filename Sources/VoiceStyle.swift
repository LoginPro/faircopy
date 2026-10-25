import Foundation

/// «Мой стиль»: стиль, собранный из сообщений самого пользователя.
/// Модель не дообучается — вместо этого она (1) описывает манеру автора как инструкцию
/// и (2) получает примеры «нейтральный пересказ → как написал автор» (обратный перевод),
/// по которым копирует его речь в новых текстах. Всё считается локально.
@MainActor
final class VoiceStyleBuilder: ObservableObject {
    struct Sender: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    @Published var pastedText = ""
    /// 0 — вставленный текст, 1 — экспорт Telegram.
    @Published var source = 0
    @Published var importedFile: String?
    @Published var senders: [Sender] = []
    @Published var senderID: String?
    @Published var name = String(localized: "Мой стиль")
    @Published var progress: String?
    @Published var error: String?
    @Published var building = false

    private var importedMessages: [(sender: String, text: String)] = []

    /// Сообщения, по которым будет строиться стиль.
    var messages: [String] {
        let source: [String]
        if importedFile != nil {
            source = importedMessages.filter { $0.sender == senderID }.map(\.text)
        } else {
            // вставленный текст: каждое сообщение с новой строки (или абзацами)
            source = pastedText.components(separatedBy: .newlines)
        }
        var seen = Set<String>()
        return source
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    // MARK: импорт экспорта Telegram (Telegram Desktop → Экспорт истории чата → JSON или HTML)

    /// Принимает result.json, любой messages*.html или саму папку экспорта.
    func importExport(from url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        if url.pathExtension.lowercased() == "json" {
            importTelegram(from: url)
        } else if isDir.boolValue, FileManager.default.fileExists(atPath: dir.appendingPathComponent("result.json").path) {
            importTelegram(from: dir.appendingPathComponent("result.json"))
        } else {
            importTelegramHTML(folder: dir)
        }
    }

    func importTelegram(from url: URL) {
        error = nil
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // один чат: {messages: [...]}; полный экспорт: {chats: {list: [{messages: [...]}]}}
            var raw: [[String: Any]] = root["messages"] as? [[String: Any]] ?? []
            if let list = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]] {
                for chat in list { raw += chat["messages"] as? [[String: Any]] ?? [] }
            }
            var msgs: [(String, String)] = []
            var names: [String: String] = [:]
            for m in raw where (m["type"] as? String) == "message" && m["forwarded_from"] == nil {
                guard let from = m["from_id"] as? String else { continue }
                let text = Self.plainText(m["text"])
                guard !text.isEmpty else { continue }
                msgs.append((from, text))
                if let n = m["from"] as? String { names[from] = n }
            }
            guard !msgs.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            importedMessages = msgs
            importedFile = url.lastPathComponent
            var counts: [String: Int] = [:]
            for (s, _) in msgs { counts[s, default: 0] += 1 }
            senders = counts.map { Sender(id: $0.key, name: names[$0.key] ?? $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
            // в полном экспорте Telegram сам говорит, кто владелец аккаунта
            if let me = (root["personal_information"] as? [String: Any])?["user_id"] {
                senderID = "user\(me)"
            }
            if senderID == nil || !senders.contains(where: { $0.id == senderID }) { senderID = senders.first?.id }
        } catch {
            self.error = String(localized: "Не удалось прочитать экспорт. Нужен файл result.json из Telegram Desktop (формат JSON).")
        }
    }

    /// HTML-экспорт: messages.html, messages2.html … Сообщение — блок «message default clearfix»;
    /// подряд идущие сообщения одного автора помечены «joined» и имени не содержат.
    func importTelegramHTML(folder: URL) {
        error = nil
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("messages") && $0.hasSuffix(".html") }
            .sorted { Self.pageNumber($0) < Self.pageNumber($1) }
        var msgs: [(String, String)] = []
        var chatTitle: String?
        for name in names {
            guard let html = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            if chatTitle == nil { chatTitle = Self.firstMatch(#"<div class="text bold">(.*?)</div>"#, in: html) }
            var sender: String?
            for chunk in html.components(separatedBy: "<div class=\"message ").dropFirst() {
                guard chunk.hasPrefix("default clearfix") else { continue } // служебные сообщения
                if !chunk.hasPrefix("default clearfix joined"),
                   let from = Self.firstMatch(#"<div class="from_name">(.*?)</div>"#, in: chunk) {
                    sender = from
                }
                // пересланное — чужая речь, а не автора
                guard let who = sender, !chunk.contains("class=\"forwarded body\""),
                      let text = Self.firstMatch(#"<div class="text">(.*?)</div>"#, in: chunk, keepLines: true),
                      !text.isEmpty else { continue }
                msgs.append((who, text))
            }
        }
        guard !msgs.isEmpty else {
            error = String(localized: "В папке не нашлось сообщений. Нужна папка экспорта Telegram с файлами messages*.html.")
            return
        }
        importedMessages = msgs
        importedFile = folder.lastPathComponent
        var counts: [String: Int] = [:]
        for (s, _) in msgs { counts[s, default: 0] += 1 }
        senders = counts.map { Sender(id: $0.key, name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        // в заголовке страницы — имя собеседника; значит, твои сообщения — от другого отправителя
        senderID = senders.first { $0.name != chatTitle }?.id ?? senders.first?.id
    }

    private static func pageNumber(_ name: String) -> Int {
        Int(name.dropFirst("messages".count).dropLast(".html".count)) ?? 1
    }

    /// Первое совпадение группы, очищенное от тегов и HTML-сущностей.
    private static func firstMatch(_ pattern: String, in text: String, keepLines: Bool = false) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        var s = String(text[r])
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: keepLines ? "\n" : " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = unescape(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
        // числовые сущности (&#128512; и т. п.)
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let whole = Range(m.range, in: out), let hexR = Range(m.range(at: 1), in: out),
                      let numR = Range(m.range(at: 2), in: out),
                      let code = UInt32(out[numR], radix: out[hexR].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    func clearImport() {
        importedFile = nil
        importedMessages = []
        senders = []
        senderID = nil
    }

    /// Текст сообщения в экспорте — строка или массив из строк и объектов {type, text}.
    private static func plainText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let parts = value as? [Any] {
            return parts.map { p in
                if let s = p as? String { return s }
                return (p as? [String: Any])?["text"] as? String ?? ""
            }.joined()
        }
        return ""
    }

    // MARK: построение стиля

    func build() async -> Style? {
        let all = messages
        guard all.count >= 15 else {
            error = String(localized: "Нужно хотя бы 15 сообщений — сейчас \(all.count). Чем больше, тем точнее стиль.")
            return nil
        }
        building = true; error = nil
        defer { building = false; progress = nil }

        // равномерная выборка по всей переписке, чтобы стиль не зависел от одного дня
        let analysisSample = Self.spread(all, budgetChars: 9000)
        // формальные привычки считаем сами по всем сообщениям — на глаз модель в них ошибается
        let stats = VoiceStats(all)
        do {
            progress = String(localized: "Изучаю манеру письма по \(analysisSample.count) сообщениям…")
            // описание должно быть полным списком; если модель оборвалась — пробуем ещё раз
            var description = ""
            for attempt in 0..<3 {
                description = try await LLMClient.shared.complete(Self.analysisMessages(analysisSample),
                                                                  maxTokens: 1200, temperature: attempt == 0 ? 0.2 : 0.4)
                    .replacingOccurrences(of: "**", with: "")
                if Self.isComplete(description) { break }
                progress = String(localized: "Уточняю описание манеры…")
            }
            description = Self.dropRareQuotes(description, messages: all)

            let candidates = all.filter { (40...260).contains($0.count) }
            let picks = Self.spread(candidates.isEmpty ? all : candidates, count: 8)
            var examples: [Style.Example] = []
            for (i, original) in picks.enumerated() {
                progress = String(localized: "Готовлю примеры речи: \(i + 1) из \(picks.count)…")
                let neutral = try await LLMClient.shared.complete(Self.neutralizeMessages(original), maxTokens: 400)
                if !neutral.isEmpty, neutral != original {
                    examples.append(.init(input: neutral, output: original))
                }
            }
            let title = name.trimmingCharacters(in: .whitespaces)
            let prompt = description + "\n\n" + stats.rules + "\n\n" + Self.moderation
            return Style(id: UUID().uuidString, emoji: "🗣️", name: title.isEmpty ? String(localized: "Мой стиль") : title,
                         prompt: prompt, examples: examples)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Модель иногда «находит» словечко в одном сообщении или выдумывает ему значение.
    /// Оставляем пункт с цитатой, только если цитата — короткий оборот, встречающийся хотя бы в 3 сообщениях.
    static func dropRareQuotes(_ text: String, messages: [String]) -> String {
        let lowered = messages.map { $0.lowercased() }
        // «ёлочки» в русском описании, "прямые" и “фигурные” — в английском
        let quoteRe = try! NSRegularExpression(pattern: "«([^»]+)»|\"([^\"]+)\"|“([^”]+)”")
        return text.components(separatedBy: "\n").filter { line in
            let quotes = quoteRe.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
                (1...3).lazy.compactMap { Range(m.range(at: $0), in: line) }.first.map { String(line[$0]).lowercased() }
            }
            return quotes.allSatisfy { q in
                q.split(separator: " ").count <= 3 && lowered.lazy.filter { $0.contains(q) }.prefix(3).count == 3
            }
        }.joined(separator: "\n")
    }

    /// Полное описание — хотя бы 6 пунктов и законченное последнее предложение.
    private static func isComplete(_ text: String) -> Bool {
        let points = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        guard points.count >= 6, let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?»)\"”".contains(last)
    }

    /// Берёт сообщения равномерно по всему списку, пока не кончится бюджет символов.
    private static func spread(_ items: [String], budgetChars: Int) -> [String] {
        let step = max(1, items.count / max(1, budgetChars / 60))
        var out: [String] = [], used = 0
        for i in stride(from: 0, to: items.count, by: step) {
            let m = String(items[i].prefix(300))
            if used + m.count > budgetChars { break }
            out.append(m); used += m.count
        }
        return out
    }

    private static func spread(_ items: [String], count: Int) -> [String] {
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }

    /// Без этого модель превращает стиль в пародию: вставляет все любимые словечки разом и дописывает мысли.
    static var moderation: String { Shared.pack.voice.moderation.value }

    static func analysisMessages(_ sample: [String]) -> [ChatMessage] {
        [.init(role: "system", content: Shared.pack.voice.analysis.value),
         .init(role: "user", content: sample.joined(separator: "\n"))]
    }

    static func neutralizeMessages(_ text: String) -> [ChatMessage] {
        [.init(role: "system", content: Shared.pack.voice.neutralize.value),
         .init(role: "user", content: Shared.fill(Shared.prompts.input, ["text": text]))]
    }
}

/// Точные формальные привычки, посчитанные по всем сообщениям автора.
struct VoiceStats {
    let count: Int
    let upperStart: Int, periodEnd: Int, bracket: Int, doubleBracket: Int, emoji: Int, ellipsis: Int
    let medianWords: Int

    init(_ messages: [String]) {
        func pct(_ n: Int, of total: Int) -> Int { total == 0 ? 0 : Int((Double(n) * 100 / Double(total)).rounded()) }
        count = messages.count
        let lettered = messages.compactMap { $0.first(where: \.isLetter) }
        upperStart = pct(lettered.filter(\.isUppercase).count, of: lettered.count)
        let trimmed = messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        periodEnd = pct(trimmed.filter { $0.hasSuffix(".") && !$0.hasSuffix("..") }.count, of: count)
        bracket = pct(trimmed.filter { $0.contains(")") && !$0.contains("(") }.count, of: count)
        doubleBracket = pct(trimmed.filter { $0.contains("))") }.count, of: count)
        emoji = pct(messages.filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }.count, of: count)
        ellipsis = pct(messages.filter { $0.contains("...") || $0.contains("…") }.count, of: count)
        let words = messages.map { $0.split(whereSeparator: \.isWhitespace).count }.sorted()
        medianWords = words.isEmpty ? 0 : words[words.count / 2]
    }

    /// Частота → понятное правило для модели.
    private func rule(_ p: Int, _ tiers: PromptPack.Tiers) -> String {
        p >= 70 ? tiers.often : p >= 25 ? tiers.sometimes : tiers.rarely
    }

    var rules: String {
        let v = Shared.pack.voice
        return Shared.fill(v.stats.value, [
            "count": "\(count)",
            "capitalRule": rule(upperStart, v.capitalRule), "capitalStart": "\(upperStart)",
            "periodRule": rule(periodEnd, v.periodRule), "periodEnd": "\(periodEnd)",
            "bracket": "\(bracket)", "doubleBracket": "\(doubleBracket)",
            "emoji": "\(emoji)", "ellipsis": "\(ellipsis)", "medianWords": "\(medianWords)",
        ])
    }
}
