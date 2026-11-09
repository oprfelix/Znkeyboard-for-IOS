import Foundation

/// A dictionary word: [syllables] is its raw pinyin; [id] its language-model id, or -1.
public struct Word {
    public let text: String
    public let syllables: [String]
    public let id: Int
    public let trade: Bool
}

/// A word found for typed pieces, with what it ranks by.
public struct Match {
    public let word: Word
    public let score: Float
    /// What the user's picks added to [score], and the picks that count (see learnedUses).
    public let learned: Float
    public let uses: Int
}

/// One typed piece: a whole syllable that must match exactly, or the start of one.
public struct LexiconPiece {
    public let text: String
    public let isPrefix: Bool
    public init(_ text: String, isPrefix: Bool) {
        self.text = text
        self.isPrefix = isPrefix
    }
}

/// Fuzzy sounds: each rule folds the second spelling onto the first, as on Android.
public struct FuzzyRules: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let zZh = FuzzyRules(rawValue: 1)
    public static let cCh = FuzzyRules(rawValue: 2)
    public static let sSh = FuzzyRules(rawValue: 4)
    public static let nL = FuzzyRules(rawValue: 8)
    public static let anAng = FuzzyRules(rawValue: 16)
    public static let enEng = FuzzyRules(rawValue: 32)
    public static let inIng = FuzzyRules(rawValue: 64)
    public static let all: FuzzyRules = [.zZh, .cCh, .sSh, .nL, .anAng, .enEng, .inIng]
    /// What a new user starts with.
    public static let standard: FuzzyRules = all.subtracting(.anAng)
    public static let labelled: [(rule: FuzzyRules, label: String)] = [
        (.zZh, "z = zh"), (.cCh, "c = ch"), (.sSh, "s = sh"), (.nL, "n = l"),
        (.anAng, "an = ang"), (.enEng, "en = eng"), (.inIng, "in = ing"),
    ]

    func normalize(_ syllable: String) -> String {
        var s = syllable
        if contains(.zZh), s.hasPrefix("zh") { s = "z" + s.dropFirst(2) }
        if contains(.cCh), s.hasPrefix("ch") { s = "c" + s.dropFirst(2) }
        if contains(.sSh), s.hasPrefix("sh") { s = "s" + s.dropFirst(2) }
        if contains(.nL), s.hasPrefix("l") { s = "n" + s.dropFirst(1) }
        if s.count > 2 {
            if contains(.anAng), s.hasSuffix("ang") { s.removeLast() }
            if contains(.enEng), s.hasSuffix("eng") { s.removeLast() }
            if contains(.inIng), s.hasSuffix("ing") { s.removeLast() }
        }
        return s
    }
}

/// Lookups over [MappedDictionary] the way PinyinDictionary.kt answers them.
public final class PinyinLexicon {
    public let dictionary: MappedDictionary
    public let model: LanguageModel?
    public let fuzzy: FuzzyRules
    public let rawSyllables: Set<String>
    private let normalizedSyllables: Set<String>
    private let syllablePrefixes: Set<String>
    private let rawNames: [String]
    private let normalizedNames: [String]
    private let normalizedIds: [Int]
    private let normalizedIndex: [String: Int]
    private let syllableIndex: [String: Int]
    private var fitCache: [String: [Bool]] = [:]
    private var nineKeyWordCache: [String: [(match: Match, byInitials: Bool)]] = [:]
    private var nineKeyVersion = -1

    /// What the user's picks changed: dictionary rows, and phrases the dictionary lacks.
    private struct Learned {
        var score: Float
        var uses: Int
    }

    private struct Built {
        let text: String
        let raw: [String]
        let initials: [UInt8]
        var score: Float
        var uses: Int
    }

    private var learnedRows: [Int: Learned] = [:]
    private var built: [Built] = []
    private var pairs: [String: [String: Int]] = [:]
    private var pairTotals: [String: Int] = [:]
    /// Every learned word's uses together: P(word) among the user's picks is uses / this.
    public private(set) var learnedUses = 0
    /// Changes with what was learned, so cached lookups start over.
    public private(set) var version = 0

