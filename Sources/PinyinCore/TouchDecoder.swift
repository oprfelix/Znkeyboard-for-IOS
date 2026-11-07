import Foundation

/// The letter keys as the keyboard draws them: centres by letter, and the distance between keys.
public struct KeyGeometry {
    public var centersX: [Float]
    public var centersY: [Float]
    public var pitchX: Float
    public var pitchY: Float

    public init(centersX: [Float], centersY: [Float], pitchX: Float, pitchY: Float) {
        self.centersX = centersX
        self.centersY = centersY
        self.pitchX = pitchX
        self.pitchY = pitchY
    }
}

/// Which letter a touch meant: the best of log P(touch | key, this hand) + λ log P(key | before).
/// A touch on the centre of a key always types that key, and only keys within about 1.6 pitches
/// compete. Follows typing/TouchDecoder.kt.
public final class TouchDecoder {
    static let anchorXFraction: Float = 0.30
    static let anchorYFraction: Float = 0.28
    private static let candidatePitches: Float = 1.6
    private static let languageWeight: Float = 0.7

    private let touchModel: () -> TouchModel
    private let languageModel: () -> CharLanguageModel

    public init(touchModel: @escaping () -> TouchModel, languageModel: @escaping () -> CharLanguageModel) {
        self.touchModel = touchModel
        self.languageModel = languageModel
    }

    public func decode(x: Float, y: Float, geometricLetter: Int, keys: KeyGeometry, previous2: UInt8, previous1: UInt8, useLanguageModel: Bool) -> Int {
        if abs(x - keys.centersX[geometricLetter]) <= Self.anchorXFraction * keys.pitchX,
           abs(y - keys.centersY[geometricLetter]) <= Self.anchorYFraction * keys.pitchY {
            return geometricLetter
        }
        let model = touchModel()
        let language = languageModel()
        var best = geometricLetter
        var bestScore = -Float.infinity
        for letter in 0..<TouchModel.letterCount {
            let cx = keys.centersX[letter], cy = keys.centersY[letter]
            if abs(x - cx) > Self.candidatePitches * keys.pitchX || abs(y - cy) > Self.candidatePitches * keys.pitchY { continue }
            let params = model.params(letter, pitchX: keys.pitchX, pitchY: keys.pitchY)
            let dx = x - cx - params.meanX
            let dy = y - cy - params.meanY
            var score = -0.5 * (dx * dx / params.varX + dy * dy / params.varY) - 0.5 * log(params.varX * params.varY)
            if useLanguageModel {
                score += Self.languageWeight * language.logProb(previous2, previous1, UInt8(97 + letter))
            }
            if score > bestScore {
                bestScore = score
                best = letter
            }
        }
        return best
    }

    /// How well a touch fits each letter, the best being 0 and those too far +∞, for pinyin to
    /// weigh later against what the letters spell.
    public func letterCosts(x: Float, y: Float, keys: KeyGeometry) -> [Float] {
        let model = touchModel()
        var costs = [Float](repeating: .infinity, count: TouchModel.letterCount)
        var best = Float.infinity
        for letter in 0..<TouchModel.letterCount {
            let cx = keys.centersX[letter], cy = keys.centersY[letter]
            if abs(x - cx) > Self.candidatePitches * keys.pitchX || abs(y - cy) > Self.candidatePitches * keys.pitchY { continue }
            let params = model.params(letter, pitchX: keys.pitchX, pitchY: keys.pitchY)
            let dx = x - cx - params.meanX
            let dy = y - cy - params.meanY
            let cost = 0.5 * (dx * dx / params.varX + dy * dy / params.varY) + 0.5 * log(params.varX * params.varY)
            costs[letter] = cost
            if cost < best { best = cost }
        }
        for letter in 0..<TouchModel.letterCount { costs[letter] -= best }
        return costs
    }
}
