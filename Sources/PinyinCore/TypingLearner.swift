import Foundation

/// Learns from ordinary typing. A letter that survives the next few keys confirms where its touch
/// landed; one deleted and retyped as a neighbour teaches that neighbour; and a pinyin reading that
/// took a tap as another key does the same. Follows typing/TypingLearner.kt.
public final class TypingLearner {
    public final class Sample {
        public let letter: Int
        let x: Float
        let y: Float
        let keys: KeyGeometry
        var correctedLetter = -1
        var confirmed = false

        public init(letter: Int, x: Float, y: Float, keys: KeyGeometry) {
            self.letter = letter
            self.x = x
            self.y = y
            self.keys = keys
        }
    }

    private final class Entry {
        let char: UInt8
        let sample: Sample?
        var time: Int64

        init(_ char: UInt8, _ sample: Sample?, _ time: Int64) {
            self.char = char
            self.sample = sample
            self.time = time
        }
    }

    private static let pendingCapacity = 10
    private static let contextCapacity = 16
    private static let repairWindow: Int64 = 8000
    private static let neighbourXPitches: Float = 1.6
    private static let neighbourYPitches: Float = 1.25
    private static let sameSpotFraction: Float = 0.12
    private static let space: UInt8 = 32

    private let touchModel: () -> TouchModel
    private let languageModel: () -> CharLanguageModel
    private let clock: () -> Int64
    private var pending: [Entry] = []
    private var deleted: [Entry] = []
    private var context: [UInt8] = []
    private var confirmed2 = TypingLearner.space
    private var confirmed1 = TypingLearner.space
    public private(set) var confirmations = 0

    public init(touchModel: @escaping () -> TouchModel, languageModel: @escaping () -> CharLanguageModel, clock: @escaping () -> Int64) {
        self.touchModel = touchModel
        self.languageModel = languageModel
        self.clock = clock
    }

    public var previous2: UInt8 { context.count >= 2 ? context[context.count - 2] : Self.space }
    public var previous1: UInt8 { context.last ?? Self.space }

    public func onCommitted(_ char: Character, _ sample: Sample?) {
        let normalized = CharLanguageModel.normalize(char)
        appendContext(normalized)
        let now = clock()
        if normalized == Self.space {
            deleted.removeAll()
        } else if let replaced = deleted.popLast() {
            relabel(replaced, normalized, sample, now)
        }
        pending.append(Entry(normalized, sample, now))
        while pending.count > Self.pendingCapacity { confirm(pending.removeFirst()) }
    }

    public func onBackspace() {
        if !context.isEmpty { context.removeLast() }
        guard let entry = pending.popLast() else {
            deleted.removeAll()
            return
        }
        entry.time = clock()
        deleted.append(entry)
        while deleted.count > Self.pendingCapacity { deleted.removeFirst() }
    }

    /// The field changed underneath the keyboard: accept what was typed and read the context anew.
    public func onContextChanged(_ textBeforeCaret: String?) {
        flush()
        context = (textBeforeCaret ?? "").suffix(Self.contextCapacity).map(CharLanguageModel.normalize)
        confirmed2 = previous2
        confirmed1 = previous1
    }

    public func flush() {
        while !pending.isEmpty { confirm(pending.removeFirst()) }
        deleted.removeAll()
    }

    /// The user took a reading that read [sample]'s tap as [letter].
    public func correct(_ sample: Sample, _ letter: Int) {
        guard letter != sample.letter, (0..<TouchModel.letterCount).contains(letter) else { return }
        let keys = sample.keys
        let targetX = keys.centersX[letter], targetY = keys.centersY[letter]
        if abs(sample.x - targetX) > Self.neighbourXPitches * keys.pitchX { return }
        if abs(sample.y - targetY) > Self.neighbourYPitches * keys.pitchY { return }
        if !sample.confirmed {
            sample.correctedLetter = letter
            return
        }
        confirmations += 1
        touchModel().learn(letter, dx: sample.x - targetX, dy: sample.y - targetY, pitchX: keys.pitchX, pitchY: keys.pitchY)
    }

    private func relabel(_ replaced: Entry, _ replacement: UInt8, _ replacementSample: Sample?, _ now: Int64) {
        guard let original = replaced.sample, replacement != replaced.char, replacement >= 97, replacement <= 122,
              now - replaced.time <= Self.repairWindow else { return }
        let target = Int(replacement) - 97
        let keys = original.keys
        // Only neighbours count: deleting a word to write another is an edit, not a mistap.
        let targetX = keys.centersX[target], targetY = keys.centersY[target]
        if abs(original.x - targetX) > Self.neighbourXPitches * keys.pitchX { return }
        if abs(original.y - targetY) > Self.neighbourYPitches * keys.pitchY { return }
        // Retyped right where the deleted one landed: the user changed their mind.
        if let again = replacementSample,
           abs(again.x - original.x) < Self.sameSpotFraction * keys.pitchX,
           abs(again.y - original.y) < Self.sameSpotFraction * keys.pitchY,
           again.letter == original.letter { return }
        confirmations += 1
        touchModel().learn(target, dx: original.x - targetX, dy: original.y - targetY, pitchX: keys.pitchX, pitchY: keys.pitchY)
    }

    private func confirm(_ entry: Entry) {
        confirmations += 1
        if let sample = entry.sample, sample.letter == Int(entry.char) - 97 {
            let letter = sample.correctedLetter >= 0 ? sample.correctedLetter : sample.letter
            let keys = sample.keys
            touchModel().learn(letter, dx: sample.x - keys.centersX[letter], dy: sample.y - keys.centersY[letter], pitchX: keys.pitchX, pitchY: keys.pitchY)
            sample.confirmed = true
        }
        if entry.char != Self.space || confirmed1 != Self.space {
            languageModel().learn(confirmed2, confirmed1, entry.char)
        }
        confirmed2 = confirmed1
        confirmed1 = entry.char
    }

    private func appendContext(_ char: UInt8) {
        context.append(char)
        if context.count > Self.contextCapacity * 2 { context.removeFirst(context.count - Self.contextCapacity) }
    }
}
