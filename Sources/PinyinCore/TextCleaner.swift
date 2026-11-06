import Foundation

/// Text from the model: English gets plain ASCII punctuation, and text with other letters keeps
/// its own marks, losing only invisible characters. A port of AsciiTextSanitizer.kt.
enum TextCleaner {
    private static let invisible: Set<UInt32> = [0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF]
    private static let replacements: [UInt32: String] = [
        0x2018: "'",
        0x2019: "'",
        0x201A: "'",
        0x2039: "<",
        0x203A: ">",
        0x00AB: "<<",
        0x00BB: ">>",
        0x2014: "-",
        0x2013: "-",
        0x2012: "-",
        0x2015: "-",
        0x2010: "-",
        0x2011: "-",
        0x00AD: "",
        0x00A0: " ",
        0x2002: " ",
        0x2003: " ",
        0x2009: " ",
        0x200A: " ",
        0x202F: " ",
        0x205F: " ",
        0x200B: "",
        0x200C: "",
        0x200D: "",
        0xFEFF: "",
        0x200E: "",
        0x200F: "",
        0x2060: "",
        0x2061: "",
        0x2062: "",
        0x2063: "",
        0x2064: "",
        0x2026: "...",
        0x2022: "*",
        0x2023: ">",
        0x2043: "-",
        0x00B7: ".",
        0x2027: ".",
        0x2032: "'",
        0x00D7: "x",
        0x2212: "-",
        0x2248: "~=",
        0x2260: "!=",
        0x2264: "<=",
        0x2265: ">=",
        0x2192: "->",
        0x2190: "<-",
        0x00A9: "(c)",
        0x00AE: "(R)",
        0x2122: "(TM)",
        0x3010: "[",
        0x3011: "]",
        0xFF5B: "{",
        0xFF5D: "}",
    ]

    static func clean(_ text: String) -> String {
        let hasOtherLetters = text.unicodeScalars.contains { $0.value >= 0x80 && CharacterSet.letters.contains($0) }
        if hasOtherLetters {
            var out = String.UnicodeScalarView()
            for scalar in text.unicodeScalars where !invisible.contains(scalar.value) { out.append(scalar) }
            return String(out)
        }
        var out = ""
        for scalar in text.unicodeScalars {
            if let replacement = replacements[scalar.value] {
                out += replacement
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
