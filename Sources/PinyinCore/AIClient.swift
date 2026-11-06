import Foundation

public enum AIProviderKind: String, CaseIterable {
    case deepSeek = "deepseek"
    case gemini
    case openAICompatible = "openai_compatible"

    public var label: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "OpenAI compatible"
        }
    }

    public var fixedBaseURL: String? {
        switch self {
        case .deepSeek: return "https://api.deepseek.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openAICompatible: return nil
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-flash"
        case .gemini: return "gemini-3.5-flash-lite"
        case .openAICompatible: return ""
        }
    }
}

public struct AIProvider {
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(baseURL: String, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty
    }
}

public struct TranslateLanguage: Hashable {
    public let code: String
    public let name: String
    public let chineseName: String

    public static let all: [TranslateLanguage] = [
        .init(code: "EN", name: "English", chineseName: "英文"),
        .init(code: "ZH", name: "Simplified Chinese", chineseName: "简体中文"),
        .init(code: "TW", name: "Traditional Chinese", chineseName: "繁体中文"),
        .init(code: "ES", name: "Spanish", chineseName: "西班牙文"),
        .init(code: "FR", name: "French", chineseName: "法文"),
        .init(code: "AR", name: "Arabic", chineseName: "阿拉伯文"),
        .init(code: "RU", name: "Russian", chineseName: "俄文"),
        .init(code: "PT", name: "Portuguese", chineseName: "葡萄牙文"),
        .init(code: "DE", name: "German", chineseName: "德文"),
        .init(code: "JA", name: "Japanese", chineseName: "日文"),
        .init(code: "KO", name: "Korean", chineseName: "韩文"),
        .init(code: "ID", name: "Indonesian", chineseName: "印尼文"),
        .init(code: "VI", name: "Vietnamese", chineseName: "越南文"),
        .init(code: "TH", name: "Thai", chineseName: "泰文"),
    ]
}

public enum AIError: Error, Equatable {
    case notConfigured, tooLong, empty, refused, timedOut, offline, badAddress, invalidReply
    case http(Int, String)
}

/// Polish, translate and reading translation over an OpenAI-compatible chat API: a port of
/// AgentChatClient.kt, so the two keyboards ask the same way and fail the same way.
public final class AIClient {
    public static let maxSourceCharacters = 5000
    private let session: URLSession
    private let busyDelays: [UInt64]

    /// [busyDelaysMs] are the waits before each further try when the provider answers busy.
    public init(session: URLSession = .shared, busyDelaysMs: [UInt64] = [1000, 3000]) {
        self.session = session
        busyDelays = busyDelaysMs
    }

    public func polish(_ text: String, with provider: AIProvider) async throws -> String {
        try await request(system: Prompts.rewrite, text: text, provider: provider)
    }

    /// The models the provider offers, best known names first; empty when it won't say.
    public func models(_ provider: AIProvider) async throws -> [String] {
        guard !provider.apiKey.isEmpty else { return [] }
        var base = provider.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models"), url.scheme == "https" else { throw AIError.badAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw AIError.http(code, "") }
        return Self.parseModels(data)
    }

    static func parseModels(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embedding", "vision", "image", "audio", "tts", "aqa", "imagen", "veo"]
        return items.compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { id in !excluded.contains { id.lowercased().contains($0) } }
            .sorted()
    }

    /// Polishes [text] and writes it in [language], to send to someone.
    public func translate(_ text: String, to language: TranslateLanguage, with provider: AIProvider) async throws -> String {
        let system = Prompts.rewrite + "\n\n---\n\n" + Prompts.translate.replacingOccurrences(of: "{language}", with: language.name)
        return try await request(system: system, text: text, provider: provider)
    }

    /// Translates [text] faithfully to read it. Chinese goes to English when the language is Chinese.
    public func read(_ text: String, in language: TranslateLanguage, with provider: AIProvider) async throws -> String {
        var target = language
        if ["ZH", "TW"].contains(language.code), Self.isMostlyChinese(text) { target = TranslateLanguage.all[0] }
        return try await request(system: Prompts.read.replacingOccurrences(of: "{language}", with: target.name), text: text, provider: provider)
    }

    public static func isMostlyChinese(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.isEmpty { return false }
        let chinese = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return chinese.count * 2 > letters.count
    }

    /// Whether just-copied text is worth offering to translate.
    public static func isWorthReading(_ text: String, target: TranslateLanguage) -> Bool {
        let letters = text.filter(\.isLetter).count
        if text.count > maxSourceCharacters || letters < 2 { return false }
        if !text.contains(where: \.isWhitespace), text.contains(where: \.isNumber) || text.contains("://") || text.hasPrefix("www.") { return false }
        return !["ZH", "TW"].contains(target.code) || !isMostlyChinese(text)
    }

    public static func maxTokens(for text: String) -> Int {
        let units = Array(text.utf16)
        let cjk = units.filter { $0 >= 0x2E80 }.count
        let estimated = cjk + (units.count - cjk) / 3
        return min(max(estimated * 3 / 2 + 200, 2000), 8000)
    }

