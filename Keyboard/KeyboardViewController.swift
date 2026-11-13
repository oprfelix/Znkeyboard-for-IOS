import PinyinCore
import UIKit

/// The keyboard extension: a thin view over KeyboardSession.
final class KeyboardViewController: UIInputViewController, TextTarget {
    private let keys = KeyboardKeysView()
    private let grid = CandidateGridView()
    private let saved = SavedTextPanelView()
    /// Which saved texts cover the keys, if any.
    private var savedTab: SavedTextPanelView.Tab?
    /// The translate languages cover the keys.
    private let languages = LanguagePanelView()
    private var choosingLanguage = false
    private let typing = AdaptiveTyping()
    private var afterConsent: (() -> Void)?
    private let bar = CandidateBarView()
    private let spellingRow = SpellingRowView()
    private var session: KeyboardSession?
    private var heightConstraint: NSLayoutConstraint?
    private var hasMarkedText = false
    private var engineRules = FuzzyRules.all
    private var expectedBefore: String?
    private let card = ReadingCardView()
    private var cardHeight: NSLayoutConstraint!
    /// Something new was copied; it is only read when the offer is tapped, since reading makes
    /// iOS ask for permission.
    private var hasNewCopy = false
    private var pasteboardTimer: Timer?
    /// What a translation will replace: [original] as it was sent, either the selection or (when
    /// [wholeField]) all the text the field showed around the caret; [text] the result once it is in.
    private var replacement: (original: String, wholeField: Bool, text: String)?
    private var request: Task<Void, Never>?
    private let client = AIClient()
    private static let barHeight: CGFloat = 48
    private static let spellingHeight: CGFloat = 38
    private static let multiTapWindow: CFTimeInterval = 0.8
    /// The field shows a few hundred characters before the caret; a long line takes more reads.
    private static let maxLineReads = 8
    private var barHeight: NSLayoutConstraint!
    private var spellingRowHeight: NSLayoutConstraint!
    private var keysHeight: CGFloat { keys.preferredHeight }
    /// Kept in English and on the symbol pages too, so the keyboard doesn't change height.
    private var spellingSize: CGFloat { keys.nineKey ? Self.spellingHeight : 0 }
    private var lastMultiTap: (letters: String, index: Int, upper: Bool, at: CFTimeInterval)?
    private var keyboardHeight: CGFloat { Self.barHeight + keysHeight + spellingSize }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A hot phone slows down; AI 整句排序 rests until it cools.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notePerfThermal()
            self?.syncSentenceScorer()
        }
        // The app being typed in leaving the screen is the last sure moment to write anything.
        for name in [Notification.Name.NSExtensionHostWillResignActive, .NSExtensionHostDidEnterBackground] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistLearning() }
            }
        }
        guard let root = view else { return }
        root.isMultipleTouchEnabled = true
        for item in [card, spellingRow, bar, keys, grid] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        barHeight = bar.heightAnchor.constraint(equalToConstant: Self.barHeight)
        spellingRowHeight = spellingRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            spellingRow.topAnchor.constraint(equalTo: card.bottomAnchor),
            spellingRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            spellingRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            spellingRowHeight,
            bar.topAnchor.constraint(equalTo: spellingRow.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barHeight,
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            grid.topAnchor.constraint(equalTo: keys.topAnchor),
            grid.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: keys.bottomAnchor),
        ])
        grid.isHidden = true
        saved.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(saved)
        NSLayoutConstraint.activate([
            saved.topAnchor.constraint(equalTo: keys.topAnchor),
            saved.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            saved.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            saved.bottomAnchor.constraint(equalTo: keys.bottomAnchor),
        ])
        saved.isHidden = true
        languages.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(languages)
        NSLayoutConstraint.activate([
            languages.topAnchor.constraint(equalTo: keys.topAnchor),
            languages.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            languages.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            languages.bottomAnchor.constraint(equalTo: keys.bottomAnchor),
        ])
        languages.isHidden = true
        languages.onPick = { [weak self] language in
            SharedSettings.translateLanguage = language
            self?.choosingLanguage = false
            self?.render()
        }
        bar.onLanguage = { [weak self] in
            guard let self else { return }
            choosingLanguage.toggle()
            if choosingLanguage { savedTab = nil }
            render()
        }
        saved.onPick = { [weak self] text in
            self?.closeSaved()
            self?.session?.typeLiteral(text)
        }
        saved.onDelete = { [weak self] tab, index in
            if tab == .clipboard { SavedTexts.clipboard.remove(at: index) } else { SavedTexts.phrases.remove(at: index) }
            self?.openSaved(tab)
        }
        saved.onKeep = { [weak self] index in
            if let text = SavedTexts.clipboard[safe: index] { SavedTexts.addPhrase(text) }
            self?.openSaved(.phrases)
        }
        saved.onClear = { [weak self] in
            SavedTexts.clipboard = []
            self?.openSaved(.clipboard)
        }
        bar.onClipboard = { [weak self] in self?.toggleSaved(.clipboard) }
        bar.onPhrases = { [weak self] in self?.toggleSaved(.phrases) }
        bar.onHelp = { [weak self] in self?.toggleSaved(.help) }
        saved.onRead = { [weak self] in self?.readFromBar() }
        grid.onTap = { [weak self] index in self?.session?.tapItem(index) }
        spellingRow.onTap = { [weak self] index in self?.session?.chooseSpelling(index) }
        bar.onExpand = { [weak self] in self?.session?.toggleExpanded() }
        cardHeight = card.heightAnchor.constraint(equalToConstant: 0)
        cardHeight.isActive = true
        card.isHidden = true
        card.clipsToBounds = true
        card.onClose = { [weak self] in self?.closeCard() }
        card.onAction = { [weak self] in self?.cardAction() }
        bar.onTranslate = { [weak self] in self?.rewrite() }
        // As on Android: what is being typed goes in as the first candidate, then the field is translated.
        bar.onQuickTranslate = { [weak self] in
            guard let self, let session else { return }
            if session.isComposing { session.tapItem(0) }
            // The field reports the new text a moment after it goes in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.rewrite() }
        }
        bar.onOffer = { [weak self] in self?.readCopied() }
        bar.onDismissOffer = { [weak self] in
            self?.hasNewCopy = false
            self?.render()
        }
        let height = root.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        (view as? UIInputView)?.allowsSelfSizing = true
        heightConstraint = height
        keys.onKey = { [weak self] key in self?.pressed(key) }
        keys.onKeyTime = { [weak self] ms in self?.noteKeyTime(ms) }
        keys.onLetter = { [weak self] text, tap, sample in self?.typed(text, tap, sample) }
        keys.typing = typing
        keys.onMoveCaret = { [weak self] steps in self?.moveCaret(steps) }
        keys.onBeginPointing = { [weak self] in self?.session?.beginPointing() ?? false }
        keys.onMovePointer = { [weak self] steps in self?.session?.movePointer(steps) }
        keys.onEndPointing = { [weak self] in self?.session?.endPointing() }
        keys.onChooseLayout = { [weak self] nine in self?.chooseLayout(nine) }
        typing.load()
        keys.onGlobe = { [weak self] view, event in self?.handleInputModeList(from: view, with: event) }
        // A pick changes the field like a key does: noted, so the change is not taken for the
        // app's own and the 联想 that follow it are kept.
        bar.onTap = { [weak self] index in
            guard let self, let session else { return }
            session.tapItem(index)
            if !session.isComposing { expectedBefore = textDocumentProxy.documentContextBeforeInput }
        }
        bar.onFix = { [weak self] in self?.session?.tapFix() }
        loadEngine()
        render()
    }

    /// What the app may have changed since the keyboard was last on screen.
    private func applySettings() {
        if hasFullAccess { SharedSettings.keyboardHasFullAccess = true }
        var haptics: UIImpactFeedbackGenerator?
        if hasFullAccess, SharedSettings.hapticsEnabled {
            haptics = UIImpactFeedbackGenerator(style: .medium)
            haptics?.prepare()
        }
        keys.haptics = haptics
        keys.playsSound = hasFullAccess && SharedSettings.keySoundEnabled
        keys.showsPopup = SharedSettings.keyPopupEnabled
        keys.showsNumberRow = SharedSettings.numberRow
        keys.nineKey = SharedSettings.nineKey
        session?.nineKey = SharedSettings.nineKey
        typing.adaptiveEnabled = SharedSettings.adaptiveTouch
        if engineRules != SharedSettings.fuzzyRules {
            saveLearning()
            loadEngine()
        }
        session?.doubleSpacePeriod = SharedSettings.doubleSpacePeriod
        syncSentenceScorer()
        heightConstraint?.constant = keyboardHeight
        updateShift()
    }

    // MARK: AI 整句排序

    /// The character model while AI 整句排序 is on: loaded off the main thread the first time,
    /// then handed to each session.
    private var sentenceScorer: TimedSentenceScorer?
    private var sentenceScorerLoading = false

    private func syncSentenceScorer() {
        if Self.phoneIsHot {
            if !pausedForHeat, sentenceScorer != nil { perf.thermalPauses += 1 }
            pausedForHeat = true
            session?.setSentenceScorer(nil)
            return
        }
        pausedForHeat = false
        guard SharedSettings.aiRerank else {
            saveSentenceScorerStats()
            sentenceScorer = nil
            session?.setSentenceScorer(nil)
            return
        }
        if let sentenceScorer {
            session?.setSentenceScorer(sentenceScorer)
            return
        }
        guard !sentenceScorerLoading,
              let modelPath = Bundle.main.path(forResource: "charlm", ofType: "bin"),
              let vocabPath = Bundle.main.path(forResource: "charlm_vocab", ofType: "txt") else { return }
        sentenceScorerLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let model = CharModel(path: modelPath, vocabPath: vocabPath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sentenceScorerLoading = false
                guard let model, SharedSettings.aiRerank else { return }
                let scorer = TimedSentenceScorer(model)
                self.sentenceScorer = scorer
                self.session?.setSentenceScorer(scorer)
            }
        }
    }

    /// Adds the time spent scoring since the last save to the setting's summary in the app.
    private func saveSentenceScorerStats() {
        guard let (calls, millis) = sentenceScorer?.takeStats() else { return }
        SharedSettings.addAIRerankStats(calls: calls, millis: millis)
    }

    /// English sentences start with a capital.
    private func updateShift() {
        guard let session, session.language == .english, SharedSettings.autoCapitalize else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        keys.setShifted(trimmed.isEmpty || (before.hasSuffix(" ") && ".?!".contains(trimmed.last!)))
    }

    private func loadEngine() {
        let bundle = Bundle.main
        guard let dictPath = bundle.path(forResource: "dict", ofType: "bin"),
              let modelPath = bundle.path(forResource: "lm", ofType: "bin"),
              let dictionary = MappedDictionary(path: dictPath) else { return }
        engineRules = SharedSettings.fuzzyRules
        let lexicon = PinyinLexicon(dictionary: dictionary, model: LanguageModel(path: modelPath), fuzzy: engineRules)
        let data = (try? Data(contentsOf: Self.learnedFile)).flatMap(PinyinUserData.decode) ?? PinyinUserData()
        let learner = PinyinLearner(data: data, lexicon: lexicon)
        let english = bundle.path(forResource: "english", ofType: "txt").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map(EnglishWords.init)
        session = KeyboardSession(lexicon: lexicon, learner: learner, english: english, target: self, decodesInBackground: true, touchLearner: typing.learner)
        session?.onChange = { [weak self] in
            self?.render()
            self?.scheduleSave()
        }
        savedClock = learner.data.clock
        if let sentenceScorer { session?.setSentenceScorer(sentenceScorer) }
    }

    private static var learnedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pinyin-user.txt")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keys.showsGlobe = needsInputModeSwitchKey
        // Each time it comes up it is a keyboard, not the panel left open last time.
        savedTab = nil
        choosingLanguage = false
        applySettings()
        noticeCopied()
        render()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.noticeCopied() }
    }

    // Without these the system holds touches near the screen edges back to see if they are its
    // own gestures, which makes the bottom row and the outer keys lag or drop.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        typing.setLandscape(view.bounds.width > view.bounds.height * 1.5 && view.bounds.width > 500)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.isMultipleTouchEnabled = true
        freeTouches()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The system can add its recognizers after the keyboard appears.
        freeTouches()
    }

    /// The system wraps the keyboard in several views with gesture recognizers of their own; any
    /// that holds a touch back until it decides it isn't its gesture made light, quick taps arrive
    /// late or not at all, so only a firm press typed. Every one above the keyboard lets touches
    /// through at once, and the window's tap and pan recognizers (which ate quick taps) are off.
    private func freeTouches() {
        var ancestor = view.superview
        while let current = ancestor {
            for recognizer in current.gestureRecognizers ?? [] {
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.cancelsTouchesInView = false
                if current === view.window,
                   recognizer is UITapGestureRecognizer || recognizer is UIPanGestureRecognizer || String(describing: type(of: recognizer)).contains("DoubleTap") {
                    recognizer.isEnabled = false
                }
            }
            ancestor = current.superview
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pasteboardTimer?.invalidate()
        // A card left up would come back over another field, its 替换 aimed at text that isn't there.
        if !card.isHidden { closeCard() }
        session?.settleOffer()
        saveLearning()
        saveSentenceScorerStats()
    }

    private func saveLearning() {
        session?.settle()
        persistLearning()
    }

    /// iOS may end the keyboard without a viewWillDisappear (back to the home screen, the app
    /// suspended), so what was learned is written a few seconds after typing stops, not only then.
    private var saveTimer: Timer?
    private var savedClock = 0
    private static let saveDelay: TimeInterval = 3

    private func scheduleSave() {
        guard let clock = session?.learner.data.clock, clock != savedClock else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            self?.persistLearning()
        }
    }

    /// Writes the picks and the touch model as they are, without waiting for a reading in progress.
    private func persistLearning() {
        saveTimer?.invalidate()
        saveTimer = nil
        flushPerf()
        typing.save(on: Self.saveQueue)
        guard let learner = session?.learner, learner.data.clock != savedClock else { return }
        // Encoded here, where the learner lives; written off the main thread, so a key pressed
        // just then doesn't wait for the file.
        let data = learner.data.encode()
        let file = Self.learnedFile
        Self.saveQueue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        savedClock = learner.data.clock
    }

    private static let saveQueue = DispatchQueue(label: "keyboard.save", qos: .utility)

    // MARK: 性能诊断

    private var perf = PerfReport()
    private var pausedForHeat = false

    private static var phoneIsHot: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private func noteKeyTime(_ ms: Double) {
        perf.keys += 1
        perf.keyMillis += ms
        perf.keyMax = max(perf.keyMax, ms)
        if ms > 1000.0 / 60 { perf.slowKeys += 1 }
    }

    private func notePerfThermal() {
        perf.hottest = max(perf.hottest, ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// Adds what was measured since the last time to the app's 性能诊断 page.
    private func flushPerf() {
        if let times = session?.takeDecodeTimes() {
            perf.decodes += times.count
            perf.decodeMillis += times.millis
            perf.decodeMax = max(perf.decodeMax, times.max)
        }
        notePerfThermal()
        perf.memoryPeak = max(perf.memoryPeak, Self.memoryFootprintMB())
        guard perf.keys > 0 || perf.decodes > 0 || perf.thermalPauses > 0 else { return }
        SharedSettings.addPerf(perf)
        perf = PerfReport()
    }

    /// The memory iOS counts against the keyboard's limit, in megabytes.
    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let session, !session.isComposing else { return }
        if textDocumentProxy.documentContextBeforeInput != expectedBefore {
            expectedBefore = textDocumentProxy.documentContextBeforeInput
            typing.learner.onContextChanged(expectedBefore)
            session.fieldChanged()
        }
        refreshTools()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshTools()
    }

    /// 翻译 greys out in an empty field and says 翻译选中 over a selection; only the tools change,
    /// so candidates on the bar are left alone.
    private func refreshTools() {
        guard let session, !session.isComposing, session.items.isEmpty else { return }
        render()
    }

    private func typed(_ text: String, _ tap: [Float]?, _ sample: TypingLearner.Sample?) {
        guard let session else { return }
        hasNewCopy = false
        for character in text {
            typing.learner.onCommitted(character, sample)
            let wasComposing = session.composing
            session.type(character, tap: tap, sample: sample)
            // The first letter puts the bar in place of the tools at once; the candidates follow.
            if wasComposing.isEmpty, !session.composing.isEmpty { bar.beginComposing() }
        }
        afterKey(session)
    }

    /// The layout picked on the keyboard; the app shows it next time it opens.
    private func chooseLayout(_ nine: Bool) {
        SharedSettings.nineKey = nine
        keys.nineKey = nine
        session?.nineKey = nine
        heightConstraint?.constant = keyboardHeight
        render()
    }

    /// Whole characters, worked out from one reading of the field, as it updates late.
    private func moveCaret(_ steps: Int) {
        let proxy = textDocumentProxy
        let text = steps < 0
            ? String((proxy.documentContextBeforeInput ?? "").suffix(-steps))
            : String((proxy.documentContextAfterInput ?? "").prefix(steps))
        guard !text.isEmpty else { return }
        proxy.adjustTextPosition(byCharacterOffset: steps < 0 ? -text.utf16.count : text.utf16.count)
    }

    /// Taps in a row on an English 9-key key step through its letters.
    private func multiTap(_ letters: String, _ session: KeyboardSession) {
        let key = letters.lowercased()
        let now = CACurrentMediaTime()
        var index = 0
        var upper = letters != key
        if let last = lastMultiTap, last.letters == key, now - last.at < Self.multiTapWindow {
            index = (last.index + 1) % key.count
            upper = last.upper
            session.backspace()
        }
        lastMultiTap = (key, index, upper, now)
        let letter = String(Array(key)[index])
        session.type(Character(upper ? letter.uppercased() : letter))
    }

    private func pressed(_ key: KeyboardKeysView.Key) {
        guard let session else { return }
        hasNewCopy = false
        if case .letters = key {} else { lastMultiTap = nil }
        switch key {
        case let .text(text):
            typed(text, nil, nil)
            return
        case let .literal(text):
            text.forEach { typing.learner.onCommitted($0, nil) }
            session.typeLiteral(text)
        case .space:
            typing.learner.onCommitted(" ", nil)
            session.space()
        case .backspace:
            typing.learner.onBackspace()
            session.backspace()
        case .deleteLine:
            typing.learner.onContextChanged(nil)
            deleteLine()
        case .returnKey:
            typing.learner.onCommitted("\n", nil)
            if !session.returnKey() { textDocumentProxy.insertText("\n") }
        case let .digit(digit): session.typeDigit(digit)
        case .punctuation: session.offerPunctuation()
        case .separator: session.separator()
        case .nextSpelling: session.nextSpelling()
        case .emoji: session.offerEmoji()
        case let .letters(letters): multiTap(letters, session)
        case .language: session.toggleLanguage()
        case .nextKeyboard: advanceToNextInputMode()
        }
        afterKey(session)
    }

    private func afterKey(_ session: KeyboardSession) {
        if !session.isComposing { expectedBefore = textDocumentProxy.documentContextBeforeInput }
        keys.setChinese(session.language == .chinese)
        updateShift()
    }

    private func render() {
        guard let session else {
            bar.show(label: "词典没有加载", items: [], fixTitle: nil, expanded: false)
            return
        }
        layoutCard()
        let notice = session.isComposing ? session.notice : ""
        bar.showsLabel = spellingSize == 0 && !notice.isEmpty
        spellingRow.show(session.spellings, selected: session.spellingIndex)
        keys.setComposing(session.isComposing, choosingMark: session.offerSelection != nil)
        let expanded = session.expanded && !session.items.isEmpty
        if expanded { grid.show(session.items) }
        if session.isComposing, savedTab != nil { savedTab = nil }
        if session.isComposing || savedTab != nil || hasNewCopy { choosingLanguage = false }
        let covered = savedTab != nil || choosingLanguage
        saved.isHidden = savedTab == nil
        languages.isHidden = !choosingLanguage
        if choosingLanguage { languages.show(selected: SharedSettings.translateLanguage) }
        grid.isHidden = !expanded || covered
        keys.isHidden = expanded || covered
        if !session.isComposing, session.items.isEmpty {
            let proxy = textDocumentProxy
            let selected = !(proxy.selectedText ?? "").isEmpty
            let field = (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "")
            bar.showTools(languageName: SharedSettings.translateLanguage.chineseName, offering: hasNewCopy, saved: savedTab,
                          choosingLanguage: choosingLanguage,
                          hasText: selected || !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selection: selected)
            return
        }
        bar.show(
            label: notice,
            items: session.items,
            fixTitle: session.canFix ? (session.isChoosingWord ? "取消" : (session.editCaret == nil ? "改词" : "完成")) : nil,
            expanded: expanded,
            selected: session.pointedItem ?? session.offerSelection,
            // Not over a punctuation offer or while picking a word to change.
            translatable: !session.items.isEmpty && session.offerSelection == nil && !session.isChoosingWord
        )
    }

    // MARK: Clipboard and phrases

    /// Reading the clipboard can make iOS ask to paste; it happens only on a tap here.
    private func openSaved(_ tab: SavedTextPanelView.Tab) {
        var note: String?
        if tab == .clipboard {
            if hasFullAccess {
                let board = UIPasteboard.general
                let concealed = board.types.contains("org.nspasteboard.ConcealedType")
                if board.changeCount != SharedSettings.lastSavedPasteboard, board.hasStrings, !concealed, let text = board.string {
                    SavedTexts.remember(text)
                }
                SharedSettings.lastSavedPasteboard = board.changeCount
            } else if SavedTexts.clipboard.isEmpty {
                note = "要记录剪贴板，请在「设置 → 通用 → 键盘 → 键盘 → ZnKeyboard」打开「允许完全访问」。"
            }
        }
        savedTab = tab
        saved.show(tab, tab == .clipboard ? SavedTexts.clipboard : tab == .phrases ? SavedTexts.phrases : [], note: note)
        render()
    }

    /// The bar's icon opens its panel, and closes it when it is already open.
    private func toggleSaved(_ tab: SavedTextPanelView.Tab) {
        if savedTab == tab { closeSaved() } else { openSaved(tab) }
    }

    private func closeSaved() {
        savedTab = nil
        render()
    }

    /// Deletes the line before the caret; at the start of a line, the line break.
    private func deleteLine() {
        session?.discardComposition()
        let proxy = textDocumentProxy
        var first = true
        for _ in 0..<Self.maxLineReads {
            let before = proxy.documentContextBeforeInput ?? ""
            if before.isEmpty { break }
            if before.hasSuffix("\n") {
                if first { proxy.deleteBackward() }
                break
            }
            let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            for _ in 0..<line.count { proxy.deleteBackward() }
            first = false
        }
        expectedBefore = proxy.documentContextBeforeInput
    }

    // MARK: AI

    /// Whether something was copied since the last offer; this much reads nothing and asks nothing.
    private func noticeCopied() {
        guard hasFullAccess else { return }
        let board = UIPasteboard.general
        guard board.changeCount != SharedSettings.lastOfferedPasteboard else { return }
        SharedSettings.lastOfferedPasteboard = board.changeCount
        guard board.hasStrings else { return }
        hasNewCopy = true
        render()
    }

    private func cardAction() {
        guard let retry = afterConsent else {
            applyReplacement()
            return
        }
        SharedSettings.grantAIConsent()
        closeCard()
        retry()
    }

    /// Nothing goes to an AI service before the user has said yes to that service.
    private func canUseAI(then retry: @escaping () -> Void) -> Bool {
        guard hasFullAccess else {
            showCardMessage("请在「设置 → 通用 → 键盘 → 键盘 → ZnKeyboard」打开「允许完全访问」。")
            return false
        }
        guard SharedSettings.provider.isConfigured else {
            showCardMessage("请打开 ZnKeyboard App，填写 API Key。")
            return false
        }
        guard SharedSettings.hasAIConsent else {
            replacement = nil
            afterConsent = retry
            card.showResult(
                title: "发送前请确认",
                body: "翻译会把你选中的文字发给 \(SharedSettings.aiRecipientName)，由它按自己的隐私政策处理。文字不经过 ZnKeyboard 的服务器。同意后，用这个服务时不再询问。",
                actionTitle: "同意"
            )
            showCard()
            return false
        }
        return true
    }

    private func showCardMessage(_ message: String) {
        replacement = nil
        card.showResult(title: "ZnKeyboard", body: message, actionTitle: nil)
        showCard()
    }

    private func showCard() {
        // A card over the clipboard or phrases would be two things at once.
        if savedTab != nil || choosingLanguage {
            savedTab = nil
            choosingLanguage = false
            render()
        }
        card.isHidden = false
        cardHeight.isActive = false
        layoutCard()
    }

    /// The result takes the bar's place; the bar comes back under it while typing the reply.
    private func layoutCard() {
        let showing = !card.isHidden
        let typing = session.map { $0.isComposing || !$0.items.isEmpty } ?? false
        let barShown = !showing || typing
        bar.isHidden = !barShown
        let barSize = barShown ? Self.barHeight : 0
        if barHeight.constant != barSize { barHeight.constant = barSize }
        let cardSize = showing
            ? card.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            : 0
        if spellingRowHeight.constant != spellingSize { spellingRowHeight.constant = spellingSize }
        let height = keysHeight + barSize + cardSize + spellingSize
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    private func closeCard() {
        afterConsent = nil
        request?.cancel()
        replacement = nil
        card.isHidden = true
        cardHeight.isActive = true
        layoutCard()
        render()
    }

    /// What to do first, said where the user looks for it.
    private static let readHowTo = "剪贴板里还没有文字。先在聊天里长按对方发来的外文，点「拷贝」，再回到输入框，键盘上会出现「翻译刚复制的外文」。"

    /// Help's button: translates what was copied, or says how when nothing was.
    private func readFromBar() {
        if hasFullAccess, !UIPasteboard.general.hasStrings {
            showCardMessage(Self.readHowTo)
            return
        }
        readCopied()
    }

    private func readCopied() {
        hasNewCopy = false
        render()
        guard canUseAI(then: { [weak self] in self?.readCopied() }) else { return }
        // A read that waits means iOS asked the user; say once how to stop it asking.
        let started = Date()
        let copied = UIPasteboard.general.string
        let wasAsked = Date().timeIntervalSince(started) > 0.4
        var tip: String?
        if wasAsked, copied != nil, !SharedSettings.pasteTipShown {
            SharedSettings.pasteTipShown = true
            tip = "不想每次都确认？在「设置 › App › ZnKeyboard › 从其他 App 粘贴」选「允许」。"
        }
        if let copied, !UIPasteboard.general.types.contains("org.nspasteboard.ConcealedType") {
            SavedTexts.remember(copied)
            SharedSettings.lastSavedPasteboard = UIPasteboard.general.changeCount
        }
        guard let text = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            showCardMessage("没有读到复制的内容。可在「设置 → App → ZnKeyboard → 从其他 App 粘贴」选「允许」，以后就不用每次确认。")
            return
        }
        let language = SharedSettings.readingLanguage
        guard AIClient.isWorthReading(text, target: language) else {
            showCardMessage("复制的内容已经是\(language.chineseName)，或者不是需要翻译的文字。")
            return
        }
        run(title: "译文 · \(language.chineseName)", keepsResult: false, tip: tip, done: { SharedSettings.readTried = true }) { [client] in
            try await client.read(text, in: language, with: SharedSettings.provider)
        }
    }

    /// Translates the selection, or else all the text the field shows around the caret.
    private func rewrite() {
        guard canUseAI(then: { [weak self] in self?.rewrite() }) else { return }
        let proxy = textDocumentProxy
        let selected = proxy.selectedText ?? ""
        let text = selected.isEmpty ? (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "") : selected
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showCardMessage("先输入文字，或选中一段文字。")
            return
        }
        let language = SharedSettings.translateLanguage
        replacement = (text, selected.isEmpty, text)
        run(title: "翻译 → \(language.chineseName)", keepsResult: true, flows: true) { [client] in
            try await client.translate(text, to: language, with: SharedSettings.provider)
        }
    }

    /// [done] runs once a result has come back.
    /// [flows]: the title's arrow moves while waiting and becomes ✓ with the result.
    private func run(title: String, keepsResult: Bool, tip: String? = nil, flows: Bool = false, done: (() -> Void)? = nil,
                     _ work: @escaping () async throws -> String) {
        request?.cancel()
        card.showWorking(title: title, flows: flows)
        showCard()
        request = Task { @MainActor [weak self] in
            do {
                let result = try await work()
                guard let self, !Task.isCancelled else { return }
                if keepsResult { self.replacement?.text = result }
                let body = tip.map { result + "\n\n" + $0 } ?? result
                self.card.showResult(title: flows ? "✓ " + title : title, body: body, actionTitle: keepsResult ? "替换" : nil)
                self.showCard()
                done?()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.replacement = nil
                self.card.showResult(title: title, body: AIClient.message(for: error, chinese: true), actionTitle: nil)
                self.showCard()
            }
        }
    }

    private func applyReplacement() {
        guard let replacement else { return }
        let proxy = textDocumentProxy
        // Typing, moving the caret or another field since it was sent: replacing now would delete
        // the wrong text, so nothing changes.
        let now = replacement.wholeField
            ? (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "")
            : proxy.selectedText ?? ""
        guard now == replacement.original else {
            self.replacement = nil
            card.showResult(title: "ZnKeyboard", body: "文字已经改动，请重新翻译。", actionTitle: nil)
            showCard()
            return
        }
        if replacement.wholeField {
            // To the end of what was read (UTF-16 offsets, like every caret move here), then back over it.
            proxy.adjustTextPosition(byCharacterOffset: (proxy.documentContextAfterInput ?? "").utf16.count)
            for _ in 0..<replacement.original.count { proxy.deleteBackward() }
        }
        proxy.insertText(replacement.text)
        expectedBefore = proxy.documentContextBeforeInput
        closeCard()
    }

    // MARK: TextTarget

    var textBeforeCaret: String? { textDocumentProxy.documentContextBeforeInput }

    func setMarkedText(_ text: String) {
        if text.isEmpty {
            if hasMarkedText {
                textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                textDocumentProxy.unmarkText()
            }
            hasMarkedText = false
        } else {
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
            hasMarkedText = true
        }
    }

    func commitText(_ text: String) {
        if hasMarkedText {
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
            textDocumentProxy.unmarkText()
            hasMarkedText = false
        } else {
            textDocumentProxy.insertText(text)
        }
    }

    func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }
}

/// The character model, timing each call for AI 整句排序's summary in the app. It runs on the
/// session's decoding queue while the main thread takes the totals, hence the lock.
final class TimedSentenceScorer: SentenceScorer {
    private let model: CharModel
    private let lock = NSLock()
    private var calls = 0
    private var millis = 0.0

    init(_ model: CharModel) { self.model = model }

    func score(_ texts: [String]) -> [Float]? {
        let started = CFAbsoluteTimeGetCurrent()
        let result = model.score(texts)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lock.lock()
        calls += 1
        millis += elapsed
        lock.unlock()
        return result
    }

    /// The calls and milliseconds since the last time.
    func takeStats() -> (Int, Double) {
        lock.lock()
        defer {
            calls = 0
            millis = 0
            lock.unlock()
        }
        return (calls, millis)
    }
}

