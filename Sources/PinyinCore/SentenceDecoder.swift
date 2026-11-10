import Foundation

/// Reads typed pinyin as a row of words: a port of SentenceDecoder.kt, with the same costs, so the
/// two keyboards agree. Every split is tried: whole syllables, 简拼, mixes, and one slip per word.
public final class SentenceDecoder {
    public struct Sentence {
        public let text: String
        public let parts: [Word]
        public let spelling: String
        public let cost: Float
    }

    /// The word committed just before this input.
    public struct Context {
        public let text: String
        public let id: Int
        public init(text: String, id: Int) {
            self.text = text
            self.id = id
        }
    }

    private struct Piece {
        let end: Int
        let text: String
        let isPrefix: Bool
        let cost: Float
        var slip: Bool { !isPrefix && cost > 0 }
    }

    private struct Edge {
        let end: Int
        let pieces: [Piece]
        let match: Match
        let cost: Float
    }

    private final class Step {
        let cost: Float
        let previous: Step?
        let word: Word?
        let pieces: [Piece]
        let context: Int
        let text: String?
        var alternates: [Step] = []

        init(_ cost: Float, _ previous: Step?, _ word: Word?, _ pieces: [Piece], _ context: Int, _ text: String?) {
            self.cost = cost
            self.previous = previous
            self.word = word
            self.pieces = pieces
            self.context = context
            self.text = text
        }

        func addAlternate(_ step: Step) {
            var at = alternates.count
            while at > 0 && alternates[at - 1].cost > step.cost { at -= 1 }
            alternates.insert(step, at: at)
            if alternates.count > C.maxAlternates { alternates.removeLast() }
        }
    }

    private struct Reading {
        let cost: Float
        let steps: [Step]
        let from: Int
    }

    private enum C {
        static let tradeBonus: Float = 2.5
        static let maxInput = 60
        static let maxCache = 3000
        static let fuzzyChoices = 16
        static let fuzzyCost: Float = 2.5
        static let maxSyllableLength = 6
        static let maxWordSyllables = 6
        static let maxNineKeyWordDigits = 24
        static let wordCost: Float = 22
        static let beam = 6
        static let lmChoices = 16
        static let maxAlternates = 3
        static let alternativeMargin: Float = 6
        static let maxReadingsTried = 24
        static let lmWordCost: Float = 1
        static let lmWeight: Float = 0.6
        static let picksWeight: Float = 0.05
        static let picksScale = 300
        static let pairsWeight: Float = 0.1
        static let initialCost: Float = 2.5
        static let initialBeforeVowelCost: Float = 9
        static let stillTypingCost: Float = 1.5
        static let nasalCost: Float = 3
        static let missingLetterCost: Float = 3.5
        static let lostInitialCost: Float = 5
        static let slipCost: Float = 7
        static let touchSlipCost: Float = 2
        static let touchWeight: Float = 1
        static let maxTouchExtra: Float = 4
        static let shortTouchSlipCost: Float = 1
        static let maxInitialsWord = 6
        static let initials = Set("bpmfdtnlgkhjqxzcsryw".utf8)
        static let vowels = Set("aoe".utf8)
        static let zeroInitialVowels = Set("aeiou".utf8)
        static let compoundInitials: Set<String> = ["zh", "ch", "sh"]
        static let separator = UInt8(ascii: "'")
    }

