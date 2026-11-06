import Foundation

/// Letter trigrams P(c | a, b) over {boundary, a..z}: a bundled prior that the user's own typing
/// gradually outweighs. Follows typing/CharLanguageModel.kt. Characters are ASCII bytes.
public final class CharLanguageModel {
    static let alphabet = 27
    private static let contextCount = alphabet * alphabet
    private static let trigramCount = contextCount * alphabet
    private static let priorScale = 16.0
    private static let personalPriorStrength: Float = 40
    private static let maxContextCount: Float = 4000
    private static let minProbability: Float = 1e-4
    private static let magic: UInt32 = 0x5A4E_4C4D
    private static let version: UInt32 = 1
    private static let headerBytes = 8

    private var prior: [UInt8]?
    private var personal = [Float](repeating: 0, count: trigramCount)
    private var contextTotals = [Float](repeating: 0, count: contextCount)

    public init() {}

    public func setPrior(_ data: Data?) {
        prior = data.flatMap { $0.count == Self.trigramCount ? [UInt8]($0) : nil }
    }

    private static func index(_ char: UInt8) -> Int {
        let lower = char >= 65 && char <= 90 ? char + 32 : char
        return lower >= 97 && lower <= 122 ? Int(lower) - 96 : 0
    }

    /// A lowercase letter, or the space that stands for every boundary.
    public static func normalize(_ char: Character) -> UInt8 {
        guard let ascii = char.asciiValue else { return 32 }
        let lower = ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii
        return lower >= 97 && lower <= 122 ? lower : 32
    }

    func logProb(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Float {
        let context = Self.index(a) * Self.alphabet + Self.index(b)
        let trigram = context * Self.alphabet + Self.index(c)
        let base = prior.map { Float(pow(2.0, -Double($0[trigram]) / Self.priorScale)) } ?? 1 / Float(Self.alphabet)
        let p = (personal[trigram] + Self.personalPriorStrength * base) / (contextTotals[context] + Self.personalPriorStrength)
        return log(max(p, Self.minProbability))
    }

    func learn(_ a: UInt8, _ b: UInt8, _ c: UInt8) {
        let context = Self.index(a) * Self.alphabet + Self.index(b)
        personal[context * Self.alphabet + Self.index(c)] += 1
        contextTotals[context] += 1
        if contextTotals[context] > Self.maxContextCount {
            let start = context * Self.alphabet
            for offset in 0..<Self.alphabet { personal[start + offset] *= 0.5 }
            contextTotals[context] *= 0.5
        }
    }

    public func encodePersonal() -> Data {
        var data = Data(capacity: Self.headerBytes + Self.trigramCount * 4)
        data.appendLittleEndian(Self.magic)
        data.appendLittleEndian(Self.version)
        for value in personal { data.appendLittleEndian(value.bitPattern) }
        return data
    }

    public func decodePersonal(_ data: Data) -> Bool {
        guard data.count == Self.headerBytes + Self.trigramCount * 4,
              data.littleEndian(at: 0) == Self.magic, data.littleEndian(at: 4) == Self.version else { return false }
        var decoded = [Float](repeating: 0, count: Self.trigramCount)
        for index in decoded.indices {
            let value = Float(bitPattern: data.littleEndian(at: Self.headerBytes + index * 4))
            if !value.isFinite || value < 0 { return false }
            decoded[index] = value
        }
        personal = decoded
        contextTotals = [Float](repeating: 0, count: Self.contextCount)
        for trigram in 0..<Self.trigramCount { contextTotals[trigram / Self.alphabet] += personal[trigram] }
        return true
    }
}
