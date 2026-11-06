import Foundation

/// The tap behind each letter being composed: how it fitted every key, and its record for the
/// touch learner. It follows the composition, so it stays lined up as letters are typed, deleted
/// or taken by a picked candidate; any other change forgets the taps. Follows PinyinTapBuffer.kt.
struct PinyinTapBuffer {
    /// More edits than this and a reading is not a correction of what was typed.
    private static let maxEdits = 4

    private var costs: [[Float]?] = []
    private var tokens: [TypingLearner.Sample?] = []

    /// What a decoder needs; a value, so it can go to another thread.
    var snapshot: SentenceDecoder.Taps { costs }

    func token(at index: Int) -> TypingLearner.Sample? { index < tokens.count ? tokens[index] : nil }

    mutating func follow(_ old: String, _ new: String, tap: [Float]?, token: TypingLearner.Sample?) {
        if new == old { return }
        let oldCount = old.utf8.count, newCount = new.utf8.count
        if newCount == oldCount + 1, new.hasPrefix(old) {
            pad(oldCount)
            costs.append(tap)
            tokens.append(token)
        } else if newCount < oldCount, old.hasPrefix(new) {
            pad(newCount)
            costs.removeLast(costs.count - newCount)
            tokens.removeLast(tokens.count - newCount)
        } else if newCount < oldCount, old.hasSuffix(new) {
            pad(oldCount)
            costs.removeFirst(oldCount - newCount)
            tokens.removeFirst(oldCount - newCount)
        } else {
            costs = [[Float]?](repeating: nil, count: newCount)
            tokens = [TypingLearner.Sample?](repeating: nil, count: newCount)
        }
    }

    private mutating func pad(_ count: Int) {
        while costs.count < count {
            costs.append(nil)
            tokens.append(nil)
        }
        if costs.count > count {
            costs.removeLast(costs.count - count)
            tokens.removeLast(tokens.count - count)
        }
    }

    /// Letters of [typed] that [spelling] reads as another letter: (index in typed, letter meant).
    /// Letters added, dropped or swapped are left out, as is anything that does not line up.
    static func substitutions(_ typed: String, _ spelling: String) -> [(at: Int, letter: UInt8)] {
        let bytes = Array(typed.utf8)
        let at = bytes.indices.filter { bytes[$0] != UInt8(ascii: "'") }
        let a = at.map { bytes[$0] }
        let b = spelling.utf8.filter { $0 != 32 }
        if a.isEmpty || b.isEmpty { return [] }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        if d[a.count][b.count] > maxEdits { return [] }
        var result: [(at: Int, letter: UInt8)] = []
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1], d[i][j] == d[i - 2][j - 2] + 1 {
                i -= 2
                j -= 2
            } else if d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                if a[i - 1] != b[j - 1] { result.append((at[i - 1], b[j - 1])) }
                i -= 1
                j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }
}
