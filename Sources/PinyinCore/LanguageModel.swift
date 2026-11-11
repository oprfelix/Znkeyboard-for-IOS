import Foundation

/// The word bigram model from lm.bin, the same file as the Android keyboard, memory-mapped and
/// read in place (big-endian). See PinyinLanguageModel.kt.
public final class LanguageModel {
    private let base: UnsafeRawPointer
    private let size: Int
    public let words: Int
    private let unigramAt = 20
    private let backoffAt: Int
    private let offsetsAt: Int
    private let pairsAt: Int

    public init?(path: String) {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 20 else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, file, 0), mapped != MAP_FAILED else { return nil }
        let start = UnsafeRawPointer(mapped)
        guard memcmp(start, "ZNLM", 4) == 0 else { return nil }
        let count = Int(start.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian)
        base = start
        size = length
        words = count
        backoffAt = 20 + (count + 2) * 2
        offsetsAt = backoffAt + (count + 2) * 2
        pairsAt = offsetsAt + (count + 3) * 4
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    public var start: Int { words }
    public var end: Int { words + 1 }

    private func int(_ at: Int) -> Int32 { Int32(bitPattern: base.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian) }
    private func short(_ at: Int) -> Int16 { Int16(bitPattern: base.loadUnaligned(fromByteOffset: at, as: UInt16.self).bigEndian) }

    public func unigram(_ word: Int) -> Float { Float(short(unigramAt + word * 2)) / 1000 }

    /// The words seen after [previous], likeliest first, with ln P(word | previous).
    public func followers(_ previous: Int, limit: Int) -> [(word: Int, logP: Float)] {
        if previous < 0 || previous >= words || limit <= 0 { return [] }
        let low = Int(int(offsetsAt + previous * 4))
        let high = Int(int(offsetsAt + (previous + 1) * 4))
        if high <= low { return [] }
        var found: [(word: Int, logP: Float)] = []
        found.reserveCapacity(high - low)
        for at in low..<high {
            let pair = UInt32(bitPattern: int(pairsAt + at * 4))
            let id = Int(pair >> 14)
            if id < words { found.append((id, -Float(pair & 0x3FFF) / 400)) }
        }
        found.sort { $0.logP > $1.logP }
        return Array(found.prefix(limit))
    }

    /// ln P([word] | [previous]).
    public func logP(_ previous: Int, _ word: Int) -> Float {
        if previous < 0 { return unigram(word) }
        var low = Int(int(offsetsAt + previous * 4))
        var high = Int(int(offsetsAt + (previous + 1) * 4)) - 1
        while low <= high {
            let mid = (low + high) >> 1
            let pair = UInt32(bitPattern: int(pairsAt + mid * 4))
            let id = Int(pair >> 14)
            if id < word { low = mid + 1 } else if id > word { high = mid - 1 } else {
                return -Float(pair & 0x3FFF) / 400
            }
        }
        return Float(short(backoffAt + previous * 2)) / 1000 + unigram(word)
    }
}
