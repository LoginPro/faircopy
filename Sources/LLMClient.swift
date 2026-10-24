import Foundation

struct ChatMessage: Encodable {
    let role: String
    let content: String
}

enum LLMError: LocalizedError {
    case serverUnavailable
    case unauthorized
    case noModel
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable: String(localized: "Сервер модели не отвечает (LM Studio, 127.0.0.1:1234)")
        case .unauthorized: String(localized: "LM Studio требует API-токен: меню редактора → «Токен LM Studio…»")
        case .noModel: String(localized: "Нет загруженных моделей в LM Studio")
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Клиент OpenAI-совместимого сервера LM Studio. Модель грузится «на лету» (JIT)
/// по первому запросу и выгружается через `ttl` секунд простоя, освобождая память.
final class LLMClient: @unchecked Sendable {
    static let shared = LLMClient()

    static let lmStudioURL = "http://127.0.0.1:1234/v1"
    /// Можно указать другой OpenAI-совместимый сервер (например, mlx_lm.server):
    /// `defaults write local.aieditor baseURL http://127.0.0.1:8080/v1` или env AIEDITOR_URL.
    var baseURL: URL {
        let env = ProcessInfo.processInfo.environment["AIEDITOR_URL"]
        return URL(string: env ?? UserDefaults.standard.string(forKey: "baseURL") ?? Self.lmStudioURL)!
    }
    var isLMStudio: Bool { baseURL.absoluteString == Self.lmStudioURL }

    var token: String? {
        get { ProcessInfo.processInfo.environment["LM_API_TOKEN"] ?? Keychain.read("lmstudio-token") }
        set { Keychain.write("lmstudio-token", newValue) }
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }
    let lmsPath = NSHomeDirectory() + "/.lmstudio/bin/lms"
    var idleTTL = 1800

    static let preferredModels = ["gemma-4-12b", "qwen3.5-9b"]

    var model: String? {
        get { UserDefaults.standard.string(forKey: "model") }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }

    func listModels() async throws -> [String] {
        var req = request("models")
        req.timeoutInterval = 2
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401 { throw LLMError.unauthorized }
        struct Resp: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try JSONDecoder().decode(Resp.self, from: data).data.map(\.id)
            .filter { !$0.contains("embed") }
    }

    /// Поднимает сервер LM Studio, если он не запущен (`lms server start`).
    func ensureServer() async throws {
        do { _ = try await listModels(); return }
        catch LLMError.unauthorized { throw LLMError.unauthorized }
        catch { guard isLMStudio else { throw LLMError.serverUnavailable } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lmsPath)
        p.arguments = ["server", "start"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if (try? await listModels()) != nil { return }
        }
        throw LLMError.serverUnavailable
    }

    func resolveModel() async throws -> String {
        let models = try await listModels()
        if let m = model, models.contains(m) { return m }
        for pref in Self.preferredModels {
            if let m = models.first(where: { $0.lowercased().contains(pref) }) { return m }
        }
        guard let first = models.first else { throw LLMError.noModel }
        return first
    }

    /// Стримит ответ; `onText` получает весь очищенный текст на текущий момент.
    @discardableResult
    func complete(_ messages: [ChatMessage], maxTokens: Int? = nil, temperature: Double = 0.2,
                  onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        try await ensureServer()
        let modelID = try await resolveModel()

        struct Body: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double
            let max_tokens: Int
            let stream: Bool
            let ttl: Int
            /// Gemma 4 / Qwen по умолчанию могут «думать» перед ответом — для правки текста это
            /// только лишние секунды, поэтому выключаем рассуждения через шаблон чата.
            let chat_template_kwargs = ["enable_thinking": false]
        }
        let inputChars = messages.last?.content.count ?? 0
        let body = Body(model: modelID, messages: messages, temperature: temperature,
                        max_tokens: maxTokens ?? max(512, inputChars * 2), stream: true, ttl: idleTTL)

        var req = request("chat/completions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 300

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw LLMError.unauthorized }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw LLMError.http(http.statusCode, text)
        }

        struct Chunk: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
            let choices: [Choice]
        }
        var raw = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
                  let delta = chunk.choices.first?.delta.content else { continue }
            raw += delta
            onText(Prompts.clean(raw))
        }
        return Prompts.clean(raw)
    }
}

extension LLMClient {
    struct LoadedModel: Decodable {
        let identifier: String
        let status: String?
        let sizeBytes: Int64?
    }

    /// Что сейчас лежит в памяти LM Studio (`lms ps --json`; CLI ходит в LM Studio без API-токена).
    func loadedModels() async -> [LoadedModel]? {
        guard let out = await runLMS(["ps", "--json"]),
              let list = try? JSONDecoder().decode([LoadedModel].self, from: Data(out.utf8)) else { return nil }
        return list
    }

    /// «Охлаждение»: выгружаем нашу модель из памяти (≈9 ГБ), чужие модели не трогаем.
    func unload() async {
        let ours = (try? await resolveModel()) ?? model
        for m in await loadedModels() ?? [] where ours == nil || m.identifier == ours {
            _ = await runLMS(["unload", m.identifier])
        }
    }

    private func runLMS(_ args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lmsPath)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }

    /// Загружает модель заранее (после запуска и пробуждения Mac): первая правка иначе ждёт
    /// 10–12 с, пока LM Studio поднимает 9 ГБ весов. Шлём тот же промпт исправления —
    /// заодно в кэше оказывается его начало, общее для всех запросов.
    func prewarm() async {
        _ = try? await complete(Prompts.messages(mode: .fix, style: nil, language: "", text: "ок"), maxTokens: 1)
    }
}

/// Токен LM Studio храним в Связке ключей, а не в plist с настройками.
enum Keychain {
    private static let service = "local.aieditor"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func write(_ account: String, _ value: String?) -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return errSecSuccess }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }
}
