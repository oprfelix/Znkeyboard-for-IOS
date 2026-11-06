import Darwin
import PinyinCore
import UIKit

/// The keyboard extension: a thin view over KeyboardSession.
final class KeyboardViewController: UIInputViewController, TextTarget {
    private let keys = KeyboardKeysView()
    private let bar = CandidateBarView()
    private var session: KeyboardSession?
    private var heightConstraint: NSLayoutConstraint?
    private var hasMarkedText = false
    private var expectedBefore: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let root = view else { return }
        for item in [bar, keys] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let height = root.heightAnchor.constraint(equalToConstant: 48 + 4 * KeyboardKeysView.rowHeight + 8)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
        keys.onKey = { [weak self] key in self?.pressed(key) }
        keys.onGlobe = { [weak self] view, event in self?.handleInputModeList(from: view, with: event) }
        bar.onTap = { [weak self] index in self?.session?.tapItem(index) }
        bar.onFix = { [weak self] in self?.session?.tapFix() }
        loadEngine()
        render()
    }

    private func loadEngine() {
        let bundle = Bundle.main
        guard let dictPath = bundle.path(forResource: "dict", ofType: "bin"),
              let modelPath = bundle.path(forResource: "lm", ofType: "bin"),
              let dictionary = MappedDictionary(path: dictPath) else { return }
        let lexicon = PinyinLexicon(dictionary: dictionary, model: LanguageModel(path: modelPath))
        let data = (try? Data(contentsOf: Self.learnedFile)).flatMap(PinyinUserData.decode) ?? PinyinUserData()
        let learner = PinyinLearner(data: data, lexicon: lexicon)
        let english = bundle.path(forResource: "english", ofType: "txt").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map(EnglishWords.init)
        session = KeyboardSession(lexicon: lexicon, learner: learner, english: english, target: self)
        session?.onChange = { [weak self] in self?.render() }
    }

    private static var learnedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pinyin-user.txt")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keys.showsGlobe = needsInputModeSwitchKey
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let data = session?.learner.data.encode() else { return }
        try? FileManager.default.createDirectory(at: Self.learnedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.learnedFile, options: .atomic)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let session, !session.isComposing else { return }
        if textDocumentProxy.documentContextBeforeInput != expectedBefore {
            expectedBefore = textDocumentProxy.documentContextBeforeInput
            session.fieldChanged()
        }
    }

    private func pressed(_ key: KeyboardKeysView.Key) {
        guard let session else { return }
        switch key {
        case let .text(text): text.forEach(session.type)
        case .space: session.space()
        case .backspace: session.backspace()
        case .returnKey:
            if !session.returnKey() { textDocumentProxy.insertText("\n") }
        case .language: session.toggleLanguage()
        case .nextKeyboard: advanceToNextInputMode()
        }
        expectedBefore = textDocumentProxy.documentContextBeforeInput
        keys.setChinese(session.language == .chinese)
    }

    private func render() {
        guard let session else {
            bar.show(label: "词典没有加载", items: [], fixTitle: nil)
            return
        }
        let debug = session.isComposing ? nil : String(format: "内存 %.1f MB，还可用 %.0f MB", Self.footprintMB(), Double(os_proc_available_memory()) / 1_048_576)
        bar.show(
            label: session.isComposing ? session.label : (debug ?? ""),
            items: session.items,
            fixTitle: session.canFix ? (session.isChoosingWord ? "取消" : (session.editCaret == nil ? "改词" : "完成")) : nil
        )
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
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
