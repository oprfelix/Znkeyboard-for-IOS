import Foundation

/// The text field the keyboard types into; the extension's UITextDocumentProxy behind it.
public protocol TextTarget: AnyObject {
    var textBeforeCaret: String? { get }
    /// The letters being composed, shown in the field and replaced by the next commit.
    func setMarkedText(_ text: String)
    /// Replaces any marked text.
    func commitText(_ text: String)
    func deleteBackward()
}

/// What the keyboard is doing, apart from any view: every key press goes in here and the bar is
/// drawn from what comes out. The rules follow ZnKeyboardInputMethodService.kt.
public final class KeyboardSession {
    public enum Language { case chinese, english }

    /// The word being changed: [part] is -1 while choosing which.
    struct Fix {
        var part: Int
        var options: [Word]
    }

    public static let hintDuration: TimeInterval = 2.5
    private static let maxPredictions = 16
    private static let doubleSpaceWindow: TimeInterval = 0.7
    private static let contextCharacters = 16
    private static let maxSpellings = 12
    private static let punctuationOffer = ["，", "。", "？", "！", "、", "：", "；", "…", "“", "”", "（", "）"]
    private static let englishPunctuationOffer = [",", ".", "?", "!", "'", "\"", ":", ";", "-", "(", ")", "@"]
    private static let emojiOffer = "😀😂🤣😊😍🥰😘😎🤔😅😭😢😡👍👎👌🙏👏🤝💪❤️🎉🔥✨✅❌⭐️💯🌹🎁📦📮💰💵📈📉☎️📱💻📧📅⏰✈️🚢🚚🏠🏭🌏🇨🇳🇺🇸🍵☕️🍚🍺".map(String.init)
    private static let punctuation: [Character: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；", "(": "（", ")": "）",
    ]

    private let engine: PinyinEngine
    private let lexicon: PinyinLexicon
    private let english: EnglishWords?
    public let learner: PinyinLearner
    private weak var target: TextTarget?

    public private(set) var language: Language = .chinese
    public private(set) var composing = ""
    public private(set) var candidates: [PinyinEngine.Candidate] = []
    public private(set) var predictions: [PinyinLearner.Prediction] = []
    public private(set) var expanded = false
    /// Where letters go while editing the pinyin of a long sentence; nil when not editing it.
    public private(set) var editCaret: Int?
    /// A short note for the bar, shown instead of the pinyin until [clearHint].
    public private(set) var hint: String?
    /// Two quick spaces type a full stop.
    public var doubleSpacePeriod = true
    /// Called whenever anything the bar shows has changed.
    public var onChange: (() -> Void)?
    /// Chinese is typed as digits on 9 keys.
    public var nineKey = false {
        didSet { if nineKey != oldValue { commitRaw() } }
    }
    /// What the digits could spell, for the row above the candidates.
    public private(set) var spellings: [String] = []
    /// The spelling now locked, while the row can still change it.
    public private(set) var spellingIndex: Int?
    private var spellingBase: String?
    private var nineKeyDisplay = ""
    /// What the row lists instead of candidates, and whether it stays open for more picks.
    private var offer: [String]?
    private var offerStays = false
    /// The mark shown in the field and marked in the row, until something settles it.
    public private(set) var offerSelection: Int?
    /// How many marks taps on the marks key step through: ，。？！
    private static let markTaps = 4

    private var lastSpace: Date?
    private var fix: Fix?
    private var fixedSentence: PinyinEngine.Candidate?
    private var fieldContext: SentenceDecoder.Context?
    private var englishRun = false
    private var englishWordJustCommitted = false
    private var englishWordsInARow = 0
    private var composingAfterLatin = false
    private let touchLearner: TypingLearner?

    /// One reading of the letters, handed to [decoding].
    private struct Job {
        let id: Int
        let text: String
        let before: SentenceDecoder.Context?
        let taps: SentenceDecoder.Taps
    }

    private var taps = PinyinTapBuffer()
    private let decoding: DispatchQueue?
    private var nextJob = 0
    /// The newest letters whose candidates are not in yet.
    private var waiting: Job?
    private var running: Int?
    /// Written on [decoding]; read on the main thread once that queue is known to be idle.
    private var decoded: (id: Int, reading: Reading)?

    /// All one reading of the composition gives the keyboard.
    private struct Reading {
        var found: [PinyinEngine.Candidate]
        var whole = false
        var display = ""
        var spellings: [String] = []
    }

