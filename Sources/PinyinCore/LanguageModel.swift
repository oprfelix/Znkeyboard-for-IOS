import Foundation

/// The word bigram model from lm.bin, the same file as the Android keyboard, memory-mapped and
/// read in place (big-endian). Each context's pairs are blocks of Rice-coded word gaps with a
/// byte per probability; a lookup binary-searches the block heads and decodes at most one block.
/// See build_lm.py for the layout and PinyinLanguageModel.kt for the same reader in Kotlin.
public final class LanguageModel {
    private static let headerBytes = 32
    private static let version = 2
    private static let codes = 256
    private static let riceBits = 5
    private static let streamPadding = 8
    /// Bits of a window that are surely the stream's: 64 less up to 7 shifted in.
    private static let windowBits = 57

    private let base: UnsafeRawPointer
    private let size: Int
    public let words: Int
    private let blockSize: Int
    private let unigramAt = LanguageModel.headerBytes
    private let backoffAt: Int
    private let pairOffsetsAt: Int
    private let blockOffsetsAt: Int
    private let headsAt: Int
    private let bitOffsetsAt: Int
    private let codesAt: Int
    private let streamAt: Int
    private let codebook: [Float]

    public init?(path: String) {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > LanguageModel.headerBytes else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, file, 0), mapped != MAP_FAILED else { return nil }
        let start = UnsafeRawPointer(mapped)
        func header(_ at: Int) -> Int { Int(Int32(bitPattern: start.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian)) }
        let words = header(8), pairs = header(16), blocks = header(20), blockSize = header(24), streamBytes = header(28)
        let expected = LanguageModel.headerBytes + (words + 2) * 4 + LanguageModel.codes * 2 + (words + 3) * 8 +
            blocks * 8 + pairs + streamBytes + LanguageModel.streamPadding
        guard memcmp(start, "ZNLM", 4) == 0, header(4) == LanguageModel.version, words > 0, pairs >= 0, blocks >= 0,
              blockSize > 0, streamBytes >= 0, expected == length else {
            munmap(mapped, length)
            return nil
        }
        base = start
        size = length
        self.words = words
        self.blockSize = blockSize
        backoffAt = unigramAt + (words + 2) * 2
        let codebookAt = backoffAt + (words + 2) * 2
        pairOffsetsAt = codebookAt + LanguageModel.codes * 2
        blockOffsetsAt = pairOffsetsAt + (words + 3) * 4
        headsAt = blockOffsetsAt + (words + 3) * 4
        bitOffsetsAt = headsAt + blocks * 4
        codesAt = bitOffsetsAt + blocks * 4
        streamAt = codesAt + pairs
        codebook = (0..<LanguageModel.codes).map {
            -Float(Int16(bitPattern: start.loadUnaligned(fromByteOffset: codebookAt + $0 * 2, as: UInt16.self).bigEndian)) / 400
        }
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    public var start: Int { words }
    public var end: Int { words + 1 }

    private func int(_ at: Int) -> Int { Int(Int32(bitPattern: base.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian)) }
    private func short(_ at: Int) -> Int16 { Int16(bitPattern: base.loadUnaligned(fromByteOffset: at, as: UInt16.self).bigEndian) }
    private func probability(_ pair: Int) -> Float { codebook[Int(base.load(fromByteOffset: codesAt + pair, as: UInt8.self))] }

    /// The stream's bits from [bit] on, the first at the top.
    private func window(_ bit: Int) -> UInt64 {
        base.loadUnaligned(fromByteOffset: streamAt + bit >> 3, as: UInt64.self).bigEndian << UInt64(bit & 7)
    }

    /// The Rice-coded gap at [bit] with parameter [k] (the quotient in unary as ones and a zero,
    /// then k bits), and the bits it took.
    private func gap(_ bit: Int, _ k: Int) -> (gap: Int, bits: Int) {
        var at = bit
        var quotient = 0
        while true {
            let ones = (~window(at)).leadingZeroBitCount
            if ones < LanguageModel.windowBits {
                quotient += ones
                at += ones + 1
                break
            }
            quotient += LanguageModel.windowBits
            at += LanguageModel.windowBits
        }
        let remainder = k == 0 ? 0 : Int(window(at) >> UInt64(64 - k))
        at += k
        return ((quotient << k | remainder) + 1, at - bit)
    }

    public func unigram(_ word: Int) -> Float { Float(short(unigramAt + word * 2)) / 1000 }

    /// The words seen after [previous], likeliest first, with ln P(word | previous).
    public func followers(_ previous: Int, limit: Int) -> [(word: Int, logP: Float)] {
        if previous < 0 || previous >= words || limit <= 0 { return [] }
        let firstPair = int(pairOffsetsAt + previous * 4)
        let endPair = int(pairOffsetsAt + (previous + 1) * 4)
        if endPair <= firstPair { return [] }
        let firstBlock = int(blockOffsetsAt + previous * 4)
        let endBlock = int(blockOffsetsAt + (previous + 1) * 4)
        var found: [(word: Int, logP: Float)] = []
        found.reserveCapacity(endPair - firstPair)
        for block in firstBlock..<endBlock {
            let pair = firstPair + (block - firstBlock) * blockSize
            let count = min(blockSize, endPair - pair)
            let head = int(headsAt + block * 4)
            let k = head & (1 << LanguageModel.riceBits - 1)
            var id = head >> LanguageModel.riceBits
            var bit = int(bitOffsetsAt + block * 4)
            for at in 0..<count {
                if at > 0 {
                    let next = gap(bit, k)
                    id += next.gap
                    bit += next.bits
                }
                if id < words { found.append((id, probability(pair + at))) }
            }
        }
        found.sort { $0.logP > $1.logP }
        return Array(found.prefix(limit))
    }

    /// ln P([word] | [previous]).
    public func logP(_ previous: Int, _ word: Int) -> Float {
        if previous < 0 { return unigram(word) }
        let firstBlock = int(blockOffsetsAt + previous * 4)
        var low = firstBlock
        var high = int(blockOffsetsAt + (previous + 1) * 4) - 1
        // The last block that starts at or before [word].
        var block = -1
        while low <= high {
            let mid = (low + high) >> 1
            if int(headsAt + mid * 4) >> LanguageModel.riceBits <= word {
                block = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if block >= 0 {
            let pair = int(pairOffsetsAt + previous * 4) + (block - firstBlock) * blockSize
            let count = min(blockSize, int(pairOffsetsAt + (previous + 1) * 4) - pair)
            let head = int(headsAt + block * 4)
            let k = head & (1 << LanguageModel.riceBits - 1)
            var id = head >> LanguageModel.riceBits
            var bit = int(bitOffsetsAt + block * 4)
            var at = 0
            while true {
                if id == word { return probability(pair + at) }
                at += 1
                if id > word || at >= count { break }
                let next = gap(bit, k)
                id += next.gap
                bit += next.bits
            }
        }
        return Float(short(backoffAt + previous * 2)) / 1000 + unigram(word)
    }
}
