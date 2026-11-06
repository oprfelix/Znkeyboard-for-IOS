import Foundation
import PinyinCore

// Checks that need no network or device: swift run -c release checks <dict.bin> <lm.bin> <bench.tsv> <kotlin --learn cases.tsv>
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
    print(ok ? "ok  " : "FAIL", name, ok ? "" : "\(detail)")
    if !ok { failures += 1 }
}

/// Answers every request from [StubProtocol.replies], recording what was sent.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = stream.read(&bytes, maxLength: bytes.count)
            data = Data(bytes.prefix(max(count, 0)))
            stream.close()
        }
        if let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.bodies.append(body) }
        let (code, text) = Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

func reply(_ text: String) -> String {
    let content = String(data: try! JSONSerialization.data(withJSONObject: ["text": text]), encoding: .utf8)!
    let root: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": content]]]]
    return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
}

func aiChecks() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = AIClient(session: URLSession(configuration: config), busyDelaysMs: [1, 1])
    let provider = AIProvider(baseURL: "https://api.example.com/", model: "m", apiKey: "test-key")
    StubProtocol.replies = [(200, reply("Hello there."))]
    let text = try? await client.polish("helo", with: provider)
    check("polish returns the text", text == "Hello there.", text as Any)
    check("address and key", StubProtocol.requests.last?.url?.absoluteString == "https://api.example.com/chat/completions" &&
        StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let system = ((StubProtocol.bodies.last?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    check("polish uses the rewrite prompt", system.contains("rewrite assistant"), system.prefix(60))
    StubProtocol.replies = [(200, reply("Hola."))]
    _ = try? await client.translate("你好", to: TranslateLanguage.all[3], with: provider)
    let translated = ((StubProtocol.bodies.last?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    check("translate names the language", translated.contains("written in Spanish") && !translated.contains("{language}"))
    StubProtocol.replies = [(200, reply("Hi"))]
    _ = try? await client.read("你好吗", in: TranslateLanguage.all[1], with: provider)
    let read = ((StubProtocol.bodies.last?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    check("Chinese reads as English", read.contains("English"), read.prefix(80))
    StubProtocol.replies = [(503, "busy"), (503, "busy"), (200, reply("Done"))]
    let retried = try? await client.polish("x", with: provider)
    check("busy provider is tried again", retried == "Done", retried as Any)
    StubProtocol.replies = [(400, "response_format is not supported"), (200, reply("Plain"))]
    let fallback = try? await client.polish("x", with: provider)
    check("falls back from json_schema", fallback == "Plain" && (StubProtocol.bodies.last?["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    StubProtocol.replies = [(401, "bad key")]
    do { _ = try await client.polish("x", with: provider); check("401 throws", false) } catch {
        check("401 says the key", AIClient.message(for: error, chinese: true).contains("API Key"))
    }
    StubProtocol.replies = [(200, "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"{\"}}]}")]
    do { _ = try await client.polish("x", with: provider); check("cut off throws", false) } catch {
        check("cut off is too long", (error as? AIError) == .tooLong)
    }
    do { _ = try await client.polish("x", with: AIProvider(baseURL: "http://x.test", model: "m", apiKey: "k")); check("http refused", false) } catch {
        check("http refused", (error as? AIError) == .badAddress)
    }
    StubProtocol.replies = [(200, "{\"data\":[{\"id\":\"models/gemini-x\"},{\"id\":\"text-embedding-1\"},{\"id\":\"deepseek-flash\"}]}")]
    let listed = (try? await client.models(provider)) ?? []
    check("model list drops the unusable", listed == ["deepseek-flash", "gemini-x"], listed)
    check("worth reading", AIClient.isWorthReading("Hello there", target: TranslateLanguage.all[1]))
    check("Chinese not offered", !AIClient.isWorthReading("你好世界", target: TranslateLanguage.all[1]))
    check("links not offered", !AIClient.isWorthReading("https://a.com/1", target: TranslateLanguage.all[1]))
}

func learningChecks(_ args: [String]) {
    guard let dict = MappedDictionary(path: args[1]), let model = LanguageModel(path: args[2]) else { fatalError("load") }
    let lexicon = PinyinLexicon(dictionary: dict, model: model)
    let engine = PinyinEngine(lexicon: lexicon)
    let learner = PinyinLearner(data: PinyinUserData(), lexicon: lexicon)
    func top(_ input: String) -> [String] { engine.candidates(input).prefix(8).map(\.text) }
    check("建设 starts behind", top("js").first != "建设", top("js"))
    for _ in 0..<3 { learner.onPick("建设", ["jian", "she"], byHand: true); learner.onCompositionDone(); learner.breakChain() }
    check("picks move 建设 first", top("js").first == "建设", top("js"))
    learner.forget("建设")
    check("forgetting moves it back", top("js").first != "建设", top("js"))
    let context = lexicon.matches([LexiconPiece("js", isPrefix: true)], limit: 1)
    _ = context
    let restored = PinyinUserData.decode(learner.data.encode())
    check("user data round-trips", restored != nil)

    // The same run as Kotlin's --learn: full pinyin in order, picking the right words each time.
    let bench = try! String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n")
    var pinyin: [String: String] = [:]
    for line in bench where !line.hasPrefix("#") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if f.count >= 5, f[0] == "full" { pinyin[f[2]] = f[4] }
    }
    guard let fresh = MappedDictionary(path: args[1]), let freshModel = LanguageModel(path: args[2]) else { fatalError("load") }
    let lexicon2 = PinyinLexicon(dictionary: fresh, model: freshModel)
    let engine2 = PinyinEngine(lexicon: lexicon2)
    let learner2 = PinyinLearner(data: PinyinUserData(), lexicon: lexicon2)
    func expectedWords(_ text: String, _ syllables: [String]) -> [Word]? {
        let characters = Array(text)
        guard syllables.count == characters.count else { return nil }
        var best = [[Word]?](repeating: nil, count: syllables.count + 1)
        best[0] = []
        for start in syllables.indices {
            guard let here = best[start] else { continue }
            for end in (start + 1)...min(syllables.count, start + 6) {
                let pieces = syllables[start..<end].map { LexiconPiece($0, isPrefix: false) }
                let piece = String(characters[start..<end])
                guard let match = lexicon2.matches(pieces, limit: 200).first(where: { $0.word.text == piece }) else { continue }
                if best[end] == nil || best[end]!.count > here.count + 1 { best[end] = here + [match.word] }
            }
        }
        return best[syllables.count]
    }
    var cases = 0, same = 0, shown = 0
    for line in try! String(contentsOfFile: args[4], encoding: .utf8).split(separator: "\n").dropFirst() {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, f[0] == "full", let spelled = pinyin[f[2]] else { continue }
        let found = engine2.candidates(f[2])
        let mine = found.first { $0.consumed >= f[2].utf8.count }?.text ?? ""
        cases += 1
        if mine == f[4] { same += 1 } else if shown < 8 { shown += 1; print("  diff", f[2], "kt:", f[4], "swift:", mine) }
        let right = found.first?.text == f[3] && (found.first?.consumed ?? 0) >= f[2].utf8.count
        for word in expectedWords(f[3], spelled.split(separator: " ").map(String.init)) ?? [] {
            learner2.onPick(word.text, word.syllables, byHand: !right, id: word.id)
        }
        learner2.onCompositionDone()
        learner2.breakChain()
    }
    check("learning run matches Android (\(same)/\(cases))", same == cases)
}

/// A text field in memory, with marked text like a real one.
final class FakeField: TextTarget {
    var text = ""
    var marked = ""
    var textBeforeCaret: String? { text }
    func setMarkedText(_ text: String) { marked = text }
    func commitText(_ text: String) { marked = ""; self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

func fuzzyChecks(_ args: [String]) {
    guard let dict = MappedDictionary(path: args[1]), let model = LanguageModel(path: args[2]) else { fatalError("load") }
    let strict = PinyinEngine(lexicon: PinyinLexicon(dictionary: dict, model: model, fuzzy: []))
    let loose = PinyinEngine(lexicon: PinyinLexicon(dictionary: dict, model: model, fuzzy: .all))
    let plain = strict.candidates("shang").prefix(20).map(\.text)
    let folded = loose.candidates("san").prefix(20).map(\.text)
    check("fuzzy on finds 上 for san", folded.contains("上"), folded)
    check("fuzzy off keeps san apart", !strict.candidates("san").prefix(20).map(\.text).contains("上") && plain.contains("上"))
}

func sessionChecks(_ args: [String]) {
    guard let dict = MappedDictionary(path: args[1]), let model = LanguageModel(path: args[2]) else { fatalError("load") }
    let lexicon = PinyinLexicon(dictionary: dict, model: model)
    let learner = PinyinLearner(data: PinyinUserData(), lexicon: lexicon)
    let words = try! String(contentsOfFile: "Sources/PinyinCore/Resources/english.txt", encoding: .utf8)
    let field = FakeField()
    let session = KeyboardSession(lexicon: lexicon, learner: learner, english: EnglishWords(words: words), target: field)
    func typed(_ text: String) { text.forEach { session.type($0) } }
    func reset() { while session.isComposing { session.backspace() }; field.text = ""; session.fieldChanged() }

    let backgroundField = FakeField()
    let background = KeyboardSession(lexicon: lexicon, learner: learner, english: EnglishWords(words: words), target: backgroundField, decodesInBackground: true)
    "wogenniyikuaichifan".forEach { background.type($0) }
    check("background letters show at once", backgroundField.marked == "wogenniyikuaichifan" && background.composing == "wogenniyikuaichifan")
    background.settle()
    typed("wogenniyikuaichifan")
    check("background reads as the foreground", background.candidates.map(\.text) == session.candidates.map(\.text), background.candidates.first?.text as Any)
    background.backspace()
    background.backspace()
    background.space()
    check("space waits for the candidates", !background.isComposing && backgroundField.text.hasPrefix("我跟你一块"), backgroundField.text)
    reset()

    typed("nihao")
    check("letters are marked", field.marked == "nihao" && session.label == "nihao", session.label)
    session.space()
    check("space commits the top", field.text == "你好" && !session.isComposing, field.text)
    check("predictions follow a commit", !session.predictions.isEmpty)
    session.type(",")
    check("Chinese comma", field.text == "你好，", field.text)
    typed("women"); session.backspace(); session.backspace()
    check("backspace edits the letters", session.composing == "wom", session.composing)
    reset()

    typed("wogenniyikuaichfan")
    check("slip corrected", session.candidates.first?.text == "我跟你一块吃饭", session.candidates.first?.text as Any)
    session.editPinyin()
    let offset = Array("wogenniyikuaich").count
    session.moveCaret(offset)
    session.type("i")
    check("letter inserted at the caret", session.composing == "wogenniyikuaichifan" && session.editCaret == offset + 1, session.composing)
    session.backspace()
    check("backspace at the caret", session.composing == "wogenniyikuaichfan", session.composing)
    session.tapFix()
    check("done leaves editing", session.editCaret == nil)
    reset()

    typed("womenxiawukaihui")
    let sentence = session.candidates.first?.text ?? ""
    session.tapFix()
    check("choosing a word lists the parts", session.isChoosingWord && session.items.count >= 2, session.items)
    session.tapItem(0)
    check("a word with no others says so in the bar", session.label.contains("没有其他"), session.label)
    session.clearHint()
    for index in 1..<session.items.count where !session.label.hasPrefix("把「") { session.tapItem(index); session.clearHint() }
    check("alternatives listed", session.label.hasPrefix("把「"), session.label)
    session.tapItem(0)
    check("swap changes the sentence", session.candidates.first?.text != sentence && !session.isChoosingWord, session.candidates.first?.text as Any)
    session.space()
    check("the fixed sentence is committed", field.text.count == sentence.count, field.text)
    reset()

    typed("wandian"); session.space()
    typed("baojiadan")
    let firstPick = session.items.first ?? ""
    session.tapItem(0)
    check("tap commits the candidate", field.text.hasSuffix(firstPick), field.text)
    reset()

    typed("meeting")
    check("English word offered", session.items.contains("meeting"), session.items.prefix(4))
    let at = session.items.firstIndex(of: "meeting") ?? 0
    session.tapItem(at)
    typed("nihao"); session.space()
    check("English word committed", field.text.hasPrefix("meeting"), field.text)
    reset()

    session.type("I")
    session.type("t")
    check("capital starts English", field.text == "It" && !session.isComposing, field.text)
    session.space()
    check("space ends it", field.text == "It ", field.text)
    typed("ni")
    check("pinyin again", session.isComposing, field.text)
    reset()

    typed("nihao")
    check("return puts the letters in", session.returnKey() && field.text == "nihao", field.text)
    check("return passes on when idle", !session.returnKey())
    reset()

    session.toggleLanguage()
    typed("hi.")
    check("English keyboard types directly", field.text == "hi.", field.text)
    session.toggleLanguage()
    reset()

    typed("123")
    check("digits go in", field.text == "123", field.text)
    session.type(".")
    check("a dot after digits stays a dot", field.text == "123.", field.text)
    reset()

    typed("ni"); session.space(); session.space(); session.space()
    check("two spaces make a full stop", field.text.hasSuffix("。"), field.text)
    reset()

    typed("xi'an")
    check("separator kept", session.composing == "xi'an" && session.candidates.first?.text == "西安", session.candidates.first?.text as Any)
    session.space()
    check("separator not typed", field.text == "西安", field.text)
    reset()

    field.text = "这项"
    typed("js")
    check("text before the caret guides 简拼", session.candidates.first?.text == "技术", session.candidates.first?.text as Any)
    reset()
    typed("jjfa")
    check("initials word leads", session.candidates.first?.text == "解决方案", session.candidates.first?.text as Any)
    reset()

    typed("nihao")
    session.longPressItem(0)
    check("nothing to forget says so", session.label.contains("没有学习记录") || session.label.contains("已删除"), session.label)
    session.clearHint()
    reset()
    check("backspace deletes in the field", { field.text = "你好"; session.backspace(); return field.text == "你" }(), field.text)
}

let arguments = CommandLine.arguments
await aiChecks()
learningChecks(arguments)
sessionChecks(arguments)
fuzzyChecks(arguments)
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