    /// With [decodesInBackground] typing never waits for the engine: letters show at once and the
    /// candidates follow. The engine, lexicon and learner are then touched by the main thread only
    /// after [settle], so they never run on two threads at a time.
    public init(lexicon: PinyinLexicon, learner: PinyinLearner, english: EnglishWords?, target: TextTarget, decodesInBackground: Bool = false, touchLearner: TypingLearner? = nil) {
        self.touchLearner = touchLearner
        self.lexicon = lexicon
        self.learner = learner
        self.english = english
        self.target = target
        engine = PinyinEngine(lexicon: lexicon)
        decoding = decodesInBackground ? DispatchQueue(label: "pinyin.decode", qos: .userInteractive) : nil
    }

    // MARK: What the bar shows

    public var isComposing: Bool { !composing.isEmpty }
    public var isChoosingWord: Bool { fix != nil }

    /// The small line above the candidates.
    public var label: String {
        if let hint { return hint }
        if nineKey, language == .chinese { return "" }
        if editCaret != nil { return candidates.first?.text ?? "" }
        if let fix {
            guard fix.part >= 0, let part = parts[safe: fix.part] else { return "点要改的词" }
            return "把「\(part.text)」换成"
        }
        return candidates.first?.spelling?.replacingOccurrences(of: " ", with: "'") ?? composing
    }

    private var parts: [Word] { candidates.first?.parts ?? [] }

    /// What the row of candidates lists now.
    public var items: [String] {
        if let offer { return offer }
        if let fix { return fix.part < 0 ? parts.map(\.text) : fix.options.map(\.text) }
        return composing.isEmpty ? predictions.map(\.text) : candidates.map(\.text)
    }

    /// The 改词 button: shown for a sentence of two or more words, or to leave choosing.
    public var canFix: Bool { !nineKey && (fix != nil || (parts.count >= 2 && editCaret == nil)) }

    // MARK: Keys

    /// [tap] is how the touch fitted each letter key, and [sample] its record for the learner.
    public func type(_ character: Character, tap: [Float]? = nil, sample: TypingLearner.Sample? = nil) {
        lastSpace = nil
        closeOffer()
        guard language == .chinese else {
            target?.commitText(String(character))
            return
        }
        let wasEnglishRun = englishRun
        if !character.isLetter || !character.isASCII { englishRun = false }
        if character.isASCII, character.isUppercase {
            if isComposing { commitWholeTop() }
            englishRun = true
            learner.breakChain()
            predictions = []
            target?.commitText(String(character))
            changed()
            return
        }
        if character.isASCII, character.isLetter {
            if wasEnglishRun, !isComposing {
                target?.commitText(String(character))
                return
            }
            if isComposing, let at = editCaret {
                editCaret = at + 1
                update(insert(character, at: at))
            } else {
                update(composing + String(character), tap: tap, sample: sample)
            }
            return
        }
        if character == "'", isComposing {
            if !composing.hasSuffix("'") { update(composing + "'") }
            return
        }
        if isComposing {
            settle()
            if let digit = character.wholeNumberValue, digit >= 1, digit <= candidates.count, editCaret == nil {
                select(digit - 1, byHand: true)
                return
            }
            commitWholeTop()
        }
        learner.breakChain()
        predictions = []
        target?.commitText(punctuationFor(character) ?? String(character))
        changed()
    }

    /// A digit key of the 9-key keyboard.
    public func typeDigit(_ digit: Character) {
        lastSpace = nil
        closeOffer()
        englishRun = false
        leaveSpelling()
        update(composing + String(digit))
    }

    /// The 9-key keyboard's ^^ key: 分隔 inside a composition.
    public func separator() {
        leaveSpelling()
        if isComposing {
            if !composing.hasSuffix("'") { update(composing + "'") }
        } else {
            typeLiteral("^_^")
        }
    }

    /// Locks spelling [index]; with nothing left to spell, another one can still replace it.
    public func chooseSpelling(_ index: Int) {
        settle()
        guard let spelling = spellings[safe: index] else { return }
        let base = spellingBase ?? composing
        let locked = NineKey.lock(base, spelling)
        guard locked != base else { return }
        let finished = NineKey.isSpelled(locked)
        spellingBase = finished ? base : nil
        spellingIndex = finished ? index : nil
        update(locked)
    }

    /// The 选拼音 key: the next spelling.
    public func nextSpelling() {
        settle()
        if spellings.isEmpty { return }
        chooseSpelling(((spellingIndex ?? -1) + 1) % spellings.count)
    }