    public init(dictionary: MappedDictionary, model: LanguageModel?, fuzzy: FuzzyRules = .all) {
        self.fuzzy = fuzzy
        self.dictionary = dictionary
        self.model = model.flatMap { $0.words == dictionary.words ? $0 : nil }
        let names = dictionary.syllableNames
        let folded = names.map(fuzzy.normalize)
        var index: [String: Int] = [:]
        for name in folded where index[name] == nil { index[name] = index.count }
        var prefixes = Set<String>()
        for name in names + folded {
            for end in 1...name.count { prefixes.insert(String(name.prefix(end))) }
        }
        rawNames = names
        normalizedNames = folded
        normalizedIds = folded.map { index[$0]! }
        normalizedIndex = index
        syllableIndex = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        rawSyllables = Set(names)
        normalizedSyllables = Set(folded)
        syllablePrefixes = prefixes
    }

    public func isSyllable(_ text: String) -> Bool { normalizedSyllables.contains(fuzzy.normalize(text)) }
    public func isSyllablePrefix(_ text: String) -> Bool { syllablePrefixes.contains(text) }

    public func matches(_ pieces: [LexiconPiece], limit: Int) -> [Match] { matchHits(pieces, limit: limit) }

    /// Applies [uses] picks of [text] spelled [raw]; a word the dictionary lacks is added.
    public func learn(_ text: String, _ raw: [String], uses: Int) {
        version += 1
        if raw.isEmpty || raw.count != text.count || raw.contains(where: { !isSyllable($0) }) { return }
        let key = raw.map { $0.utf8.first! }
        if let row = dictionary.rows(initials: key).first(where: { dictionary.text(at: $0) == text && dictionary.syllables(at: $0) == raw }) {
            let old = learnedRows[row]?.uses ?? 0
            learnedRows[row] = Learned(score: dictionary.score(at: row) + Self.learnBonus * log(1 + Float(uses)), uses: uses)
            learnedUses += uses - old
            return
        }
        // A phrase the user built gains from its second pick on: one accidental build must not
        // push a dictionary word with the same pinyin aside.
        let score = Self.newWordBase + Self.learnBonus * log(max(Float(uses), 1))
        let counted = max(uses - 1, 0)
        if let at = built.firstIndex(where: { $0.text == text && $0.raw == raw }) {
            learnedUses += counted - built[at].uses
            built[at].score = score
            built[at].uses = counted
        } else {
            learnedUses += counted
            built.append(Built(text: text, raw: raw, initials: key, score: score, uses: counted))
        }
    }

    public func learnPair(_ previous: String, _ next: String, uses: Int) {
        if previous.isEmpty || next.isEmpty { return }
        version += 1
        let old = pairs[previous]?[next] ?? 0
        pairs[previous, default: [:]][next] = uses
        pairTotals[previous, default: 0] += uses - old
    }

    public func pairUses(_ previous: String, _ next: String) -> Int { pairs[previous]?[next] ?? 0 }
    public func pairTotal(_ previous: String) -> Int { pairTotals[previous] ?? 0 }

    public func isLearned(_ text: String) -> Bool {
        built.contains { $0.text == text } || learnedRows.keys.contains { dictionary.text(at: $0) == text }
    }

    /// Undoes [learn] for one word, with what followed it.
    public func forget(_ text: String) {
        version += 1
        pairTotals[text] = nil
        pairs[text] = nil
        for previous in Array(pairs.keys) {
            if let uses = pairs[previous]?.removeValue(forKey: text) { pairTotals[previous, default: 0] -= uses }
        }
        for row in learnedRows.keys where dictionary.text(at: row) == text {
            learnedUses -= learnedRows[row]!.uses
            learnedRows[row] = nil
        }
        for item in built where item.text == text { learnedUses -= item.uses }
        built.removeAll { $0.text == text }
    }

    /// Whether some word's initials, the user's phrases among them, start with [key].
    public func hasInitials(prefix key: [UInt8]) -> Bool {
        dictionary.hasInitials(prefix: key) || built.contains { $0.initials.starts(with: key) }
    }

    /// The last word of [text], longest first, as context for what is typed next.
    public func contextBefore(_ text: String) -> SentenceDecoder.Context? {
        let characters = Array(text.suffix(Self.maxContextWord))
        if characters.count >= 2 {
            for length in stride(from: characters.count, through: 2, by: -1) {
                let tail = String(characters.suffix(length))
                if built.contains(where: { $0.text == tail }) { return SentenceDecoder.Context(text: tail, id: -1) }
                if let row = dictionary.rows(textPrefix: tail).first(where: { dictionary.text(at: $0) == tail }) {
                    return SentenceDecoder.Context(text: tail, id: dictionary.wordId(at: row))
                }
            }
        }
        guard let last = text.last else { return nil }
        let single = String(last)
        guard let row = dictionary.rows(textPrefix: single).first(where: { dictionary.text(at: $0) == single }) else { return nil }
        return SentenceDecoder.Context(text: single, id: dictionary.wordId(at: row))
    }

