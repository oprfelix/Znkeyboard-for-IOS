import Foundation

/// The user's phrases, shared by the app and the keyboard, and what was copied, which stays on this
/// device: it lives in the app group's container, left out of backups.
public enum SavedTexts {
    public static let maxClipboard = 30
    public static let maxPhrases = 100
    /// Beyond this a copy is a document, not a snippet.
    public static let maxLength = 4000

    private static let defaults = UserDefaults(suiteName: SharedSettings.appGroup) ?? .standard

    /// What a new user starts with; once the list is changed, it is theirs, even when empty.
    public static let defaultPhrases = ["马上到！", "我在忙，晚点回复。"]

    public static var phrases: [String] {
        get { defaults.stringArray(forKey: "phrases") ?? defaultPhrases }
        set { defaults.set(Array(newValue.prefix(maxPhrases)), forKey: "phrases") }
    }

    /// Adds [text] to the top of the phrases; false when it was there already.
    @discardableResult
    public static func addPhrase(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phrases.contains(trimmed) else { return false }
        phrases = [trimmed] + phrases
        return true
    }

    private static var clipboardFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedSettings.appGroup)?
            .appendingPathComponent("clipboard.json")
    }

    /// Newest first.
    public static var clipboard: [String] {
        get {
            guard let file = clipboardFile, let data = try? Data(contentsOf: file) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            guard var file = clipboardFile, let data = try? JSONEncoder().encode(Array(newValue.prefix(maxClipboard))) else { return }
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
    }

    /// Puts [text] at the top, moving it there if it was further down.
    public static func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return }
        clipboard = [text] + clipboard.filter { $0 != text }
    }
}
