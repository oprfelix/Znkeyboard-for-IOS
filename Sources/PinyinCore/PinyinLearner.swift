import Foundation

/// What the user picked, in the same text format as Android's PinyinUserData, so a backup can move
/// between the two later. Pruned the same way: the least-used quarter goes when a table overflows.
public final class PinyinUserData {
    public final class LearnedWord {
        public let text: String
        public let syllables: [String]
        public var uses: Int
        public var lastUsed: Int
        init(_ text: String, _ syllables: [String], _ uses: Int, _ lastUsed: Int) {
            self.text = text
            self.syllables = syllables
            self.uses = uses
            self.lastUsed = lastUsed
        }
    }

    private final class Follower {
        let next: String
        var uses: Int
        var lastUsed: Int
        init(_ next: String, _ uses: Int, _ lastUsed: Int) {
            self.next = next
            self.uses = uses
            self.lastUsed = lastUsed
        }
    }

    private static let header = "zn-pinyin-user 1"
    private static let maxWords = 6000
    private static let maxPairs = 6000
    private static let maxUses = 10000

    private var words: [String: LearnedWord] = [:]
    private var following: [String: [Follower]] = [:]
    private var pairCount = 0
    public private(set) var clock = 0

    public init() {}

    public var allWords: [LearnedWord] { Array(words.values) }

    public func learnWord(_ text: String, _ syllables: [String]) -> LearnedWord {
        clock += 1
        let key = text + "\t" + syllables.joined(separator: " ")
        let word = words[key] ?? LearnedWord(text, syllables, 0, 0)
        words[key] = word
        word.uses = min(word.uses + 1, Self.maxUses)
        word.lastUsed = clock
        if words.count > Self.maxWords { pruneWords() }
        return word
    }

    public func learnPair(_ previous: String, _ next: String) -> Int {
        if previous.isEmpty || next.isEmpty { return 0 }
        clock += 1
        var list = following[previous] ?? []
        var pair = list.first { $0.next == next }
        if pair == nil {
            pair = Follower(next, 0, 0)
            list.append(pair!)
            following[previous] = list
            pairCount += 1
        }
        pair!.uses = min(pair!.uses + 1, Self.maxUses)
        pair!.lastUsed = clock
        let uses = pair!.uses
        if pairCount > Self.maxPairs { prunePairs() }
        return uses
    }

    public func forgetWord(_ text: String) {
        clock += 1
        words = words.filter { $0.value.text != text }
        following[text] = nil
        for key in Array(following.keys) { following[key]?.removeAll { $0.next == text } }
        following = following.filter { !$0.value.isEmpty }
        pairCount = following.values.reduce(0) { $0 + $1.count }
    }

    public func pairs() -> [(String, String, Int)] {
        following.flatMap { previous, list in list.map { (previous, $0.next, $0.uses) } }
    }

    public func nextWords(_ previous: String, limit: Int) -> [String] {
        (following[previous] ?? [])
            .sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.lastUsed > $1.lastUsed }
            .prefix(limit).map(\.next)
    }

    public func encode() -> Data {
        var out = Self.header + "\n"
        for word in words.values {
            out += "w\t\(word.text)\t\(word.syllables.joined(separator: " "))\t\(word.uses)\t\(word.lastUsed)\n"
        }
        for (previous, list) in following {
            for pair in list { out += "p\t\(previous)\t\(pair.next)\t\(pair.uses)\t\(pair.lastUsed)\n" }
        }
        return Data(out.utf8)
    }

    public static func decode(_ data: Data) -> PinyinUserData? {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first.map(String.init) == header else { return nil }
        let result = PinyinUserData()
        for line in lines.dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, let uses = Int(f[3]), let last = Int(f[4]) else { continue }
            if f[0] == "w" {
                let syllables = f[2].split(separator: " ").map(String.init)
                result.words[f[1] + "\t" + f[2]] = LearnedWord(f[1], syllables, uses, last)
            } else if f[0] == "p" {
                result.following[f[1], default: []].append(Follower(f[2], uses, last))
                result.pairCount += 1
            }
            result.clock = max(result.clock, last)
        }
        return result
    }

    private func pruneWords() {
        let keep = words.sorted { $0.value.uses != $1.value.uses ? $0.value.uses > $1.value.uses : $0.value.lastUsed > $1.value.lastUsed }
            .prefix(Self.maxWords * 3 / 4)
        words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func prunePairs() {
        let all = following.flatMap { previous, list in list.map { (previous, $0) } }
            .sorted { $0.1.uses != $1.1.uses ? $0.1.uses > $1.1.uses : $0.1.lastUsed > $1.1.lastUsed }
            .prefix(Self.maxPairs * 3 / 4)
        following = [:]
        for (previous, pair) in all { following[previous, default: []].append(pair) }
        pairCount = all.count
    }
}