    /// Words that continue [text], best first, as (what is left to type, the word).
    public func continuations(_ text: String, limit: Int) -> [(String, Word)] {
        if text.isEmpty { return [] }
        var hits: [(Float, Int, Word)] = dictionary.rows(textPrefix: text).compactMap { row in
            let found = dictionary.text(at: row)
            if found.count <= text.count { return nil }
            return (score(row), row, Word(text: found, syllables: dictionary.syllables(at: row), id: dictionary.wordId(at: row), trade: dictionary.isTrade(at: row)))
        }
        for item in built where item.text.count > text.count && item.text.hasPrefix(text) {
            hits.append((item.score, Int.max, Word(text: item.text, syllables: item.raw, id: -1, trade: false)))
        }
        hits.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        var seen = Set<String>()
        var result: [(String, Word)] = []
        for (_, _, word) in hits {
            let suffix = String(word.text.dropFirst(text.count))
            if seen.insert(suffix).inserted { result.append((suffix, word)) }
            if result.count >= limit { break }
        }
        return result
    }

    private func score(_ row: Int) -> Float { learnedRows[row]?.score ?? dictionary.score(at: row) }

    /// Raw initials each piece may start with; only n = l can change a first letter.
    private func initialsKeys(_ pieces: [LexiconPiece]) -> [[UInt8]] {
        var keys: [[UInt8]] = [[]]
        for piece in pieces {
            let first = piece.text.utf8.first!
            let options: [UInt8] = piece.text.utf8.count > 1 && fuzzy.contains(.nL) && (first == 110 || first == 108) ? [110, 108] : [first]
            keys = keys.flatMap { key in options.map { key + [$0] } }
        }
        return keys
    }

    /// Which syllables fit [piece]; only a few hundred pieces exist, so each is worked out once.
    private func syllablesFitting(_ piece: LexiconPiece) -> [Bool] {
        let key = piece.isPrefix ? piece.text + "*" : piece.text
        if let known = fitCache[key] { return known }
        let normalized = fuzzy.normalize(piece.text)
        let wanted = normalizedIndex[normalized] ?? -1
        let fits: [Bool] = rawNames.indices.map { id in
            if !piece.isPrefix { return normalizedIds[id] == wanted }
            if piece.text.utf8.count == 1 { return rawNames[id].hasPrefix(piece.text) }
            return normalizedNames[id].hasPrefix(normalized) || rawNames[id].hasPrefix(piece.text)
        }
        fitCache[key] = fits
        return fits
    }

    private func matchHits(_ pieces: [LexiconPiece], limit: Int) -> [Match] {
        let wanted = pieces.map { normalizedIndex[fuzzy.normalize($0.text)] ?? -1 }
        let fits = pieces.map(syllablesFitting)
        var found: [Int] = []
        for key in initialsKeys(pieces) {
            for row in dictionary.rows(initials: key) {
                let ids = dictionary.syllableIds(at: row)
                var ok = true
                for i in pieces.indices where !fits[i][Int(ids[i])] { ok = false; break }
                if ok { found.append(row) }
            }
        }
        // Rows are found as themselves, built phrases as -1 - their index.
        for index in built.indices where built[index].raw.count == pieces.count {
            let ids = built[index].raw.map { syllableIndex[$0] ?? 0 }
            if pieces.indices.allSatisfy({ fits[$0][ids[$0]] }) { found.append(-1 - index) }
        }
        found.sort(by: isBetter)
        if pieces.contains(where: \.isPrefix) {
            let last = pieces.count - 1
            func exactLast(_ hit: Int) -> Bool {
                let id = hit >= 0 ? Int(dictionary.syllableIds(at: hit)[last]) : (syllableIndex[built[-1 - hit].raw[last]] ?? 0)
                return normalizedIds[id] == wanted[last]
            }
            found = found.filter(exactLast) + found.filter { !exactLast($0) }
        }
        return found.prefix(limit).map(match)
    }

    private func isBetter(_ a: Int, _ b: Int) -> Bool {
        func value(_ hit: Int) -> Float { hit >= 0 ? score(hit) : built[-1 - hit].score }
        func order(_ hit: Int) -> Int { hit >= 0 ? hit : Int.max / 2 - hit }
        let x = value(a), y = value(b)
        return x != y ? x > y : order(a) < order(b)
    }