    /// The marks key: lists them in the row of candidates.
    public func offerPunctuation() {
        if let selected = offerSelection, let marks = offer {
            select(mark: (selected + 1) % Self.markTaps, in: marks)
            return
        }
        if isComposing { commitWholeTop() }
        closeOffer()
        offerStays = false
        predictions = []
        select(mark: 0, in: language == .chinese ? Self.punctuationOffer : Self.englishPunctuationOffer)
    }

    private func select(mark index: Int, in marks: [String]) {
        offer = marks
        offerSelection = index
        target?.setMarkedText(marks[index])
        changed()
    }

    /// Puts in the mark waiting in the field, as when the keyboard goes away.
    public func settleOffer() {
        guard offerSelection != nil else { return }
        closeOffer()
        changed()
    }

    /// The emoji key: a sheet of them, open until closed. iOS gives keyboards no way to its own.
    public func offerEmoji() {
        if isComposing { commitWholeTop() }
        closeOffer()
        offer = Self.emojiOffer
        offerStays = true
        expanded = true
        predictions = []
        changed()
    }

    /// [keep] false takes a waiting mark back out of the field instead.
    private func closeOffer(keep: Bool = true) {
        if offer != nil { expanded = false }
        if let selected = offerSelection, let mark = offer?[safe: selected] {
            offerSelection = nil
            if keep {
                target?.commitText(mark)
                learner.breakChain()
            } else {
                target?.setMarkedText("")
            }
        }
        offer = nil
        offerStays = false
    }

    private func leaveSpelling() {
        spellingBase = nil
        spellingIndex = nil
    }

    /// [text] as it is, with no Chinese punctuation put in its place.
    public func typeLiteral(_ text: String) {
        lastSpace = nil
        closeOffer()
        englishRun = false
        if isComposing { commitWholeTop() }
        learner.breakChain()
        predictions = []
        target?.commitText(text)
        changed()
    }

    public func space() {
        settle()
        if offerSelection != nil {
            closeOffer()
            changed()
            return
        }
        closeOffer()
        englishRun = false
        if editCaret != nil {
            editCaret = nil
            changed()
        } else if isComposing {
            if candidates.isEmpty { commitRaw() } else { select(0, byHand: false) }
        } else {
            learner.breakChain()
            predictions = []
            let now = Date()
            if doubleSpacePeriod, let last = lastSpace, now.timeIntervalSince(last) < Self.doubleSpaceWindow,
               let before = target?.textBeforeCaret, before.hasSuffix(" "),
               let mark = before.dropLast().last, !mark.isWhitespace, !mark.isPunctuation {
                target?.deleteBackward()
                target?.commitText(language == .chinese ? "。" : ". ")
                lastSpace = nil
            } else {
                target?.commitText(" ")
                lastSpace = now
            }
            changed()
        }
    }

    public func backspace() {
        if offerSelection != nil {
            closeOffer(keep: false)
            changed()
            return
        }
        closeOffer()
        guard isComposing else {
            settle()
            englishRun = false
            learner.breakChain()
            predictions = []
            target?.deleteBackward()
            changed()
            return
        }
        if let at = editCaret {
            if at > 0 {
                editCaret = at - 1
                update(remove(at: at - 1))
            }
            return
        }
        if nineKey {
            leaveSpelling()
            update(NineKey.backspace(composing))
        } else {
            update(String(composing.dropLast()))
        }
    }

    /// Return: the typed letters go in as they are; otherwise the host app's newline or send.
    public func returnKey() -> Bool {
        settle()
        if offerSelection != nil {
            closeOffer()
            changed()
            return true
        }
        closeOffer()
        englishRun = false
        guard isComposing else { return false }
        commitRaw()
        return true
    }

    public func toggleLanguage() {
        settle()
        closeOffer()
        commitRaw()
        englishRun = false
        learner.breakChain()
        predictions = []
        language = language == .chinese ? .english : .chinese
        changed()
    }

    /// The caret moved or the field changed by something other than this keyboard.
    public func fieldChanged() {
        settle()
        learner.breakChain()
        predictions = []
        englishRun = false
        changed()
    }

    // MARK: Candidates

    /// A tap on the row at [index], whatever it lists now.
    public func tapItem(_ index: Int) {
        settle()
        if let offer {
            guard let mark = offer[safe: index] else { return }
            if !offerStays {
                offerSelection = index
                self.offer = offer
                closeOffer()
                predictions = []
                changed()
            } else {
                target?.commitText(mark)
            }
        } else if let current = fix {
            pickFix(current, index)
        } else if isComposing {
            select(index, byHand: true)
        } else if let prediction = predictions[safe: index] {
            target?.commitText(prediction.text)
            expanded = false
            learner.onPredictionPicked(prediction)
            predictions = learner.predictions(limit: Self.maxPredictions)
            changed()
        }
    }

