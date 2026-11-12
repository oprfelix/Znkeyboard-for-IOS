import Accelerate
import Foundation

/// The character model for AI 整句排序 (charlm.bin, from tools/pinyin/charlm/export_zncm.py in
/// the Android repo): a 6-layer GPT-style model whose int8 weights stay memory-mapped, so they
/// cost the keyboard extension no dirty memory. Each matrix is turned into floats in one scratch
/// buffer just before Accelerate multiplies by it; the output projection goes a slice of the
/// vocabulary at a time, with a running log-sum-exp. It gives ln P(text, then a clause
/// boundary | clause boundary) for each text ([scores]), as the Android keyboard's ONNX model does.
public final class CharModel {
    private struct Matrix {
        let weights: Int      // int8 [rows, cols]
        let scales: Int       // f32 [rows]
        let rows: Int
        let cols: Int
    }

    private struct Layer {
        let ln1w: Int, ln1b: Int
        let qkv: Matrix, qkvBias: Int
        let proj: Matrix, projBias: Int
        let ln2w: Int, ln2b: Int
        let ff1: Matrix, ff1Bias: Int
        let ff2: Matrix, ff2Bias: Int
    }

    private static let boundary: Int32 = 1
    private static let unknown: Int32 = 2
    /// Vocabulary rows turned into floats at a time for the output projection.
    private static let vocabSlice = 1024

    private let base: UnsafeRawPointer
    private let size: Int
    public let vocab: Int
    private let dim: Int
    private let heads: Int
    private let ff: Int
    public let context: Int
    private let embed: Matrix
    private let position: Int
    private let layers: [Layer]
    private let lnw: Int, lnb: Int
    /// Floats for the largest matrix (or vocabulary slice): the only buffer kept between calls.
    private var scratch: [Float]
    private var ids: [Character: Int32] = [:]

