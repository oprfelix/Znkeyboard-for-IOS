import Foundation

/// English words offered among the candidates when the letters spell one: a port of EnglishWords.kt.
public final class EnglishWords {
    private static let minLength = 4
    private static let promoteAt = 2
    private static let maxRemembered = 500
    private let displayed: [String: String]
    private var uses: [String: Int] = [:]
    private var order: [String] = []

    /// One word per line, as it should appear.
    public init(words: String) {
        var map: [String: String] = [:]
        for line in words.split(separator: "\n") where map[line.lowercased()] == nil {
            map[line.lowercased()] = String(line)
        }
        displayed = map
    }

    func merge(_ input: String, _ candidates: [PinyinEngine.Candidate], whole: Bool) -> [PinyinEngine.Candidate] {
        guard input.utf8.count >= Self.minLength, let word = displayed[input] else { return candidates }
        let first = (uses[input] ?? 0) >= Self.promoteAt || !whole
        var result = candidates
        result.insert(PinyinEngine.Candidate(text: word, consumed: input.utf8.count, syllables: [], parts: nil, spelling: nil, id: PinyinEngine.englishId), at: first ? 0 : min(1, candidates.count))
        return result
    }

    public func picked(_ word: String) {
        let key = word.lowercased()
        if uses[key] == nil { order.append(key) }
        uses[key] = min((uses[key] ?? 0) + 1, Self.promoteAt)
        while uses.count > Self.maxRemembered { uses[order.removeFirst()] = nil }
    }

    public func forget(_ word: String) -> Bool {
        let key = word.lowercased()
        order.removeAll { $0 == key }
        return uses.removeValue(forKey: key) != nil
    }
}