    private let lexicon: PinyinLexicon
    private var matchCache: [String: [(Match, Float)]] = [:]
    private var cachedVersion = -1
    private static let neighbours: [UInt8: [UInt8]] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        var map: [UInt8: [UInt8]] = [:]
        for (r, row) in rows.enumerated() {
            for (c, key) in row.enumerated() {
                var near: [UInt8] = []
                if c > 0 { near.append(row[c - 1]) }
                if c < row.count - 1 { near.append(row[c + 1]) }
                for other in [r - 1, r + 1] where rows.indices.contains(other) {
                    let shift = other > r ? c : c + 1
                    for at in [shift - 1, shift] where rows[other].indices.contains(at) { near.append(rows[other][at]) }
                }
                map[key] = near
            }
        }
        return map
    }()

    public init(lexicon: PinyinLexicon) {
        self.lexicon = lexicon
    }

    /// Per input position, how well the tap fitted each letter (the best 0, too far +∞), or nil
    /// for a position without a tap.
    public typealias Taps = [[Float]?]

    public func decode(_ input: String, before: Context?, limit: Int, taps: Taps? = nil) -> [Sentence] {
        let letters = Array(input.utf8)
        let n = letters.count
        if n == 0 || n > C.maxInput { return [] }
        let model = lexicon.model
        let beam = model == nil ? 1 : C.beam
        let choices = model == nil ? 1 : C.lmChoices
        var piecesAt = [[Piece]?](repeating: nil, count: n)
        func pieces(_ at: Int) -> [Piece] {
            if let known = piecesAt[at] { return known }
            let read = readPieces(letters, at, taps)
            piecesAt[at] = read
            return read
        }
        let wholeInitials = model != nil && (2...C.maxInitialsWord).contains(n) && !letters.contains(C.separator) &&
            !PinyinEngine.isWholePinyin(input, lexicon)

        var best = [[Step]](repeating: [], count: n + 1)
        let startContext = before.map { $0.id >= 0 && model != nil ? $0.id : (model?.start ?? -1) } ?? (model?.start ?? -1)
        best[0].append(Step(0, nil, nil, [], startContext, before?.text))
        for start in 0..<n {
            let here = best[start]
            if here.isEmpty { continue }
            if letters[start] == C.separator {
                for step in here { relax(&best[start + 1], Step(step.cost, step, nil, [], step.context, step.text), beam) }
                continue
            }
            var edges: [Edge] = []
            var run: [Piece] = []
            func extend(_ at: Int, _ initials: [UInt8]) {
                if !run.isEmpty {
                    let pieceCost = run.reduce(Float(0)) { $0 + $1.cost }
                    for (match, fuzzyCost) in bestMatches(run, choices) {
                        edges.append(Edge(end: at, pieces: run, match: match, cost: pieceCost + fuzzyCost))
                    }
                }
                if run.count >= C.maxWordSyllables || at >= n { return }
                if letters[at] == C.separator {
                    if !run.isEmpty { extend(at + 1, initials) }
                    return
                }
                for piece in pieces(at) {
                    if piece.slip && run.contains(where: \.slip) { continue }
                    let next = initials + [piece.text.utf8.first!]
                    if !lexicon.hasInitials(prefix: next) { continue }
                    run.append(piece)
                    extend(piece.end, next)
                    run.removeLast()
                }
            }
            extend(start, [])
            if start == 0 && wholeInitials {
                let each = letters.indices.map { Piece(end: $0 + 1, text: String(UnicodeScalar(letters[$0])), isPrefix: true, cost: 0) }
                for (match, _) in bestMatches(each, choices) {
                    edges.append(Edge(end: n, pieces: each, match: match, cost: C.initialCost))
                }
            }
            for step in here {
                for edge in edges {
                    if model != nil, best[edge.end].count >= beam, best[edge.end].last!.cost <= step.cost + C.lmWordCost + edge.cost { continue }
                    let word = edge.match.word
                    let cost = edge.cost + wordCost(edge.match, step.context, step.text)
                    relax(&best[edge.end], Step(step.cost + cost, step, word, edge.pieces, word.id, word.text), beam)
                }
            }
        }
        return bestReadings(best[n], limit: limit).compactMap { reading in
            let steps = reading.steps.reversed().filter { $0.word != nil }
            if steps.isEmpty { return nil }
            let parts = steps.map { $0.word! }
            let spelling = steps.map { $0.pieces.map(\.text).joined(separator: " ") }.joined(separator: " ")
            return Sentence(text: parts.map(\.text).joined(), parts: parts, spelling: spelling, cost: reading.cost)
        }
    }

    /// The best [limit] readings of 9-key [digits]: one code spells many words, so more words are
    /// tried for each run than for letters.
    func decodeNineKey(_ digits: String, before: Context?, limit: Int) -> [Sentence] {
        let typed = Array(digits)
        let n = typed.count
        if n < 2 || n > C.maxInput { return [] }
        let model = lexicon.model
        let beam = model == nil ? 1 : C.beam
        let choices = model == nil ? 1 : C.lmChoices
        var best = [[Step]](repeating: [], count: n + 1)
        let startContext = before.map { $0.id >= 0 && model != nil ? $0.id : (model?.start ?? -1) } ?? (model?.start ?? -1)
        best[0].append(Step(0, nil, nil, [], startContext, before?.text))
        for start in 0..<n {
            let here = best[start]
            if here.isEmpty { continue }
            for end in (start + 1)...min(n, start + C.maxNineKeyWordDigits) {
                let found = lexicon.nineKeyWords(String(typed[start..<end]), limit: choices)
                for step in here {
                    for candidate in found {
                        let match = candidate.match
                        let extra = candidate.byInitials ? C.initialCost * Float(match.word.syllables.count) : 0
                        if model != nil, best[end].count >= beam, best[end].last!.cost <= step.cost + C.lmWordCost + extra { continue }
                        let cost = step.cost + extra + wordCost(match, step.context, step.text)
                        relax(&best[end], Step(cost, step, match.word, [], match.word.id, match.word.text), beam)
                    }
                }
            }
        }
        return bestReadings(best[n], limit: limit).compactMap { reading in
            let parts = reading.steps.reversed().compactMap(\.word)
            if parts.isEmpty { return nil }
            return Sentence(text: parts.map(\.text).joined(), parts: parts, spelling: parts.flatMap(\.syllables).joined(separator: " "), cost: reading.cost)
        }
    }

    func wordCost(_ match: Match, _ context: Int, _ previous: String?) -> Float {
        guard let model = lexicon.model else { return C.wordCost - match.score }
        let id = match.word.id
        var logP = id >= 0 ? model.logP(context, id) : match.score - match.learned - lexicon.dictionary.logTotalWeight
        // What the user picks is a second, personal model mixed in: how often they chose this
        // word, and this word after the last one.
        let learnedUses = lexicon.learnedUses
        let pairTotal = previous.map(lexicon.pairTotal) ?? 0
        if learnedUses > 0 || pairTotal > 0 {
            var keep: Float = 1
            var personal: Float = 0
            if learnedUses > 0 {
                keep -= C.picksWeight
                // Shares of at most the last few hundred picks: over all of them, a word picked once
                // after weeks of typing would count for nothing next to the language model.
                personal += C.picksWeight * min(Float(match.uses) / Float(min(learnedUses, C.picksScale)), 1)
            }
            if pairTotal > 0 {
                keep -= C.pairsWeight
                personal += C.pairsWeight * Float(lexicon.pairUses(previous!, match.word.text)) / Float(pairTotal)
            }
            logP = log(keep * exp(logP) + personal)
        }
        if match.word.trade { logP = min(logP + C.tradeBonus, 0) }
        return C.lmWordCost - C.lmWeight * logP
    }

    func wordCost(_ match: Match, after before: Context?) -> Float {
        guard let model = lexicon.model else { return -match.score }
        let context = before.flatMap { $0.id >= 0 ? $0.id : nil } ?? model.start
        return wordCost(match, context, before?.text)
    }

    private func bestMatches(_ run: [Piece], _ limit: Int) -> [(Match, Float)] {
        if matchCache.count > C.maxCache || cachedVersion != lexicon.version {
            matchCache.removeAll()
            cachedVersion = lexicon.version
        }
        let key = run.map { $0.isPrefix ? $0.text + "*" : $0.text }.joined(separator: " ") + "/\(limit)"
        if let known = matchCache[key] { return known }
        let found = lexicon.matches(run.map { LexiconPiece($0.text, isPrefix: $0.isPrefix) }, limit: max(C.fuzzyChoices, limit))
        let costed: [(Match, Float, Int)] = found.enumerated().map { order, match in
            var fuzzy = 0
            for i in run.indices where !run[i].isPrefix {
                if i >= match.word.syllables.count || match.word.syllables[i] != run[i].text { fuzzy += 1 }
            }
            return (match, C.fuzzyCost * Float(fuzzy), order)
        }
        let sorted = costed.sorted { a, b in
            let x = a.1 - a.0.score, y = b.1 - b.0.score
            return x != y ? x < y : a.2 < b.2
        }
        let result = sorted.prefix(limit).map { ($0.0, $0.1) }
        matchCache[key] = result
        return result
    }

    private func relax(_ steps: inout [Step], _ step: Step, _ beam: Int) {
        if let same = steps.firstIndex(where: { $0.context == step.context && (step.context >= 0 || $0.word?.text == step.word?.text) }) {
            let kept = steps[same]
            if kept.cost <= step.cost {
                kept.addAlternate(step)
                return
            }
            step.addAlternate(kept)
            kept.alternates.forEach(step.addAlternate)
            kept.alternates = []
            steps.remove(at: same)
        } else if steps.count >= beam {
            if steps.last!.cost <= step.cost { return }
            steps.removeLast()
        }
        var at = steps.count
        while at > 0 && steps[at - 1].cost > step.cost { at -= 1 }
        steps.insert(step, at: at)
    }

    private func bestReadings(_ ends: [Step], limit: Int) -> [Reading] {
        func trail(_ step: Step) -> [Step] {
            var all: [Step] = []
            var at: Step? = step
            while let current = at { all.append(current); at = current.previous }
            return all
        }
        let model = lexicon.model
        var queue: [Reading] = ends.map { step in
            let end = model != nil && step.context >= 0 ? -C.lmWeight * model!.logP(step.context, model!.end) : 0
            return Reading(cost: step.cost + end, steps: trail(step), from: 0)
        }
        guard let lowest = queue.map(\.cost).min() else { return [] }
        let worst = lowest + C.alternativeMargin
        var result: [Reading] = []
        var seen = Set<String>()
        var tried = 0
        while result.count < limit && tried < C.maxReadingsTried {
            tried += 1
            guard let at = queue.indices.min(by: { queue[$0].cost < queue[$1].cost }) else { break }
            let reading = queue.remove(at: at)
            if reading.cost > worst { break }
            if seen.insert(reading.steps.map { $0.word?.text ?? "" }.joined()).inserted { result.append(reading) }
            if result.count == limit { break }
            for index in reading.from..<reading.steps.count {
                let step = reading.steps[index]
                for other in step.alternates {
                    queue.append(Reading(cost: reading.cost + other.cost - step.cost, steps: Array(reading.steps[0..<index]) + trail(other), from: index + 1))
                }
            }
        }
        return result
    }

    private func readPieces(_ input: [UInt8], _ start: Int, _ taps: Taps?) -> [Piece] {
        var result: [Piece] = []
        var seen = Set<String>()
        func add(_ end: Int, _ text: String, _ isPrefix: Bool, _ cost: Float) {
            if seen.insert("\(end)/\(text)/\(isPrefix)").inserted { result.append(Piece(end: end, text: text, isPrefix: isPrefix, cost: cost)) }
        }
        var limit = start
        while limit < input.count && limit - start < C.maxSyllableLength + 1 && input[limit] != C.separator { limit += 1 }
        if limit > start {
            for end in (start + 1)...limit {
                let typed = String(decoding: input[start..<end], as: UTF8.self)
                let isRaw = lexicon.rawSyllables.contains(typed)
                if isRaw { add(end, typed, false, 0) }
                if end == input.count && typed.utf8.count >= 2 && !isRaw && lexicon.isSyllablePrefix(typed) {
                    add(end, typed, true, C.stillTypingCost)
                }
                let count = end - start
                let tapAt: (Int) -> [Float]? = { at in
                    guard let taps, start + at < taps.count else { return nil }
                    return taps[start + at]
                }
                let lostInitial = count <= 2 && C.zeroInitialVowels.contains(input[start])
                let noSyllable = count == 2 && !isRaw && input[start..<end].contains { C.zeroInitialVowels.contains($0) }
                if count >= 3 || (count == 2 && input[end - 1] == 110) || lostInitial || noSyllable {
                    for (fixed, cost) in corrections(Array(input[start..<end]), tapAt) { add(end, fixed, false, cost) }
                } else if count == 2 && taps != nil {
                    // Two letters could as well be 简拼, unless the taps say a key was nearly missed.
                    for (fixed, cost) in corrections(Array(input[start..<end]), tapAt, tapsOnly: true) {
                        add(end, fixed, false, cost + C.shortTouchSlipCost)
                    }
                }
            }
        }
        let first = input[start]
        if C.initials.contains(first) {
            func costBefore(_ next: Int) -> Float {
                next < input.count && C.vowels.contains(input[next]) ? C.initialBeforeVowelCost : C.initialCost
            }
            let two = String(decoding: input[start..<min(start + 2, input.count)], as: UTF8.self)
            if C.compoundInitials.contains(two) { add(start + 2, two, true, costBefore(start + 2)) }
            add(start + 1, String(UnicodeScalar(first)), true, costBefore(start + 1))
        }
        return result
    }

    private func corrections(_ typed: [UInt8], _ tapAt: (Int) -> [Float]?, tapsOnly: Bool = false) -> [(String, Float)] {
        var result: [(String, Float)] = []
        let raw = lexicon.rawSyllables
        func consider(_ candidate: [UInt8], _ cost: Float) {
            if candidate == typed { return }
            let text = String(decoding: candidate, as: UTF8.self)
            if raw.contains(text) { result.append((text, cost)) }
        }
        /// Each letter with a tap swapped for another key, at what the tap says that costs.
        func addTapSlips() {
            for at in typed.indices {
                guard let costs = tapAt(at), typed[at] >= 97, typed[at] <= 122 else { continue }
                let own = Int(typed[at]) - 97
                for letter in 0..<26 where letter != own && costs[letter].isFinite {
                    let extra = max(costs[letter] - costs[own], 0)
                    if extra > C.maxTouchExtra { continue }
                    var other = typed
                    other[at] = UInt8(97 + letter)
                    consider(other, C.touchSlipCost + C.touchWeight * extra)
                }
            }
        }
        if tapsOnly {
            addTapSlips()
            return Self.cheapestOfEach(result)
        }
        if C.zeroInitialVowels.contains(typed[0]) {
            consider([UInt8(ascii: "y")] + typed, C.lostInitialCost)
            consider([UInt8(ascii: "w")] + typed, C.lostInitialCost)
        }
        if typed.last == 110 { consider(typed + [103], C.nasalCost) }
        if typed.count >= 2, typed.suffix(2) == [110, 103] { consider(Array(typed.dropLast()), C.nasalCost) }
        for at in 0...typed.count {
            for letter in UInt8(ascii: "a")...UInt8(ascii: "z") {
                consider(Array(typed[0..<at]) + [letter] + Array(typed[at...]), C.missingLetterCost)
            }
        }
        for at in typed.indices {
            var fewer = typed
            fewer.remove(at: at)
            if !fewer.isEmpty { consider(fewer, C.slipCost) }
        }
        addTapSlips()
        for at in typed.indices {
            if tapAt(at) != nil && typed[at] >= 97 && typed[at] <= 122 { continue }
            for neighbour in Self.neighbours[typed[at]] ?? [] {
                var other = typed
                other[at] = neighbour
                consider(other, C.slipCost)
            }
        }
        if typed.count >= 2 {
            for at in 0..<(typed.count - 1) {
                var swapped = typed
                swapped.swapAt(at, at + 1)
                consider(swapped, C.slipCost)
            }
        }
        return Self.cheapestOfEach(result)
    }

    private static func cheapestOfEach(_ result: [(String, Float)]) -> [(String, Float)] {
        var chosen: [String: Float] = [:]
        var order: [String] = []
        for (index, item) in result.enumerated().sorted(by: { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }) {
            _ = index
            if chosen[item.0] == nil { chosen[item.0] = item.1; order.append(item.0) }
        }
        return order.map { ($0, chosen[$0]!) }
    }
}