    private func request(system: String, text: String, provider: AIProvider) async throws -> String {
        guard provider.isConfigured else { throw AIError.notConfigured }
        if text.utf16.count > Self.maxSourceCharacters { throw AIError.tooLong }
        var base = provider.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme == "https" else { throw AIError.badAddress }
        var schemaError: Error?
        for strict in [true, false] {
            do {
                return try await withBusyRetries {
                    try await self.send(url, system: system, text: text, provider: provider, strict: strict)
                }
            } catch let AIError.http(code, reply) where strict && Self.isStructuredOutputUnsupported(code, reply) {
                schemaError = AIError.http(code, reply)
            }
        }
        throw schemaError ?? AIError.invalidReply
    }

    private func withBusyRetries(_ send: () async throws -> String) async throws -> String {
        for delay in busyDelays {
            do {
                return try await send()
            } catch let AIError.http(code, _) where code == 429 || (500...599).contains(code) {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
        }
        return try await send()
    }

    private static func isStructuredOutputUnsupported(_ code: Int, _ reply: String) -> Bool {
        guard [400, 404, 422].contains(code) else { return false }
        let lower = reply.lowercased()
        return ["no endpoints found", "failed to initialize samplers", "response_format", "json_schema", "structured output", "schema"]
            .contains { lower.contains($0) }
    }

    private func send(_ url: URL, system: String, text: String, provider: AIProvider, strict: Bool) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let format: [String: Any] = strict ? [
            "type": "json_schema",
            "json_schema": [
                "name": "znkeyboard_rewrite_response",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": ["text": ["type": "string", "description": "The final rewritten text only, without labels, explanations, or prefaces."]],
                    "required": ["text"],
                ],
            ],
        ] : ["type": "json_object"]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
            "temperature": 0.4,
            "max_tokens": Self.maxTokens(for: text),
            "response_format": format,
        ] as [String: Any])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? AIError.timedOut : AIError.offline
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw AIError.http(code, String(decoding: data, as: UTF8.self)) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first else { throw AIError.invalidReply }
        if choice["finish_reason"] as? String == "length" { throw AIError.tooLong }
        guard let message = choice["message"] as? [String: Any] else { throw AIError.invalidReply }
        if let refusal = message["refusal"] as? String, !refusal.trimmingCharacters(in: .whitespaces).isEmpty, refusal.lowercased() != "null" {
            throw AIError.refused
        }
        var content = ""
        if let text = message["content"] as? String {
            content = text
        } else if let parts = message["content"] as? [Any] {
            content = parts.map { ($0 as? String) ?? (($0 as? [String: Any])?["text"] as? String) ?? "" }.joined()
        } else if let object = message["content"] as? [String: Any] {
            return try finish(object["text"] as? String)
        } else {
            throw AIError.invalidReply
        }
        for tag in ["think", "reasoning"] {
            content = content.replacingOccurrences(of: "(?is)<\(tag)>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        guard let payload = content.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AIError.invalidReply }
        return try finish(object["text"] as? String)
    }

    private static func finish(_ text: String?) throws -> String {
        let cleaned = TextCleaner.clean(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.lowercased() == "null" { throw AIError.empty }
        return cleaned
    }

    /// What went wrong in words; never the server's raw reply.
    public static func message(for error: Error, chinese: Bool) -> String {
        func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
        switch error as? AIError {
        case .notConfigured: return t("请先在设置里填写 API Key。", "Add your API key in settings first.")
        case .tooLong: return t("文字太长，请分段处理（最多 5000 字）。", "The text is too long; do it in parts (5,000 characters at most).")
        case .empty: return t("AI 没有返回结果，请再试一次。", "The AI returned nothing. Try again.")
        case .refused: return t("AI 拒绝处理这段文字。", "The AI declined this text.")
        case .timedOut: return t("AI 服务响应超时，请稍后再试。", "The AI service took too long. Try again later.")
        case .offline: return t("无法连接 AI 服务，请检查网络。", "Couldn't reach the AI service. Check your connection.")
        case .badAddress: return t("接口地址必须以 https 开头。", "Use an https address.")
        case let .http(code, _):
            switch code {
            case 400: return t("请求被拒绝（HTTP 400），请检查模型名称。", "The request was rejected (HTTP 400). Check the model name.")
            case 401, 403: return t("API Key 无效或没有权限（HTTP \(code)），请在设置里检查。", "The API key is invalid or lacks access (HTTP \(code)). Check settings.")
            case 402: return t("额度已用完（HTTP 402），请检查账户余额。", "Out of credit (HTTP 402). Check your account.")
            case 404: return t("找不到这个模型或接口地址（HTTP 404），请在设置里检查。", "Model or API address not found (HTTP 404). Check settings.")
            case 429, 500...599: return t("AI 服务商暂时繁忙（HTTP \(code)），自动重试后仍未成功，请稍后再试。", "The AI provider is busy (HTTP \(code)) and still didn't answer after a few tries. Try again shortly.")
            default: return t("AI 请求失败（HTTP \(code)）。", "The AI request failed (HTTP \(code)).")
            }
        default: return t("AI 请求失败，请稍后再试。", "The AI request failed. Try again later.")
        }
    }
}