    private func match(_ hit: Int) -> Match {
        if hit < 0 {
            let item = built[-1 - hit]
            return Match(word: Word(text: item.text, syllables: item.raw, id: -1, trade: false), score: item.score, learned: item.score - Self.newWordBase, uses: item.uses)
        }
        let base = dictionary.score(at: hit)
        let known = learnedRows[hit]
        return Match(
            word: Word(text: dictionary.text(at: hit), syllables: dictionary.syllables(at: hit), id: dictionary.wordId(at: hit), trade: dictionary.isTrade(at: hit)),
            score: known?.score ?? base,
            learned: (known?.score ?? base) - base,
            uses: known?.uses ?? 0
        )
    }

    // MARK: 9-key

    /// Hits for a 9-key code, best first: dictionary rows, and phrases the user built.
    private func codeHits(_ code: [UInt8], initials: Bool) -> [Int] {
        var hits = initials ? dictionary.rows(initialsCode: code) : dictionary.rows(code: code)
        let typed = String(decoding: code, as: UTF8.self)
        var moved = !learnedRows.isEmpty
        for index in built.indices {
            let raw = built[index].raw
            if initials ? raw.count < 2 : false { continue }
            if NineKey.code(initials ? raw.map { String($0.prefix(1)) }.joined() : raw.joined()) == typed {
                hits.append(-1 - index)
                moved = true
            }
        }
        if moved { hits.sort(by: isBetter) }
        return hits
    }

    private func rawSyllables(_ hit: Int) -> [String] { hit >= 0 ? dictionary.syllables(at: hit) : built[-1 - hit].raw }

    /// The best [limit] words whose 9-key code is [digits], then the best [limit] whose 简拼 is.
    func nineKeyWords(_ digits: String, limit: Int) -> [(match: Match, byInitials: Bool)] {
        if nineKeyVersion != version || nineKeyWordCache.count > Self.maxNineKeyCache {
            nineKeyWordCache.removeAll()
            nineKeyVersion = version
        }
        let key = "\(digits)/\(limit)"
        if let known = nineKeyWordCache[key] { return known }
        let code = Array(digits.utf8)
        let full = codeHits(code, initials: false).prefix(limit).map { (match: match($0), byInitials: false) }
        let short = codeHits(code, initials: true).prefix(limit).map { (match: match($0), byInitials: true) }
        let found = full + short
        nineKeyWordCache[key] = found
        return found
    }