/// Learns from pinyin commits: a port of PinyinLearner.kt.
public final class PinyinLearner {
    /// A word to offer after a commit; [word] is set when it completes a dictionary word.
    public struct Prediction {
        public let text: String
        public let word: Word?
    }

    private static let maxPhraseSyllables = 6
    private static let learnedPredictions = 4
    private static let continuationsFirst = 4
    private static let modelPredictions = 6
    public private(set) var data: PinyinUserData
    private let lexicon: PinyinLexicon
    public var learningEnabled = true
    public private(set) var previous: String?
    private var previousId = -1
    private var phraseText = ""
    private var phraseSyllables: [String] = []
    private var phrasePicks = 0
    private var phraseByHand = false

    public init(data: PinyinUserData, lexicon: PinyinLexicon) {
        self.data = data
        self.lexicon = lexicon
        for word in data.allWords { lexicon.learn(word.text, word.syllables, uses: word.uses) }
        for (previous, next, uses) in data.pairs() { lexicon.learnPair(previous, next, uses: uses) }
    }

    public var context: SentenceDecoder.Context? {
        previous.map { SentenceDecoder.Context(text: $0, id: previousId) }
    }

    public func onPick(_ text: String, _ syllables: [String], byHand: Bool, id: Int = -1) {
        if learningEnabled {
            learnWord(text, syllables)
            if let previous { learnPair(previous, text) }
        }
        phraseText += text
        phraseSyllables += syllables
        phrasePicks += 1
        phraseByHand = phraseByHand || byHand
        previous = text
        previousId = id
    }

    public func onCompositionDone() {
        if learningEnabled, phrasePicks >= 2, phraseByHand, phraseSyllables.count <= Self.maxPhraseSyllables {
            learnWord(phraseText, phraseSyllables)
            previous = phraseText
        }
        resetPhrase()
    }

    public func onCompositionAbandoned() {
        resetPhrase()
        breakChain()
    }

    public func breakChain() {
        previous = nil
        previousId = -1
    }

    public func onPredictionPicked(_ prediction: Prediction) {
        if let word = prediction.word {
            if learningEnabled { learnWord(word.text, word.syllables) }
            previous = word.text
            previousId = word.id
        } else {
            if learningEnabled, let previous { learnPair(previous, prediction.text) }
            previous = prediction.text
            previousId = -1
        }
    }

    /// Words the user typed after the last one before, then continuations from the dictionary.
    public func predictions(limit: Int) -> [Prediction] {
        guard let context = previous else { return [] }
        var result: [Prediction] = []
        var seen = Set<String>()
        for next in data.nextWords(context, limit: Self.learnedPredictions) where seen.insert(next).inserted {
            result.append(Prediction(text: next, word: nil))
        }
        // Then words that continue it (怎么 → 样, 办), a few words likely to follow it (发货 →
        // 时间, 速度), and the rest of the continuations.
        let continuations = lexicon.continuations(context, limit: limit)
        let following = lexicon.nextWords(after: context, id: previousId, limit: Self.modelPredictions)
        func add(_ prediction: Prediction) {
            if result.count < limit && seen.insert(prediction.text).inserted { result.append(prediction) }
        }
        for (suffix, word) in continuations.prefix(Self.continuationsFirst) { add(Prediction(text: suffix, word: word)) }
        for word in following { add(Prediction(text: word.text, word: nil)) }
        for (suffix, word) in continuations.dropFirst(Self.continuationsFirst) { add(Prediction(text: suffix, word: word)) }
        return result
    }

    public func forget(_ text: String) {
        data.forgetWord(text)
        lexicon.forget(text)
        if previous == text { breakChain() }
    }

    private func learnPair(_ previous: String, _ next: String) {
        lexicon.learnPair(previous, next, uses: data.learnPair(previous, next))
    }

    private func learnWord(_ text: String, _ syllables: [String]) {
        let word = data.learnWord(text, syllables)
        lexicon.learn(word.text, word.syllables, uses: word.uses)
    }

    private func resetPhrase() {
        phraseText = ""
        phraseSyllables = []
        phrasePicks = 0
        phraseByHand = false
    }
}