    /// [path]: charlm.bin; [vocabPath]: one character a line, the id being line + 3.
    public init?(path: String, vocabPath: String) {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 32 else { return nil }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, file, 0), mapped != MAP_FAILED else { return nil }
        let start = UnsafeRawPointer(mapped)
        func header(_ at: Int) -> Int { Int(start.loadUnaligned(fromByteOffset: at, as: Int32.self).littleEndian) }
        guard memcmp(start, "ZNCM", 4) == 0, header(4) == 1 else {
            munmap(mapped, length)
            return nil
        }
        let vocab = header(8), dim = header(12), layerCount = header(16), heads = header(20), ff = header(24), context = header(28)
        var at = 32
        func align() { at = (at + 15) & ~15 }
        func floats(_ count: Int) -> Int { align(); defer { at += count * 4 }; return at }
        func matrix(_ rows: Int, _ cols: Int) -> Matrix {
            align()
            let weights = at
            at += rows * cols
            return Matrix(weights: weights, scales: floats(rows), rows: rows, cols: cols)
        }
        embed = matrix(vocab, dim)
        position = floats(context * dim)
        var layers: [Layer] = []
        for _ in 0..<layerCount {
            let ln1w = floats(dim), ln1b = floats(dim)
            let qkv = matrix(3 * dim, dim), qkvBias = floats(3 * dim)
            let proj = matrix(dim, dim), projBias = floats(dim)
            let ln2w = floats(dim), ln2b = floats(dim)
            let ff1 = matrix(ff, dim), ff1Bias = floats(ff)
            let ff2 = matrix(dim, ff), ff2Bias = floats(dim)
            layers.append(Layer(ln1w: ln1w, ln1b: ln1b, qkv: qkv, qkvBias: qkvBias, proj: proj, projBias: projBias,
                                ln2w: ln2w, ln2b: ln2b, ff1: ff1, ff1Bias: ff1Bias, ff2: ff2, ff2Bias: ff2Bias))
        }
        lnw = floats(dim)
        lnb = floats(dim)
        align()
        guard at <= length, let text = try? String(contentsOfFile: vocabPath, encoding: .utf8) else {
            munmap(mapped, length)
            return nil
        }
        for (line, character) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let first = character.first { ids[first] = Int32(line + 3) }
        }
        base = start
        size = length
        self.vocab = vocab
        self.dim = dim
        self.heads = heads
        self.ff = ff
        self.context = context
        self.layers = layers
        scratch = [Float](repeating: 0, count: max(3 * dim * dim, ff * dim, CharModel.vocabSlice * dim))
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    private func pointer(_ at: Int) -> UnsafePointer<Float> { (base + at).assumingMemoryBound(to: Float.self) }

    /// ln P of each text as a whole clause; characters the model doesn't know count as unknown,
    /// and texts longer than its context are cut.
    public func scores(_ texts: [String]) -> [Float] {
        let sequences = texts.map { text -> [Int32] in
            [CharModel.boundary] + text.prefix(context - 1).map { ids[$0] ?? CharModel.unknown }
        }
        return score(sequences: sequences)
    }

    /// [sequences]: each the boundary, then the characters' ids.
    public func score(sequences: [[Int32]]) -> [Float] {
        let starts = sequences.reduce(into: [0]) { $0.append($0.last! + $1.count) }
        let rows = starts.last!
        if rows == 0 { return [] }
        var x = [Float](repeating: 0, count: rows * dim)
        var h = [Float](repeating: 0, count: rows * dim)
        var qkv = [Float](repeating: 0, count: rows * 3 * dim)
        var attended = [Float](repeating: 0, count: rows * dim)
        var hidden = [Float](repeating: 0, count: rows * ff)

        // Token and position embeddings.
        for (s, sequence) in sequences.enumerated() {
            for (t, id) in sequence.enumerated() {
                let row = starts[s] + t
                let scale = pointer(embed.scales)[Int(id)]
                let q = (base + embed.weights + Int(id) * dim).assumingMemoryBound(to: Int8.self)
                x.withUnsafeMutableBufferPointer { out in
                    let dst = out.baseAddress! + row * dim
                    vDSP_vflt8(q, 1, dst, 1, vDSP_Length(dim))
                    var s = scale
                    vDSP_vsmul(dst, 1, &s, dst, 1, vDSP_Length(dim))
                    vDSP_vadd(dst, 1, pointer(position) + t * dim, 1, dst, 1, vDSP_Length(dim))
                }
            }
        }

        for layer in layers {
            layerNorm(x, into: &h, rows: rows, weight: layer.ln1w, bias: layer.ln1b)
            multiply(h, by: layer.qkv, bias: layer.qkvBias, rows: rows, into: &qkv)
            attend(qkv, starts: starts, into: &attended)
            multiply(attended, by: layer.proj, bias: layer.projBias, rows: rows, into: &h)
            vDSP_vadd(x, 1, h, 1, &x, 1, vDSP_Length(rows * dim))
            layerNorm(x, into: &h, rows: rows, weight: layer.ln2w, bias: layer.ln2b)
            multiply(h, by: layer.ff1, bias: layer.ff1Bias, rows: rows, into: &hidden)
            for i in 0..<hidden.count {
                let v = hidden[i]
                hidden[i] = 0.5 * v * (1 + erff(v * 0.70710678))
            }
            multiply(hidden, by: layer.ff2, bias: layer.ff2Bias, rows: rows, into: &h)
            vDSP_vadd(x, 1, h, 1, &x, 1, vDSP_Length(rows * dim))
        }
        layerNorm(x, into: &h, rows: rows, weight: lnw, bias: lnb)

        // Next-character targets: the following id, then the boundary after the last character.
        var targets = [Int](repeating: Int(CharModel.boundary), count: rows)
        for (s, sequence) in sequences.enumerated() {
            for t in 0..<(sequence.count - 1) { targets[starts[s] + t] = Int(sequence[t + 1]) }
        }
        let logp = logProbabilities(h, rows: rows, targets: targets)
        return sequences.indices.map { s in (starts[s]..<starts[s + 1]).reduce(Float(0)) { $0 + logp[$1] } }
    }

    private func layerNorm(_ x: [Float], into out: inout [Float], rows: Int, weight: Int, bias: Int) {
        let n = vDSP_Length(dim)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for r in 0..<rows {
                    let row = src.baseAddress! + r * dim
                    let o = dst.baseAddress! + r * dim
                    var mean: Float = 0
                    vDSP_meanv(row, 1, &mean, n)
                    var negMean = -mean
                    vDSP_vsadd(row, 1, &negMean, o, 1, n)
                    var meanSquare: Float = 0
                    vDSP_measqv(o, 1, &meanSquare, n)
                    var inv = 1 / sqrtf(meanSquare + 1e-5)
                    vDSP_vsmul(o, 1, &inv, o, 1, n)
                    vDSP_vma(o, 1, pointer(weight), 1, pointer(bias), 1, o, 1, n)
                }
            }
        }
    }

    /// Rows of [matrix] as floats in [scratch], from row [first] for [count] rows.
    private func dequantize(_ matrix: Matrix, first: Int = 0, count: Int? = nil) {
        let rows = count ?? matrix.rows
        let q = (base + matrix.weights + first * matrix.cols).assumingMemoryBound(to: Int8.self)
        let scales = pointer(matrix.scales) + first
        scratch.withUnsafeMutableBufferPointer { out in
            let dst = out.baseAddress!
            vDSP_vflt8(q, 1, dst, 1, vDSP_Length(rows * matrix.cols))
            for r in 0..<rows {
                var s = scales[r]
                vDSP_vsmul(dst + r * matrix.cols, 1, &s, dst + r * matrix.cols, 1, vDSP_Length(matrix.cols))
            }
        }
    }

    /// out [rows, matrix.rows] = input [rows, matrix.cols] × matrixᵀ + bias.
    private func multiply(_ input: [Float], by matrix: Matrix, bias: Int, rows: Int, into out: inout [Float]) {
        dequantize(matrix)
        let biasPointer = pointer(bias)
        scratch.withUnsafeBufferPointer { w in
            input.withUnsafeBufferPointer { a in
                out.withUnsafeMutableBufferPointer { c in
                    for r in 0..<rows { (c.baseAddress! + r * matrix.rows).update(from: biasPointer, count: matrix.rows) }
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(matrix.rows), Int32(matrix.cols),
                                1, a.baseAddress!, Int32(matrix.cols), w.baseAddress!, Int32(matrix.cols),
                                1, c.baseAddress!, Int32(matrix.rows))
                }
            }
        }
    }

    /// Causal self-attention within each sequence, head by head.
    private func attend(_ qkv: [Float], starts: [Int], into out: inout [Float]) {
        let headDim = dim / heads
        let scale = 1 / sqrtf(Float(headDim))
        var weights = [Float](repeating: 0, count: context)
        for s in 0..<(starts.count - 1) {
            let first = starts[s], length = starts[s + 1] - first
            for head in 0..<heads {
                let offset = head * headDim
                for i in 0..<length {
                    let q = (first + i) * 3 * dim + offset
                    var best = -Float.infinity
                    for j in 0...i {
                        let k = (first + j) * 3 * dim + dim + offset
                        var dot: Float = 0
                        for d in 0..<headDim { dot += qkv[q + d] * qkv[k + d] }
                        weights[j] = dot * scale
                        best = max(best, weights[j])
                    }
                    var total: Float = 0
                    for j in 0...i {
                        weights[j] = expf(weights[j] - best)
                        total += weights[j]
                    }
                    let o = (first + i) * dim + offset
                    for d in 0..<headDim { out[o + d] = 0 }
                    for j in 0...i {
                        let v = (first + j) * 3 * dim + 2 * dim + offset
                        let w = weights[j] / total
                        for d in 0..<headDim { out[o + d] += w * qkv[v + d] }
                    }
                }
            }
        }
    }

    /// ln P(target) for each row, the output projection (the embedding, tied) a slice at a time.
    private func logProbabilities(_ h: [Float], rows: Int, targets: [Int]) -> [Float] {
        var maxima = [Float](repeating: -.infinity, count: rows)
        var sums = [Float](repeating: 0, count: rows)
        var picked = [Float](repeating: 0, count: rows)
        let slice = CharModel.vocabSlice
        var logits = [Float](repeating: 0, count: rows * slice)
        var first = 0
        while first < vocab {
            let count = min(slice, vocab - first)
            dequantize(embed, first: first, count: count)
            scratch.withUnsafeBufferPointer { w in
                h.withUnsafeBufferPointer { a in
                    logits.withUnsafeMutableBufferPointer { c in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(count), Int32(dim),
                                    1, a.baseAddress!, Int32(dim), w.baseAddress!, Int32(dim), 0, c.baseAddress!, Int32(count))
                    }
                }
            }
            logits.withUnsafeMutableBufferPointer { c in
                for r in 0..<rows {
                    let row = c.baseAddress! + r * count
                    var sliceMax: Float = 0
                    vDSP_maxv(row, 1, &sliceMax, vDSP_Length(count))
                    let newMax = max(maxima[r], sliceMax)
                    if (first..<(first + count)).contains(targets[r]) { picked[r] = row[targets[r] - first] }
                    var shift = -newMax
                    vDSP_vsadd(row, 1, &shift, row, 1, vDSP_Length(count))
                    var n = Int32(count)
                    vvexpf(row, row, &n)
                    var sliceSum: Float = 0
                    vDSP_sve(row, 1, &sliceSum, vDSP_Length(count))
                    sums[r] = sums[r] * expf(maxima[r] - newMax) + sliceSum
                    maxima[r] = newMax
                }
            }
            first += count
        }
        return (0..<rows).map { picked[$0] - maxima[$0] - logf(sums[$0]) }
    }
}

extension CharModel: SentenceScorer {
    public func score(_ texts: [String]) -> [Float]? {
        texts.isEmpty ? nil : scores(texts)
    }
}