    /// A long press forgets what was learned about this candidate; dictionary words stay.
    public func longPressItem(_ index: Int) {
        settle()
        guard fix == nil else { return }
        if isComposing, let word = candidates[safe: index], word.id == PinyinEngine.englishId {
            if english?.forget(word.text) == true {
                showHint("已删除学习记录：\(word.text)")
                update(composing)
            } else {
                showHint("这个词没有学习记录，不用删除。")
            }
            return
        }
        let texts: [String]
        if isComposing {
            guard let candidate = candidates[safe: index] else { return }
            texts = (candidate.parts?.map(\.text) ?? [candidate.text]).filter(lexicon.isLearned)
        } else {
            texts = predictions[safe: index].map { [$0.text] } ?? []
        }
        if texts.isEmpty {
            showHint("这个词没有学习记录，不用删除。")
            return
        }
        texts.forEach(learner.forget)
        showHint("已删除学习记录：\(texts.joined(separator: "、"))")
        if isComposing { update(composing) } else { predictions = learner.predictions(limit: Self.maxPredictions); changed() }
    }

    public func toggleExpanded() {
        settle()
        if offerStays {
            closeOffer()
            changed()
            return
        }
        expanded.toggle()
        changed()
    }

    /// The 改词 button, which also reads 取消 and 完成.
    public func tapFix() {
        settle()
        if editCaret != nil {
            editCaret = nil
        } else if fix == nil {
            fix = Fix(part: -1, options: [])
            expanded = false
        } else {
            fix = nil
        }
        changed()
    }

    public func editPinyin() {
        settle()
        guard isComposing else { return }
        fix = nil
        expanded = false
        editCaret = composing.utf8.count
        changed()
    }

    public func moveCaret(_ offset: Int) {
        guard editCaret != nil else { return }
        editCaret = min(max(offset, 0), composing.utf8.count)
        changed()
    }

    public func clearHint() {
        hint = nil
        changed()
    }

    // MARK: Inside

    private func pickFix(_ current: Fix, _ index: Int) {
        guard let sentence = candidates.first else { return }
        if current.part < 0 {
            guard let part = parts[safe: index] else { return }
            let options = engine.alternatives(part)
            if options.isEmpty {
                showHint("这个词没有其他读法相同的词。")
                return
            }
            fix = Fix(part: index, options: options)
        } else {
            guard let word = current.options[safe: index] else { return }
            let fixed = engine.withPart(sentence, current.part, word)
            candidates = [fixed] + candidates.dropFirst().filter { $0.text != fixed.text }
            fixedSentence = fixed
            fix = nil
        }
        changed()
    }

    private func showHint(_ text: String) {
        hint = text
        changed()
    }

    private func insert(_ character: Character, at offset: Int) -> String {
        var letters = Array(composing)
        letters.insert(character, at: offset)
        return String(letters)
    }

    private func remove(at offset: Int) -> String {
        var letters = Array(composing)
        letters.remove(at: offset)
        return String(letters)
    }

    private func update(_ text: String, tap: [Float]? = nil, sample: TypingLearner.Sample? = nil) {
        taps.follow(composing, text, tap: tap, token: sample)
        fix = nil
        fixedSentence = nil
        expanded = false
        if composing.isEmpty || text.isEmpty { editCaret = nil }
        if composing.isEmpty || text.isEmpty { settle() }
        if composing.isEmpty {
            let before = target?.textBeforeCaret ?? ""
            fieldContext = lexicon.contextBefore(String(before.suffix(Self.contextCharacters)))
            composingAfterLatin = englishWordJustCommitted || (before.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false)
        }
        composing = text
        if text.isEmpty {
            candidates = []
            spellings = []
            leaveSpelling()
            target?.setMarkedText("")
        } else {
            // 9-key digits show as the pinyin they spell, once that is worked out.
            if !nineKey { target?.setMarkedText(text) }
            predictions = []
            nextJob += 1
            let job = Job(id: nextJob, text: text, before: learner.context ?? fieldContext, taps: taps.snapshot)
            if decoding == nil {
                show(read(job))
                changed()
                return
            }
            waiting = job
            if running == nil { start(job) }
            return
        }
        predictions = []
        changed()
    }

    private func start(_ job: Job) {
        running = job.id
        decoding?.async { [self] in
            let reading = read(job)
            decoded = (job.id, reading)
            DispatchQueue.main.async { [self] in finished(job.id, reading) }
        }
    }