    /// Words for 9-key input: [locked] syllables picked from the spelling list, then [digits]
    /// (2–9). [boundaries] are digit offsets of typed separators, where a word must split. Best
    /// first: words using every digit, the last syllable maybe still being typed, then 简拼, then
    /// words using a leading part of the digits. [digits] on each is how many it uses.
    func nineKeyMatches(locked: [String], digits: String, boundaries: Set<Int>) -> [(word: Word, digits: Int)] {
        let lockedCode = NineKey.code(locked.joined())
        let lockedNormalized = locked.map(fuzzy.normalize)
        let typed = Array(digits)
        var seen = Set<String>()
        var result: [(word: Word, digits: Int)] = []

        func fits(_ raw: [String], _ used: Int) -> Bool {
            if raw.count <= locked.count && used > 0 { return false }
            for (index, syllable) in lockedNormalized.enumerated() where index >= raw.count || fuzzy.normalize(raw[index]) != syllable { return false }
            if boundaries.isEmpty { return true }
            var ends = Set<Int>()
            var at = -lockedCode.utf8.count
            for syllable in raw {
                at += syllable.utf8.count
                if at > 0 { ends.insert(at) }
            }
            return !boundaries.contains { $0 >= 1 && $0 < used && !ends.contains($0) }
        }

        func take(_ hits: [Int], _ used: Int, _ limit: Int) {
            var added = 0
            for hit in hits {
                if added >= limit { break }
                let found = match(hit).word
                if seen.insert(found.text).inserted {
                    result.append((found, used))
                    added += 1
                }
            }
        }

        // Every digit used. When that only spells single characters (64 → 你, 米…), 简拼 words
        // (64 → 你好) come after the first few rather than after all of them.
        let whole = codeHits(Array((lockedCode + digits).utf8), initials: false).filter { fits(rawSyllables($0), typed.count) }
        let singlesOnly = locked.isEmpty && !whole.isEmpty && whole.allSatisfy { rawSyllables($0).count == 1 }
        let short = locked.isEmpty && typed.count >= 2 ? codeHits(Array(digits.utf8), initials: true) : []
        if singlesOnly && typed.count >= 2 {
            // Also the top character of every syllable the digits spell (586 → 落, 论, 军, 困, 括),
            // so a less used syllable is not pushed behind the 简拼 words.
            var spelled = Set<String>()
            let heads = whole.enumerated().filter { i, hit in
                spelled.insert(rawSyllables(hit)[0]).inserted || i < Self.singlesBeforeInitials
            }.map { $0.element }
            take(heads, typed.count, heads.count)
            take(short, typed.count, Self.initialsLimit)
        }
        take(whole, typed.count, Self.fullLimit)
        // The last syllable still being typed: complete it from every syllable code it starts.
        var growing: [Int] = []
        if typed.count >= 1 {
            for split in stride(from: typed.count - 1, through: max(0, typed.count - Self.maxCodeLength + 1), by: -1) {
                let tail = String(typed[split...])
                let head = lockedCode + String(typed[..<split])
                for code in syllablesByCode.keys where code.utf8.count > tail.utf8.count && code.hasPrefix(tail) {
                    for hit in codeHits(Array((head + code).utf8), initials: false) {
                        let raw = rawSyllables(hit)
                        if NineKey.code(raw.last!) == code && fits(raw, typed.count) { growing.append(hit) }
                    }
                }
            }
        }
        take(growing.sorted(by: isBetter), typed.count, Self.fullLimit)
        take(short, typed.count, Self.initialsLimit)
        // A leading part of the digits; the rest stays for the next pick.
        if typed.count >= 2 {
            for used in stride(from: typed.count - 1, through: 1, by: -1) {
                let hits = codeHits(Array((lockedCode + String(typed[..<used])).utf8), initials: false).filter { fits(rawSyllables($0), used) }
                take(hits, used, used <= Self.maxCodeLength ? Self.singleLimit : Self.partialLimit)
            }
        }
        // Everything locked and nothing typed after it.
        if typed.isEmpty && !locked.isEmpty {
            let hits = codeHits(Array(lockedCode.utf8), initials: false).filter { rawSyllables($0).count == locked.count && fits(rawSyllables($0), 0) }
            take(hits, 0, Self.fullLimit)
        }
        return result
    }

    /// Syllables a run of digits can start with, longest and most used first, then its letters.
    func nineKeySpellings(_ digits: String) -> [String] {
        if digits.isEmpty { return [] }
        let typed = Array(digits)
        var result: [String] = []
        for length in stride(from: min(Self.maxCodeLength, typed.count), through: 1, by: -1) {
            result += syllablesByCode[String(typed[..<length])] ?? []
        }
        for letter in NineKey.letters(of: typed[0]) where !result.contains(letter) { result.append(letter) }
        return result
    }

    /// The likeliest pinyin for [digits], for showing what is being typed (ni'hao for 64426).
    func nineKeySpell(_ digits: String) -> [String] {
        let typed = Array(digits)
        var result: [String] = []
        var at = 0
        while at < typed.count, let spelling = nineKeySpellings(String(typed[at...])).first {
            result.append(spelling)
            at += spelling.utf8.count
        }
        return result
    }

    /// Code → syllables with it, most used first, by the best single character of each.
    private lazy var syllablesByCode: [String: [String]] = {
        var best: [String: Float] = [:]
        for initial in Set(rawNames.compactMap(\.utf8.first)) {
            for row in dictionary.rows(initials: [initial]) {
                let name = rawNames[Int(dictionary.syllableIds(at: row)[0])]
                if best[name] == nil { best[name] = dictionary.score(at: row) }
            }
        }
        return Dictionary(grouping: best.keys, by: NineKey.code).mapValues { names in
            names.sorted { best[$0]! != best[$1]! ? best[$0]! > best[$1]! : $0 < $1 }
        }
    }()

    private static let maxNineKeyCache = 3000
    private static let fullLimit = 30
    private static let initialsLimit = 10
    private static let singlesBeforeInitials = 6
    private static let partialLimit = 8
    private static let singleLimit = 40
    private static let maxCodeLength = 6

    private static let learnBonus: Float = 4
    private static let maxContextWord = 6
    private static let newWordBase: Float = log(20000)
}
