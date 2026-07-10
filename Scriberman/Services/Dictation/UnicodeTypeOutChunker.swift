import Foundation

/// Splits text into pieces small enough for `CGEventKeyboardSetUnicodeString`,
/// which carries at most 20 UTF-16 code units per keyboard event. Chunks are
/// built scalar-by-scalar so surrogate pairs are never split across events —
/// a lone surrogate is invalid input for the receiving app (design D1).
enum UnicodeTypeOutChunker {
    static let maxUTF16UnitsPerEvent = 20

    static func chunks(for text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnitCount = 0

        for scalar in text.unicodeScalars {
            let scalarUnitCount = UTF16.width(scalar)
            if currentUnitCount + scalarUnitCount > maxUTF16UnitsPerEvent {
                result.append(current)
                current = ""
                currentUnitCount = 0
            }
            current.unicodeScalars.append(scalar)
            currentUnitCount += scalarUnitCount
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
