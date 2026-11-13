import Foundation
import PinyinCore

/// Owns the touch models, one per orientation because thumbs sit differently, a letter model for
/// each language, as pinyin spells nothing like English, and their files. Android glue lives in AdaptiveTypingEngine.kt; everything here is main-thread only.
final class AdaptiveTyping {
    private static let portraitFile = "touch_portrait.bin"
    private static let landscapeFile = "touch_landscape.bin"
    private static let lettersFile = "letters_personal.bin"
    private static let pinyinLettersFile = "letters_pinyin.bin"

    private var portrait = TouchModel()
    private var landscape = TouchModel()
    private var isLandscape = false
    private var savedConfirmations = 0
    private let english = CharLanguageModel()
    private let pinyin = CharLanguageModel()
    private(set) lazy var decoder = TouchDecoder(touchModel: { [unowned self] in activeModel }, languageModel: { [unowned self] in activeLetters })
    private(set) lazy var learner = TypingLearner(touchModel: { [unowned self] in activeModel }, languageModel: { [unowned self] in activeLetters }) {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
    var adaptiveEnabled = true
    var chinese = true {
        willSet { if newValue != chinese { learner.flush() } }
    }

    private var activeModel: TouchModel { isLandscape ? landscape : portrait }
    private var activeLetters: CharLanguageModel { chinese ? pinyin : english }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("typing")
    }

    func setLandscape(_ value: Bool) {
        guard value != isLandscape else { return }
        learner.flush()
        isLandscape = value
    }

    func load() {
        func prior(_ name: String) -> Data? { Bundle.main.url(forResource: name, withExtension: "bin").flatMap { try? Data(contentsOf: $0) } }
        english.setPrior(prior("en_char_trigram"))
        pinyin.setPrior(prior("pinyin_char_trigram"))
        func read(_ name: String) -> Data? { try? Data(contentsOf: Self.directory.appendingPathComponent(name)) }
        if let model = read(Self.portraitFile).flatMap(TouchModel.decode) { portrait = model }
        if let model = read(Self.landscapeFile).flatMap(TouchModel.decode) { landscape = model }
        if let letters = read(Self.lettersFile) { _ = english.decodePersonal(letters) }
        if let letters = read(Self.pinyinLettersFile) { _ = pinyin.decodePersonal(letters) }
    }

    /// Encodes what changed here (the models are main-thread only) and writes it on [queue], so
    /// typing never waits for the files.
    func save(on queue: DispatchQueue) {
        learner.flush()
        guard learner.confirmations != savedConfirmations else { return }
        savedConfirmations = learner.confirmations
        let files = [
            (Self.portraitFile, portrait.encode()),
            (Self.landscapeFile, landscape.encode()),
            (Self.lettersFile, english.encodePersonal()),
            (Self.pinyinLettersFile, pinyin.encodePersonal()),
        ]
        queue.async {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for (name, data) in files { try? data.write(to: Self.directory.appendingPathComponent(name), options: .atomic) }
        }
    }
}
