import Foundation

/// Turns typed pinyin into candidates: a port of PinyinEngine.kt.
public final class PinyinEngine {
    public static let alternativesLimit = 20
    public static let englishId = -2

    public struct Candidate {
        public let text: String
        public let consumed: Int
        public let syllables: [String]
        public let parts: [Word]?
        public let spelling: String?
        public let id: Int
    }

    struct Syllable {
        let text: String
        let end: Int
    }

    private enum C {
        static let maxSyllableLength = 6
        static let maxInitialsLength = 6
        static let initialWordsLimit = 6
        static let minBeforeInitials = 3
        static let maxBeforeInitials = 5
        static let minLettersNearTop = 3
        static let maxCandidates = 80
        static let fullMatchLimit = 30
        static let partialMatchLimit = 8
        static let singleSyllableLimit = 40
        static let maxSentences = 3
    }

    private let lexicon: PinyinLexicon
    private let decoder: SentenceDecoder

    public init(lexicon: PinyinLexicon) {
        self.lexicon = lexicon
        decoder = SentenceDecoder(lexicon: lexicon)
    }

    public func candidates(_ input: String, before: SentenceDecoder.Context? = nil, taps: SentenceDecoder.Taps? = nil) -> [Candidate] {
        let words = wordCandidates(input)
        let limit = lexicon.model == nil ? 1 : C.maxSentences
        let sentences = decoder.decode(input, before: before, limit: limit, taps: taps)
        let length = input.utf8.count
        guard let sentence = sentences.first else { return withInitialWords(input, words, before) }
        let typed = input.replacingOccurrences(of: "'", with: "")
        let corrected = sentence.spelling.replacingOccurrences(of: " ", with: "") != typed
        if sentence.parts.count < 2 && !corrected && lexicon.model == nil {
            return withInitialWords(input, words, before)
        }
        let whole = sentences.map { Self.wholeInput($0, length) }
        return withInitialWords(input, withSentences(whole, words, length), before)
    }

    /// Other words that read like [part] of a sentence, best first, to swap it for.
    public func alternatives(_ part: Word) -> [Word] {
        lexicon.matches(part.syllables.map { LexiconPiece($0, isPrefix: false) }, limit: Self.alternativesLimit)
            .map(\.word).filter { $0.text != part.text }
    }

    /// [sentence] with its part at [index] replaced by [word]; picking it learns that word.
    public func withPart(_ sentence: Candidate, _ index: Int, _ word: Word) -> Candidate {
        var parts = sentence.parts ?? []
        parts[index] = word
        return Candidate(text: parts.map(\.text).joined(), consumed: sentence.consumed, syllables: parts.flatMap(\.syllables), parts: parts, spelling: sentence.spelling, id: sentence.id)
    }

    static func wholeInput(_ sentence: SentenceDecoder.Sentence, _ length: Int) -> Candidate {
        Candidate(text: sentence.text, consumed: length, syllables: sentence.parts.flatMap(\.syllables), parts: sentence.parts, spelling: sentence.spelling, id: -1)
    }

    private func withSentences(_ sentences: [Candidate], _ words: [Candidate], _ length: Int) -> [Candidate] {
        let best = sentences[0]
        let top = words.first
        let listed = top != nil && top!.text == best.text && top!.consumed >= length ? words : [best] + words.filter { $0.text != best.text }
        let others = sentences.dropFirst().filter { other in (other.parts?.count ?? 0) >= 2 && !listed.contains { $0.text == other.text } }
        if others.isEmpty { return listed }
        let at = listed.firstIndex { $0.consumed < length } ?? listed.count
        return Array(listed[0..<at]) + others + Array(listed[at...])
    }

