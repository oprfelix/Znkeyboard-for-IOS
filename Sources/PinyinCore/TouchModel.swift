import Foundation

/// Where this user's finger lands on each of the 26 letter keys, relative to the key's centre,
/// in points. Each key keeps forgetting statistics, shrunk key → region → a neutral prior, so rare
/// keys borrow the offset of their neighbours. Follows typing/TouchModel.kt; the files are alike.
public final class TouchModel {
    public static let letterCount = 26
    static let statCount = 5
    private static let magic: UInt32 = 0x5A4E_544D
    private static let version: UInt32 = 1
    private static let headerBytes = 8
    private static let priorSigma: Float = 10
    private static let minSigma: Float = 5
    private static let maxSigma: Float = 20
    private static let keyPriorStrength: Float = 15
    private static let regionPriorStrength: Float = 30
    private static let maxMeanPitchFraction: Float = 0.45
    private static let decay: Float = 0.997
    /// QWERTY row × thumb side.
    private static let regionOfLetter: [Int] = {
        var regions = [Int](repeating: 0, count: letterCount)
        for (region, letters) in ["qwert", "yuiop", "asdfg", "hjkl", "zxcv", "bnm"].enumerated() {
            for letter in letters.utf8 { regions[Int(letter) - 97] = region }
        }
        return regions
    }()

    private var stats = [Float](repeating: 0, count: letterCount * statCount)

    public init() {}

    public var sampleCount: Float {
        stride(from: 0, to: stats.count, by: Self.statCount).reduce(Float(0)) { $0 + stats[$1] }
    }

    public func learn(_ letter: Int, dx: Float, dy: Float, pitchX: Float, pitchY: Float) {
        guard (0..<Self.letterCount).contains(letter) else { return }
        // A touch more than a full key away was not an attempt at this key.
        if abs(dx) > pitchX || abs(dy) > pitchY { return }
        let base = letter * Self.statCount
        for index in 0..<Self.statCount { stats[base + index] *= Self.decay }
        stats[base] += 1
        stats[base + 1] += dx
        stats[base + 2] += dy
        stats[base + 3] += dx * dx
        stats[base + 4] += dy * dy
    }

    /// The (meanX, meanY, varianceX, varianceY) for [letter]; a mean never reaches a neighbour.
    func params(_ letter: Int, pitchX: Float, pitchY: Float) -> (meanX: Float, meanY: Float, varX: Float, varY: Float) {
        let region = Self.regionOfLetter[letter]
        var rn: Float = 0, rsx: Float = 0, rsy: Float = 0, rsxx: Float = 0, rsyy: Float = 0
        for other in 0..<Self.letterCount where Self.regionOfLetter[other] == region {
            let base = other * Self.statCount
            rn += stats[base]
            rsx += stats[base + 1]
            rsy += stats[base + 2]
            rsxx += stats[base + 3]
            rsyy += stats[base + 4]
        }
        let priorVariance = Self.priorSigma * Self.priorSigma
        let regionWeight = Self.regionPriorStrength + rn
        let regionMeanX = rsx / regionWeight
        let regionMeanY = rsy / regionWeight
        let regionVarX = (Self.regionPriorStrength * priorVariance + rsxx) / regionWeight - regionMeanX * regionMeanX * (rn / regionWeight)
        let regionVarY = (Self.regionPriorStrength * priorVariance + rsyy) / regionWeight - regionMeanY * regionMeanY * (rn / regionWeight)

        let base = letter * Self.statCount
        let keyWeight = Self.keyPriorStrength + stats[base]
        let meanX = (Self.keyPriorStrength * regionMeanX + stats[base + 1]) / keyWeight
        let meanY = (Self.keyPriorStrength * regionMeanY + stats[base + 2]) / keyWeight
        let varX = (Self.keyPriorStrength * (regionVarX + regionMeanX * regionMeanX) + stats[base + 3]) / keyWeight - meanX * meanX
        let varY = (Self.keyPriorStrength * (regionVarY + regionMeanY * regionMeanY) + stats[base + 4]) / keyWeight - meanY * meanY

        func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }
        let lowVar = Self.minSigma * Self.minSigma, highVar = Self.maxSigma * Self.maxSigma
        return (
            clamp(meanX, -Self.maxMeanPitchFraction * pitchX, Self.maxMeanPitchFraction * pitchX),
            clamp(meanY, -Self.maxMeanPitchFraction * pitchY, Self.maxMeanPitchFraction * pitchY),
            clamp(varX, lowVar, highVar),
            clamp(varY, lowVar, highVar)
        )
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.headerBytes + stats.count * 4)
        data.appendLittleEndian(Self.magic)
        data.appendLittleEndian(Self.version)
        for value in stats { data.appendLittleEndian(value.bitPattern) }
        return data
    }

    public static func decode(_ data: Data) -> TouchModel? {
        guard data.count == headerBytes + letterCount * statCount * 4,
              data.littleEndian(at: 0) == magic, data.littleEndian(at: 4) == version else { return nil }
        let model = TouchModel()
        for index in model.stats.indices {
            let value = Float(bitPattern: data.littleEndian(at: headerBytes + index * 4))
            if !value.isFinite { return nil }
            model.stats[index] = value
        }
        return model
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func littleEndian(at offset: Int) -> UInt32 {
        let at = startIndex + offset
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
}
