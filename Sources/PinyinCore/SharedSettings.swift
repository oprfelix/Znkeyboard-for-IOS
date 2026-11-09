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
            writeKey(shared, keyAccount)
            writeKey("", sharedKeyAccount)
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

    private static func writeKey(_ value: String, _ account: String) {
        SecItemDelete(keyQuery(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var query = keyQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
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
