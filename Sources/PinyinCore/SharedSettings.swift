import Foundation
import Security

/// What the app and the keyboard share: settings in the app group, the API key in the keychain.
public enum SharedSettings {
    public static let appGroup = "group.com.oprfelix.znkeyboard"
    public static let keychainGroup = "6DSHU7W7LQ.com.oprfelix.znkeyboard.shared"

    private static let defaults = UserDefaults(suiteName: appGroup) ?? .standard
    private static let keyAccount = "api-key"

    public static var providerKind: AIProviderKind {
        get { defaults.string(forKey: "provider").flatMap(AIProviderKind.init) ?? .deepSeek }
        set { defaults.set(newValue.rawValue, forKey: "provider") }
    }

    public static var customBaseURL: String {
        get { defaults.string(forKey: "baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "baseURL") }
    }

    public static var model: String {
        get { defaults.string(forKey: "model") ?? providerKind.defaultModel }
        set { defaults.set(newValue, forKey: "model") }
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
        get { defaults.object(forKey: "fuzzyRules") == nil ? .all : FuzzyRules(rawValue: defaults.integer(forKey: "fuzzyRules")) }
        set { defaults.set(newValue.rawValue, forKey: "fuzzyRules") }
    }

    private static func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    public static var hapticsEnabled: Bool {
        get { flag("haptics", default: true) }
        set { defaults.set(newValue, forKey: "haptics") }
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

    public static var apiKey: String {
        get {
            var query = keyQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(keyQuery as CFDictionary)
            guard !newValue.isEmpty else { return }
            var query = keyQuery
            query[kSecValueData as String] = Data(newValue.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static var keyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZnKeyboard",
            kSecAttrAccount as String: keyAccount,
            kSecAttrAccessGroup as String: keychainGroup,
        ]
    }
}
