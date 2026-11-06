import Foundation

/// The dictionary as one read-only memory-mapped file (see tools/build_dict.py), so that it costs
/// the keyboard extension almost no memory of its own. Lookups never allocate per row.
public final class MappedDictionary {
    private let base: UnsafeRawPointer
    private let size: Int
    public let rows: Int
    public let logTotalWeight: Float
    public let words: Int
    private let syllableCount: Int
    private let textOffsets: UnsafePointer<UInt32>
    private let syllableOffsets: UnsafePointer<UInt32>
    private let wordIds: UnsafePointer<Int32>
    private let scores: UnsafePointer<Float32>
    private let rowsByText: UnsafePointer<UInt32>
    private let flags: UnsafePointer<UInt8>
    private let syllableIds: UnsafePointer<UInt16>
    private let initials: UnsafePointer<UInt8>
    private let text: UnsafePointer<UInt8>
    public let syllableNames: [String]

    public init?(path: String) {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 20 else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, file, 0), mapped != MAP_FAILED else { return nil }
        let start = UnsafeRawPointer(mapped)
        guard memcmp(start, "ZNDB", 4) == 0 else { return nil }
        let header = start.assumingMemoryBound(to: UInt32.self)
        let count = Int(header[2])
        var at = 28
        func section<T>(_ type: T.Type, _ items: Int) -> UnsafePointer<T> {
            let pointer = (start + at).assumingMemoryBound(to: T.self)
            at += (items * MemoryLayout<T>.stride + 3) & ~3
            return pointer
        }
        base = start
        size = length
        rows = count
        syllableCount = Int(header[3])
        words = Int(header[4])
        logTotalWeight = (start + 24).load(as: Float32.self)
        textOffsets = section(UInt32.self, count + 1)
        syllableOffsets = section(UInt32.self, count + 1)
        wordIds = section(Int32.self, count)
        scores = section(Float32.self, count)
        rowsByText = section(UInt32.self, count)
        flags = section(UInt8.self, count)
        let syllables = Int(syllableOffsets[count])
        syllableIds = section(UInt16.self, syllables)
        initials = section(UInt8.self, syllables)
        text = section(UInt8.self, Int(textOffsets[count]))
        let names = UnsafeBufferPointer(start: (start + at).assumingMemoryBound(to: UInt8.self), count: length - at)
        syllableNames = String(decoding: names, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    public func text(at row: Int) -> String {
        let start = Int(textOffsets[row])
        let bytes = UnsafeBufferPointer(start: text + start, count: Int(textOffsets[row + 1]) - start)
        return String(decoding: bytes, as: UTF8.self)
    }

    public func score(at row: Int) -> Float { scores[row] }
    public func isTrade(at row: Int) -> Bool { flags[row] & 1 != 0 }
    public func syllableIds(at row: Int) -> UnsafeBufferPointer<UInt16> {
        let start = Int(syllableOffsets[row])
        return UnsafeBufferPointer(start: syllableIds + start, count: Int(syllableOffsets[row + 1]) - start)
    }
    public func wordId(at row: Int) -> Int { Int(wordIds[row]) }

    public func syllables(at row: Int) -> [String] {
        (Int(syllableOffsets[row])..<Int(syllableOffsets[row + 1])).map { syllableNames[Int(syllableIds[$0])] }
    }

    /// Rows whose initials are exactly [key], best first; empty when there are none.
    public func rows(initials key: [UInt8]) -> Range<Int> {
        let first = lowerBound(key, orAfter: false)
        return first..<lowerBound(key, orAfter: true)
    }

    /// Rows whose text starts with [prefix], by text; the text itself comes first.
    public func rows(textPrefix prefix: String) -> [Int] {
        let key = Array(prefix.utf8)
        var low = 0, high = rows
        while low < high {
            let mid = (low + high) / 2
            if compareText(Int(rowsByText[mid]), key) < 0 { low = mid + 1 } else { high = mid }
        }
        var result: [Int] = []
        while low < rows, hasTextPrefix(Int(rowsByText[low]), key) {
            result.append(Int(rowsByText[low]))
            low += 1
        }
        return result
    }

    private func compareText(_ row: Int, _ key: [UInt8]) -> Int {
        let start = Int(textOffsets[row])
        let length = Int(textOffsets[row + 1]) - start
        for i in 0..<min(length, key.count) {
            let a = text[start + i], b = key[i]
            if a != b { return a < b ? -1 : 1 }
        }
        return length < key.count ? -1 : (length == key.count ? 0 : 1)
    }

    private func hasTextPrefix(_ row: Int, _ key: [UInt8]) -> Bool {
        let start = Int(textOffsets[row])
        guard Int(textOffsets[row + 1]) - start >= key.count else { return false }
        for i in 0..<key.count where text[start + i] != key[i] { return false }
        return true
    }

    /// Whether some word's initials start with [key].
    public func hasInitials(prefix key: [UInt8]) -> Bool {
        let row = lowerBound(key, orAfter: false)
        guard row < rows else { return false }
        let start = Int(syllableOffsets[row])
        guard Int(syllableOffsets[row + 1]) - start >= key.count else { return false }
        for i in 0..<key.count where initials[start + i] != key[i] { return false }
        return true
    }

    private func lowerBound(_ key: [UInt8], orAfter after: Bool) -> Int {
        var low = 0, high = rows
        while low < high {
            let mid = (low + high) / 2
            let order = compare(row: mid, key)
            if order < 0 || (after && order == 0) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func compare(row: Int, _ key: [UInt8]) -> Int {
        let start = Int(syllableOffsets[row])
        let length = Int(syllableOffsets[row + 1]) - start
        for i in 0..<min(length, key.count) {
            let a = initials[start + i], b = key[i]
            if a != b { return a < b ? -1 : 1 }
        }
        return length == key.count ? 0 : (length < key.count ? -1 : 1)
    }
}