    private func withInitialWords(_ input: String, _ words: [Candidate], _ before: SentenceDecoder.Context?) -> [Candidate] {
        let length = input.utf8.count
        if !(2...C.maxInitialsLength).contains(length) || input.contains("'") { return words }
        let pieces = input.map { LexiconPiece(String($0), isPrefix: true) }
        let found = lexicon.matches(pieces, limit: C.initialWordsLimit)
            .filter { match in !words.contains { $0.text == match.word.text } }
            .map { ($0, decoder.wordCost($0, after: before)) }
            .sorted { $0.1 < $1.1 }
            .map { $0.0.word }
        if found.isEmpty { return words }
        let added = found.map { Candidate(text: $0.text, consumed: length, syllables: $0.syllables, parts: nil, spelling: nil, id: $0.id) }
        if Self.isWholePinyin(input, lexicon) {
            let at = words.firstIndex { $0.consumed < length } ?? words.count
            return Array(words[0..<at]) + added + Array(words[at...])
        }
        let lastWord = words.lastIndex { $0.consumed >= length && $0.text.count > 1 } ?? -1
        let at = min(max(C.minBeforeInitials, min(C.maxBeforeInitials, lastWord + 1)), words.count)
        if length < C.minLettersNearTop || at < 1 || lexicon.model == nil {
            return Array(words[0..<at]) + added + Array(words[at...])
        }
        return [words[0], added[0]] + Array(words[1..<at]) + Array(added.dropFirst()) + Array(words[at...])
    }

    static func isWholePinyin(_ input: String, _ lexicon: PinyinLexicon) -> Bool {
        let letters = Array(input.utf8)
        var reachable = [Bool](repeating: false, count: letters.count + 1)
        reachable[0] = true
        for start in letters.indices where reachable[start] {
            let last = min(start + C.maxSyllableLength, letters.count)
            if start + 1 > last { continue }
            for end in (start + 1)...last where lexicon.isSyllable(String(decoding: letters[start..<end], as: UTF8.self)) {
                reachable[end] = true
            }
        }
        return reachable[letters.count]
    }

    private func wordCandidates(_ input: String) -> [Candidate] {
        let syllables = segment(input)
        if syllables.isEmpty { return [] }
        let letters = Array(input.utf8)
        var seen = Set<String>()
        var result: [Candidate] = []
        for count in stride(from: syllables.count, through: 1, by: -1) {
            let limit = count == syllables.count ? C.fullMatchLimit : (count == 1 ? C.singleSyllableLimit : C.partialMatchLimit)
            let found = lexicon.matches(piecesFor(syllables, count), limit: limit)
            var consumed = syllables[count - 1].end
            if consumed < letters.count && letters[consumed] == 39 { consumed += 1 }
            for match in found {
                if seen.insert(match.word.text).inserted {
                    result.append(Candidate(text: match.word.text, consumed: consumed, syllables: match.word.syllables, parts: nil, spelling: nil, id: match.word.id))
                }
                if result.count >= C.maxCandidates { return result }
            }
        }
        return result
    }

    private func piecesFor(_ syllables: [Syllable], _ count: Int) -> [LexiconPiece] {
        (0..<count).map { i in
            let text = syllables[i].text
            let complete = text.utf8.count >= 2 && lexicon.isSyllable(text)
            return LexiconPiece(text, isPrefix: !complete || i == syllables.count - 1)
        }
    }

    func segment(_ input: String) -> [Syllable] {
        let letters = Array(input.utf8)
        var result: [Syllable] = []
        var start = 0
        while start < letters.count {
            if letters[start] == 39 { start += 1; continue }
            var end = start
            while end < letters.count && letters[end] != 39 { end += 1 }
            let chunk = segmentChunk(letters, start, end)
            result += chunk
            if chunk.last?.end != end { break }
            start = end
        }
        return result
    }

    private func segmentChunk(_ letters: [UInt8], _ start: Int, _ end: Int) -> [Syllable] {
        var best: [Syllable] = []
        var deadEnds = Set<Int>()
        var path: [Syllable] = []
        func search(_ position: Int) -> Bool {
            if position == end {
                best = path
                return true
            }
            if deadEnds.contains(position) { return false }
            for length in stride(from: min(C.maxSyllableLength, end - position), through: 1, by: -1) {
                let piece = String(decoding: letters[position..<(position + length)], as: UTF8.self)
                if lexicon.isSyllable(piece) || lexicon.isSyllablePrefix(piece) {
                    path.append(Syllable(text: piece, end: position + length))
                    if search(position + length) { return true }
                    path.removeLast()
                }
            }
            if (path.last?.end ?? start) > (best.last?.end ?? start) { best = path }
            deadEnds.insert(position)
            return false
        }
        _ = search(start)
        return best
    }
}
