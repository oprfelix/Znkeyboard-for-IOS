import Foundation
import PinyinCore

/// Owns the touch models, one per orientation because thumbs sit differently, the letter model and
/// their files. Android glue lives in AdaptiveTypingEngine.kt; everything here is main-thread only.
final class AdaptiveTyping {
    private static let portraitFile = "touch_portrait.bin"
    private static let landscapeFile = "touch_landscape.bin"
    private static let lettersFile = "letters_personal.bin"

    private var portrait = TouchModel()
    private var landscape = TouchModel()
    private var isLandscape = false
    private var savedConfirmations = 0
    private let language = CharLanguageModel()
    private(set) lazy var decoder = TouchDecoder(touchModel: { [unowned self] in activeModel }, languageModel: language)
    private(set) lazy var learner = TypingLearner(touchModel: { [unowned self] in activeModel }, languageModel: language) {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
    var adaptiveEnabled = true

    private var activeModel: TouchModel { isLandscape ? landscape : portrait }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("typing")
    }

    func setLandscape(_ value: Bool) {
        guard value != isLandscape else { return }
        learner.flush()
        isLandscape = value
    }

    func load() {
        language.setPrior(Bundle.main.url(forResource: "en_char_trigram", withExtension: "bin").flatMap { try? Data(contentsOf: $0) })
        func read(_ name: String) -> Data? { try? Data(contentsOf: Self.directory.appendingPathComponent(name)) }
        if let model = read(Self.portraitFile).flatMap(TouchModel.decode) { portrait = model }
        if let model = read(Self.landscapeFile).flatMap(TouchModel.decode) { landscape = model }
        if let letters = read(Self.lettersFile) { _ = language.decodePersonal(letters) }
    }

    func save() {
        learner.flush()
        guard learner.confirmations != savedConfirmations else { return }
        savedConfirmations = learner.confirmations
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? portrait.encode().write(to: Self.directory.appendingPathComponent(Self.portraitFile), options: .atomic)
        try? landscape.encode().write(to: Self.directory.appendingPathComponent(Self.landscapeFile), options: .atomic)
        try? language.encodePersonal().write(to: Self.directory.appendingPathComponent(Self.lettersFile), options: .atomic)
    }
}