    private func read(_ job: Job) -> Reading {
        guard nineKey else {
            return Reading(found: engine.candidates(job.text, before: job.before, taps: job.taps), whole: PinyinEngine.isWholePinyin(job.text, lexicon))
        }
        let found = engine.nineKeyCandidates(job.text, before: job.before)
        return Reading(
            found: found,
            display: NineKey.display(job.text, lexicon, top: found.first),
            spellings: Array(NineKey.spellings(job.text, lexicon).prefix(Self.maxSpellings))
        )
    }

    private func finished(_ id: Int, _ reading: Reading) {
        guard running == id else { return }
        running = nil
        guard let job = waiting else { return }
        if job.id == id {
            waiting = nil
            show(reading)
            changed()
        } else {
            start(job)
        }
    }

    private func show(_ reading: Reading) {
        guard nineKey else {
            candidates = english?.merge(composing, reading.found, whole: reading.whole) ?? reading.found
            return
        }
        candidates = reading.found
        nineKeyDisplay = reading.display
        if spellingBase == nil { spellings = reading.spellings }
        target?.setMarkedText(reading.display)
    }

    /// Waits for the engine and brings the candidates up to the letters typed, so what follows
    /// sees the right ones and has the engine, lexicon and learner to itself.
    public func settle() {
        if running != nil { decoding?.sync {} }
        running = nil
        guard let job = waiting else { return }
        waiting = nil
        if let done = decoded, done.id == job.id {
            show(done.reading)
        } else {
            show(read(job))
        }
    }

    private func select(_ index: Int, byHand: Bool) {
        settle()
        guard let candidate = candidates[safe: index] else { return }
        let learnedByHand = byHand || candidate.text == fixedSentence?.text
        fix = nil
        editCaret = nil
        expanded = false
        let letters = Array(composing)
        // A reading that took a tap as another key teaches the touch model that key (wl → wo).
        if !nineKey, let spelling = candidate.spelling {
            for (at, letter) in PinyinTapBuffer.substitutions(String(letters.prefix(candidate.consumed)), spelling) {
                if let sample = taps.token(at: at) { touchLearner?.correct(sample, Int(letter) - 97) }
            }
        }
        leaveSpelling()
        var rest = letters.dropFirst(min(candidate.consumed, letters.count))
        while rest.first == "'" { rest = rest.dropFirst() }
        let isEnglish = candidate.id == PinyinEngine.englishId
        target?.commitText(isEnglish && composingAfterLatin ? " \(candidate.text)" : candidate.text)
        englishWordJustCommitted = isEnglish
        englishWordsInARow = isEnglish ? englishWordsInARow + 1 : 0
        if isEnglish {
            learner.breakChain()
            if learnedByHand { english?.picked(candidate.text) }
        } else if let parts = candidate.parts {
            for part in parts { learner.onPick(part.text, part.syllables, byHand: learnedByHand, id: part.id) }
        } else {
            learner.onPick(candidate.text, candidate.syllables, byHand: learnedByHand, id: candidate.id)
        }
        if rest.isEmpty {
            learner.onCompositionDone()
            taps.follow(composing, "", tap: nil, token: nil)
            composing = ""
            candidates = []
            spellings = []
            predictions = learner.predictions(limit: Self.maxPredictions)
            changed()
        } else {
            update(String(rest))
        }
    }

    private func commitWholeTop() {
        var guardCount = composing.count
        while isComposing, guardCount > 0 {
            guardCount -= 1
            settle()
            if candidates.isEmpty {
                commitRaw()
                return
            }
            select(0, byHand: false)
        }
    }

    private func commitRaw() {
        settle()
        guard isComposing else { return }
        target?.commitText((nineKey ? nineKeyDisplay : composing).replacingOccurrences(of: "'", with: ""))
        learner.onCompositionAbandoned()
        taps.follow(composing, "", tap: nil, token: nil)
        composing = ""
        candidates = []
        spellings = []
        leaveSpelling()
        predictions = []
        fix = nil
        editCaret = nil
        expanded = false
        changed()
    }

    private func punctuationFor(_ character: Character) -> String? {
        englishWordJustCommitted = false
        let inEnglishPhrase = englishWordsInARow >= 2
        englishWordsInARow = 0
        if inEnglishPhrase { return nil }
        if character == ".", target?.textBeforeCaret?.last?.isNumber == true { return nil }
        return Self.punctuation[character]
    }

    private func changed() { onChange?() }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
