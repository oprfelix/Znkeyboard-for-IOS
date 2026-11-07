import Foundation

/// 9-key (九宫格) pinyin. The composition is the syllables locked from the spelling list, then the
/// digits typed, as "ni'4426" or "64426"; a typed separator ("94'26" for xi'an) makes words split
/// there. Follows NineKeyEngine.kt. The letters and digits are all ASCII.
public enum NineKey {
    public static let separator: Character = "'"
    private static let keys: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl", "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]
    private static let digits: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (digit, letters) in keys { for letter in letters { map[letter] = digit } }
        return map
    }()

    /// "nihao" → "64426".
    public static func code(_ text: String) -> String { String(text.map { digits[$0] ?? $0 }) }

    static func letters(of digit: Character) -> [String] { (keys[digit] ?? "").map(String.init) }

    struct Parsed {
        var locked: [String] = []
        var digits = ""
        /// Digit offsets of typed separators.
        var boundaries = Set<Int>()
        /// Where the digits begin in the composition.
        var digitStart = 0

        init(_ composing: String) {
            let all = Array(composing)
            var at = 0
            while at < all.count, all[at].isLetter {
                var end = at
                while end < all.count, all[end].isLetter { end += 1 }
                locked.append(String(all[at..<end]))
                at = end < all.count && all[end] == separator ? end + 1 : end
            }
            digitStart = at
            for character in all[at...] {
                if character == separator { boundaries.insert(digits.count) } else { digits.append(character) }
            }
        }
    }

    /// How much of [composing] a candidate using [digits] digits takes up, with a following separator.
    static func consumed(_ composing: String, _ parsed: Parsed, digits: Int) -> Int {
        let all = Array(composing)
        var at = parsed.digitStart
        var counted = 0
        while at < all.count, counted < digits {
            if all[at] != separator { counted += 1 }
            at += 1
        }
        if at < all.count, all[at] == separator { at += 1 }
        return at
    }

    /// What the field shows while typing: pinyin, not digits ("ni'hao" for 64426).
    static func display(_ composing: String, _ lexicon: PinyinLexicon, top: PinyinEngine.Candidate?) -> String {
        let parsed = Parsed(composing)
        if parsed.digits.isEmpty { return parsed.locked.joined(separator: String(separator)) }
        // The top word's own pinyin when it spells exactly the digits typed; while a syllable is
        // still being typed (6442 → ni'ha), what was typed, not the word's completion (ni'hao).
        var rest: [String]?
        if let syllables = top?.syllables.dropFirst(parsed.locked.count), !syllables.isEmpty, code(syllables.joined()) == parsed.digits {
            rest = Array(syllables)
        }
        let spelled = rest ?? lexicon.nineKeySpell(parsed.digits)
        return (parsed.locked + (spelled.isEmpty ? [parsed.digits] : spelled)).joined(separator: String(separator))
    }

    /// Spellings for the first digits not yet locked, for the list above the candidates.
    static func spellings(_ composing: String, _ lexicon: PinyinLexicon) -> [String] {
        let parsed = Parsed(composing)
        let end = parsed.boundaries.filter { $0 > 0 }.min() ?? parsed.digits.count
        return lexicon.nineKeySpellings(String(parsed.digits.prefix(end)))
    }

    /// Locks [spelling] in place of the digits it was typed with.
    public static func lock(_ composing: String, _ spelling: String) -> String {
        let parsed = Parsed(composing)
        let spelled = code(spelling)
        guard parsed.digits.hasPrefix(spelled) else { return composing }
        let all = Array(composing)
        var at = parsed.digitStart
        var counted = 0
        while at < all.count, counted < spelled.count {
            if all[at] != separator { counted += 1 }
            at += 1
        }
        while at < all.count, all[at] == separator { at += 1 }
        let locked = (parsed.locked + [spelling]).joined(separator: String(separator))
        return at < all.count ? locked + String(separator) + String(all[at...]) : locked
    }

    /// Whether nothing is left but locked syllables.
    public static func isSpelled(_ composing: String) -> Bool { Parsed(composing).digits.isEmpty }

    /// Deletes the last digit; a locked syllable goes back to its digits first.
    public static func backspace(_ composing: String) -> String {
        guard let last = composing.last else { return composing }
        if !last.isLetter { return String(composing.dropLast()) }
        let parsed = Parsed(composing)
        let prefix = parsed.locked.dropLast().joined(separator: String(separator))
        let spelled = code(parsed.locked.last!)
        return prefix.isEmpty ? spelled : prefix + String(separator) + spelled
    }
}
