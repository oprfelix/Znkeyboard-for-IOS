import PinyinCore
import UIKit

/// The keyboard extension: a thin view over KeyboardSession.
final class KeyboardViewController: UIInputViewController, TextTarget {
    private let keys = KeyboardKeysView()
    private let grid = CandidateGridView()
    private let saved = SavedTextPanelView()
    /// Which saved texts cover the keys, if any.
    private var savedTab: SavedTextPanelView.Tab?
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
    /// The polished text to put in, and how many characters of the field it replaces (0 for a selection).
    private var replacement: (text: String, replaces: Int)?
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
        saved.onTab = { [weak self] tab in self?.openSaved(tab) }
        saved.onClose = { [weak self] in self?.closeSaved() }
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
        bar.onClipboard = { [weak self] in self?.openSaved(.clipboard) }
        bar.onPhrases = { [weak self] in self?.openSaved(.phrases) }
        grid.onTap = { [weak self] index in self?.session?.tapItem(index) }
        spellingRow.onTap = { [weak self] index in self?.session?.chooseSpelling(index) }
        bar.onExpand = { [weak self] in self?.session?.toggleExpanded() }
        cardHeight = card.heightAnchor.constraint(equalToConstant: 0)
        cardHeight.isActive = true
        card.isHidden = true
        card.clipsToBounds = true
        card.onClose = { [weak self] in self?.closeCard() }
        card.onAction = { [weak self] in self?.cardAction() }
        bar.onPolish = { [weak self] in self?.rewrite(translating: false) }
        bar.onTranslate = { [weak self] in self?.rewrite(translating: true) }
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
        keys.onLetter = { [weak self] text, tap, sample in self?.typed(text, tap, sample) }
        keys.typing = typing
        keys.onMoveCaret = { [weak self] steps in self?.moveCaret(steps) }
        keys.onChooseLayout = { [weak self] nine in self?.chooseLayout(nine) }
        typing.load()
        keys.onGlobe = { [weak self] view, event in self?.handleInputModeList(from: view, with: event) }
        bar.onTap = { [weak self] index in self?.session?.tapItem(index) }
        bar.onFix = { [weak self] in self?.session?.tapFix() }
        loadEngine()
        render()
    }

    /// What the app may have changed since the keyboard was last on screen.
    private func applySettings() {
        if hasFullAccess { SharedSettings.keyboardHasFullAccess = true }
        var haptics: UIImpactFeedbackGenerator?
        if hasFullAccess, SharedSettings.hapticsEnabled {
            haptics = UIImpactFeedbackGenerator(style: .light)
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
        heightConstraint?.constant = keyboardHeight
        updateShift()
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
        session?.onChange = { [weak self] in self?.render() }
    }

    private static var learnedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pinyin-user.txt")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keys.showsGlobe = needsInputModeSwitchKey
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
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        // The window's own tap and pan recognizers made quick taps vanish before reaching the keys.
        for recognizer in view.window?.gestureRecognizers ?? []
        where recognizer is UITapGestureRecognizer || recognizer is UIPanGestureRecognizer || String(describing: type(of: recognizer)).contains("DoubleTap") {
            recognizer.isEnabled = false
        }
        (view.window?.superview?.gestureRecognizers ?? []).forEach { $0.delaysTouchesBegan = false }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pasteboardTimer?.invalidate()
        session?.settleOffer()
        saveLearning()
    }

    private func saveLearning() {
        typing.save()
        session?.settle()
        guard let data = session?.learner.data.encode() else { return }
        try? FileManager.default.createDirectory(at: Self.learnedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.learnedFile, options: .atomic)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let session, !session.isComposing else { return }
        if textDocumentProxy.documentContextBeforeInput != expectedBefore {
            expectedBefore = textDocumentProxy.documentContextBeforeInput
            typing.learner.onContextChanged(expectedBefore)
            session.fieldChanged()
        }
    }

    private func typed(_ text: String, _ tap: [Float]?, _ sample: TypingLearner.Sample?) {
        guard let session else { return }
        hasNewCopy = false
        for character in text {
            typing.learner.onCommitted(character, sample)
            let wasComposing = session.composing
            session.type(character, tap: tap, sample: sample)
            if session.editCaret == nil, session.composing == wasComposing + String(character) {
                if wasComposing.isEmpty { bar.clearLabel() }
                bar.appendToLabel(character)
            }
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
        bar.showsLabel = spellingSize == 0
        spellingRow.show(session.spellings, selected: session.spellingIndex)
        keys.setComposing(session.isComposing, choosingMark: session.offerSelection != nil)
        let expanded = session.expanded && !session.items.isEmpty
        if expanded { grid.show(session.items) }
        if session.isComposing, savedTab != nil { savedTab = nil }
        saved.isHidden = savedTab == nil
        grid.isHidden = !expanded || savedTab != nil
        keys.isHidden = expanded || savedTab != nil
        if !session.isComposing, session.items.isEmpty {
            bar.showTools(languageName: SharedSettings.translateLanguage.chineseName, offering: hasNewCopy)
            return
        }
        bar.show(
            label: session.isComposing ? session.label : "",
            items: session.items,
            fixTitle: session.canFix ? (session.isChoosingWord ? "取消" : (session.editCaret == nil ? "改词" : "完成")) : nil,
            expanded: expanded,
            selected: session.offerSelection
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
        saved.show(tab, tab == .clipboard ? SavedTexts.clipboard : SavedTexts.phrases, note: note)
        render()
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
                body: "润色和翻译会把你选中的文字发给 \(SharedSettings.aiRecipientName)，由它按自己的隐私政策处理。文字不经过 ZnKeyboard 的服务器。同意后，用这个服务时不再询问。",
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

    private func readCopied() {
        hasNewCopy = false
        render()
        guard canUseAI(then: { [weak self] in self?.readCopied() }) else { return }
        let copied = UIPasteboard.general.string
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
        run(title: "译文 · \(language.chineseName)", keepsResult: false) { [client] in
            try await client.read(text, in: language, with: SharedSettings.provider)
        }
    }

    /// Polishes or translates the selection, or else all the text the field shows around the caret.
    private func rewrite(translating: Bool) {
        guard canUseAI(then: { [weak self] in self?.rewrite(translating: translating) }) else { return }
        let proxy = textDocumentProxy
        let selected = proxy.selectedText ?? ""
        let text = selected.isEmpty ? (proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? "") : selected
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showCardMessage("先输入文字，或选中一段文字。")
            return
        }
        let language = SharedSettings.translateLanguage
        replacement = (text, selected.isEmpty ? text.count : 0)
        run(title: translating ? "翻译为 \(language.chineseName)" : "润色", keepsResult: true) { [client] in
            translating ? try await client.translate(text, to: language, with: SharedSettings.provider)
                : try await client.polish(text, with: SharedSettings.provider)
        }
    }

    private func run(title: String, keepsResult: Bool, _ work: @escaping () async throws -> String) {
        request?.cancel()
        card.showWorking(title: title)
        showCard()
        request = Task { @MainActor [weak self] in
            do {
                let result = try await work()
                guard let self, !Task.isCancelled else { return }
                if keepsResult { self.replacement?.text = result }
                self.card.showResult(title: title, body: result, actionTitle: keepsResult ? "替换" : nil)
                self.showCard()
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
        if replacement.replaces > 0 {
            // Only what was read and sent goes: the field's context updates late, so it isn't read again.
            proxy.adjustTextPosition(byCharacterOffset: (proxy.documentContextAfterInput ?? "").count)
            for _ in 0..<replacement.replaces { proxy.deleteBackward() }
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
