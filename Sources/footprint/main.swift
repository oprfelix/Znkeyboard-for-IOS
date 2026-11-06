import Darwin
import Foundation
import PinyinCore

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

// With a fifth argument, bench.tsv, each letter's tap goes in too, on the bench's keyboard.
let benchWidth: Float = 411, pad: Float = 6, gap: Float = 6
let pitch = (benchWidth - 2 * pad + gap) / 10
var centersX = [Float](repeating: 0, count: 26), centersY = [Float](repeating: 0, count: 26)
for (row, letters) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
    let left = pad + [Float(0), 0.5, 1.5][row] * pitch
    for (i, letter) in letters.utf8.enumerated() {
        centersX[Int(letter) - 97] = left + Float(i) * pitch + (pitch - gap) / 2
        centersY[Int(letter) - 97] = 54 * (Float(row) + 0.5)
    }
}
let keys = KeyGeometry(centersX: centersX, centersY: centersY, pitchX: pitch, pitchY: 54)
let untrained = TouchModel()
let touch = TouchDecoder(touchModel: { untrained }, languageModel: CharLanguageModel())
var tapsByTyped: [String: SentenceDecoder.Taps] = [:]
if CommandLine.arguments.count > 4 {
    for line in try! String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let column = f.last, column.contains(","), column.contains(";") else { continue }
        for typed in f where typed.utf8.count == column.split(separator: ";").count && typed.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) {
            tapsByTyped[typed] = column.split(separator: ";").map { tap in
                let p = tap.split(separator: ",").map { Float($0)! }
                return touch.letterCosts(x: p[0], y: p[1], keys: keys)
            }
        }
    }
}
func tapsOf(_ typed: String) -> SentenceDecoder.Taps? { tapsByTyped[typed] }

// Types every line of the bench file through the engine and compares the first full candidate
// with what the Android engine chose: footprint <dict.bin> <lm.bin> <kotlin cases.tsv>
let args = CommandLine.arguments
print("start MB", footprintMB())
guard let dict = MappedDictionary(path: args[1]), let model = LanguageModel(path: args[2]) else { fatalError("load") }
let lexicon = PinyinLexicon(dictionary: dict, model: model)
print("loaded", lexicon.model != nil, "MB", footprintMB())
let engine = PinyinEngine(lexicon: lexicon)
struct Total { var cases = 0, same = 0, right = 0, kotlinRight = 0 }
var totals: [String: Total] = [:]
var shown = 0
let lines = try! String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").dropFirst()
var latencies: [Double] = []
for line in lines {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    if f.count < 5 { continue }
    let (set, typed, expected, got) = (f[0], f[2], f[3], f[4])
    let started = DispatchTime.now().uptimeNanoseconds
    let found = engine.candidates(typed, taps: tapsOf(typed))
    latencies.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
    let mine = found.first { $0.consumed >= typed.utf8.count }?.text ?? ""
    var t = totals[set] ?? Total()
    t.cases += 1
    if mine == got { t.same += 1 } else if shown < 12 { shown += 1; print("diff", set, typed, "kt:", got, "swift:", mine) }
    if found.first?.text == expected && (found.first?.consumed ?? 0) >= typed.utf8.count { t.right += 1 }
    if got == expected { t.kotlinRight += 1 }
    totals[set] = t
}
for (set, t) in totals.sorted(by: { $0.key < $1.key }) {
    print(set, "cases", t.cases, "same", String(format: "%.1f%%", 100 * Double(t.same) / Double(t.cases)), "swift top1", String(format: "%.1f%%", 100 * Double(t.right) / Double(t.cases)), "kotlin", String(format: "%.1f%%", 100 * Double(t.kotlinRight) / Double(t.cases)))
}
latencies.sort()
print("per input ms: p50", latencies[latencies.count / 2], "p95", latencies[latencies.count * 95 / 100], "max", latencies.last!)
print("end footprint MB", footprintMB())
