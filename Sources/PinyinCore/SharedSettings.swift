import Foundation
import Security

/// What the app and the keyboard share: settings in the app group, the API key in the keychain.
public enum SharedSettings {
    public static let appGroup = "group.com.oprfelix.znkeyboard"
    public static let keychainGroup = "6DSHU7W7LQ.com.oprfelix.znkeyboard.shared"

    private static let defaults = UserDefaults(suiteName: appGroup) ?? .standard
    /// Before each service kept its own, the one key lived here; the service chosen then takes it.
    private static let sharedKeyAccount = "api-key"
    private static var keyAccount: String { "api-key.\(providerKind.rawValue)" }

    public static var providerKind: AIProviderKind {
        get { defaults.string(forKey: "provider").flatMap(AIProviderKind.init) ?? .deepSeek }
        set { defaults.set(newValue.rawValue, forKey: "provider") }
    }

    public static var customBaseURL: String {
        get { defaults.string(forKey: "baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "baseURL") }
    }

    /// Each service keeps its own model, so going back to one restores it.
    public static var model: String {
        get {
            let key = "model.\(providerKind.rawValue)"
            if let shared = defaults.string(forKey: "model") {
                defaults.removeObject(forKey: "model")
                defaults.set(shared, forKey: key)
            }
            let saved = defaults.string(forKey: key) ?? providerKind.defaultModel
            // A model of another provider, or one no longer offered, falls back to the default.
            let offered = providerKind.models
            return offered.isEmpty || offered.contains(saved) ? saved : providerKind.defaultModel
        }
        set { defaults.set(newValue, forKey: "model.\(providerKind.rawValue)") }
    }

    public static var translateLanguage: TranslateLanguage {
        get { language(forKey: "translateLanguage") ?? TranslateLanguage.all[0] }
        set { defaults.set(newValue.code, forKey: "translateLanguage") }
    }

    public static var readingLanguage: TranslateLanguage {
        get { language(forKey: "readingLanguage") ?? TranslateLanguage.all[1] }
        set { defaults.set(newValue.code, forKey: "readingLanguage") }
    }

    public static var fuzzyRules: FuzzyRules {
        get { defaults.object(forKey: "fuzzyRules") == nil ? .standard : FuzzyRules(rawValue: defaults.integer(forKey: "fuzzyRules")) }
        set { defaults.set(newValue.rawValue, forKey: "fuzzyRules") }
    }

    private static func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    public static var hapticsEnabled: Bool {
        get { flag("haptics", default: true) }
        set { defaults.set(newValue, forKey: "haptics") }
    }

    /// Chinese is typed on 9 keys rather than 26.
    public static var nineKey: Bool {
        get { flag("nineKey", default: false) }
        set { defaults.set(newValue, forKey: "nineKey") }
    }

    /// The clipboard change last taken into the saved clipboard, so each copy is read once.
    public static var lastSavedPasteboard: Int {
        get { defaults.integer(forKey: "lastSavedPasteboard") }
        set { defaults.set(newValue, forKey: "lastSavedPasteboard") }
    }

    public static var keySoundEnabled: Bool {
        get { flag("keySound", default: false) }
        set { defaults.set(newValue, forKey: "keySound") }
    }

    public static var keyPopupEnabled: Bool {
        get { flag("keyPopup", default: true) }
        set { defaults.set(newValue, forKey: "keyPopup") }
    }

    public static var autoCapitalize: Bool {
        get { flag("autoCapitalize", default: true) }
        set { defaults.set(newValue, forKey: "autoCapitalize") }
    }

    public static var doubleSpacePeriod: Bool {
        get { flag("doubleSpacePeriod", default: true) }
        set { defaults.set(newValue, forKey: "doubleSpacePeriod") }
    }

    /// AI 整句排序 (experimental): the character model reorders whole-input readings. On by default.
    public static var aiRerank: Bool {
        get { flag("aiRerank", default: true) }
        set {
            defaults.set(newValue, forKey: "aiRerank")
            defaults.removeObject(forKey: "aiRerankCalls")
            defaults.removeObject(forKey: "aiRerankMillis")
        }
    }

    /// Keystrokes scored since the setting last changed, and their milliseconds in all.
    public static var aiRerankStats: (calls: Int, millis: Double) {
        (defaults.integer(forKey: "aiRerankCalls"), defaults.double(forKey: "aiRerankMillis"))
    }

    public static func addAIRerankStats(calls: Int, millis: Double) {
        guard calls > 0 else { return }
        defaults.set(defaults.integer(forKey: "aiRerankCalls") + calls, forKey: "aiRerankCalls")
        defaults.set(defaults.double(forKey: "aiRerankMillis") + millis, forKey: "aiRerankMillis")
    }

    /// What the keyboard measured while typing, for the app's 性能诊断 page.
    public static var perfReport: PerfReport {
        defaults.data(forKey: "perfReport").flatMap { try? JSONDecoder().decode(PerfReport.self, from: $0) } ?? PerfReport()
    }

    /// Adds [more] to what was measured so far.
    public static func addPerf(_ more: PerfReport) {
        var report = perfReport
        report.add(more)
        if let data = try? JSONEncoder().encode(report) { defaults.set(data, forKey: "perfReport") }
    }

    public static func resetPerf() { defaults.removeObject(forKey: "perfReport") }

    public static var adaptiveTouch: Bool {
        get { flag("adaptiveTouch", default: true) }
        set { defaults.set(newValue, forKey: "adaptiveTouch") }
    }

    /// Who the text goes to: the custom service's address, as a changed one needs a new yes.
    public static var aiRecipient: String { providerKind.fixedBaseURL == nil ? customBaseURL : providerKind.rawValue }

    /// The recipient as the user reads it.
    public static var aiRecipientName: String {
        guard providerKind.fixedBaseURL == nil else { return providerKind.label }
        return URL(string: customBaseURL)?.host ?? customBaseURL
    }

    /// Whether the user agreed to send text to the service now chosen.
    public static var hasAIConsent: Bool {
        (defaults.stringArray(forKey: "aiConsent") ?? []).contains(aiRecipient)
    }

    public static func grantAIConsent() {
        defaults.set((defaults.stringArray(forKey: "aiConsent") ?? []) + [aiRecipient], forKey: "aiConsent")
    }

    public static var numberRow: Bool {
        get { flag("numberRow", default: false) }
        set { defaults.set(newValue, forKey: "numberRow") }
    }

    /// Set by the keyboard: it can only write here with full access, so this means it has it.
    public static var keyboardHasFullAccess: Bool {
        get { defaults.bool(forKey: "keyboardHasFullAccess") }
        set { defaults.set(newValue, forKey: "keyboardHasFullAccess") }
    }

    /// Set by the keyboard the first time it translates copied text, so the guide's practice ticks.
    public static var readTried: Bool {
        get { defaults.bool(forKey: "readTried") }
        set { defaults.set(newValue, forKey: "readTried") }
    }

    /// Whether the keyboard has said once where to stop iOS asking before each paste.
    public static var pasteTipShown: Bool {
        get { defaults.bool(forKey: "pasteTipShown") }
        set { defaults.set(newValue, forKey: "pasteTipShown") }
    }

    /// The pasteboard's change count already offered, so one copy is offered once.
    public static var lastOfferedPasteboard: Int {
        get { defaults.integer(forKey: "lastOfferedPasteboard") }
        set { defaults.set(newValue, forKey: "lastOfferedPasteboard") }
    }

    private static func language(forKey key: String) -> TranslateLanguage? {
        let code = defaults.string(forKey: key)
        return TranslateLanguage.all.first { $0.code == code }
    }

    public static var provider: AIProvider {
        AIProvider(baseURL: providerKind.fixedBaseURL ?? customBaseURL, model: model, apiKey: apiKey)
    }

    /// Each service keeps its own key.
    public static var apiKey: String {
        get {
            if let key = readKey(keyAccount) { return key }
            guard let shared = readKey(sharedKeyAccount) else { return "" }
            // The old shared key goes only once it is safely in its new place (a locked phone can
            // refuse the write), or it would be lost.
            if writeKey(shared, keyAccount) { writeKey("", sharedKeyAccount) }
            return shared
        }
        set { writeKey(newValue, keyAccount) }
    }

    private static func readKey(_ account: String) -> String? {
        var query = keyQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when [value] is stored (or, empty, removed).
    @discardableResult
    private static func writeKey(_ value: String, _ account: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(keyQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        // Updated in place, so a refused write never leaves the account without its old key.
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updated = SecItemUpdate(keyQuery(account) as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var query = keyQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func keyQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZnKeyboard",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainGroup,
        ]
    }
}

/// Timings from the keyboard, added up across sessions until reset: how long a key took on the
/// main thread, how long the engine took per reading, the memory used and how hot the phone got.
public struct PerfReport: Codable, Equatable {
    public var since = Date()
    public var keys = 0
    public var keyMillis = 0.0
    public var keyMax = 0.0
    /// Keys that took longer than a 60 Hz frame.
    public var slowKeys = 0
    public var decodes = 0
    public var decodeMillis = 0.0
    public var decodeMax = 0.0
    /// The most memory the keyboard used, in megabytes.
    public var memoryPeak = 0.0
    /// ProcessInfo.ThermalState's raw value at its hottest: 0 nominal … 3 critical.
    public var hottest = 0
    /// Times AI 整句排序 was paused because the phone was hot.
    public var thermalPauses = 0

    public init() {}

    public mutating func add(_ more: PerfReport) {
        keys += more.keys
        keyMillis += more.keyMillis
        keyMax = max(keyMax, more.keyMax)
        slowKeys += more.slowKeys
        decodes += more.decodes
        decodeMillis += more.decodeMillis
        decodeMax = max(decodeMax, more.decodeMax)
        memoryPeak = max(memoryPeak, more.memoryPeak)
        hottest = max(hottest, more.hottest)
        thermalPauses += more.thermalPauses
    }
}
