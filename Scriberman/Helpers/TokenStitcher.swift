import Foundation

struct TokenStitcher {
    func normalizeTokenPiece(_ token: String) -> String {
        token.replacingOccurrences(of: "▁", with: " ")
    }

    func stitchTokens(_ tokens: [String]) -> String {
        var text = tokens.joined()
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<=\\p{L})\\s+'\\s*(?=\\p{L})", with: "'", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
