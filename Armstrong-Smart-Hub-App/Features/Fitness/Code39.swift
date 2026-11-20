import Foundation

/// Code 39, the barcode on the gym's key tag. Core Image draws Code 128 but not
/// Code 39, so the bars are worked out here and drawn by `BarcodeView`.
///
/// Each character is nine elements (bar, space, bar, … bar), three of them wide,
/// with one narrow space between characters and `*` at both ends.
enum Code39 {
    /// How many narrow widths a wide element is (the spec allows 2 to 3).
    static let wide = 3
    /// Blank space either side, in narrow widths (the spec asks for at least 10).
    static let quietZone = 10

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%")
    /// Nine bits per character, first element first; 1 is wide.
    private static let patterns: [Int] = [
        0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064, // 0-9
        0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C, // A-J
        0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016, // K-T
        0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x0A8, // U-Z - . space $
        0x0A2, 0x08A, 0x02A, // / + %
    ]
    private static let star = 0x094

    /// Whether every character can be drawn (letters are upper-cased first).
    static func canEncode(_ text: String) -> Bool {
        !text.isEmpty && text.uppercased().allSatisfy { alphabet.contains($0) }
    }

    /// The bars and spaces in narrow widths, starting with a bar, without the quiet zones;
    /// nil when a character isn't in Code 39.
    static func runs(_ text: String) -> [Int]? {
        var codes = [star]
        for character in text.uppercased() {
            guard let i = alphabet.firstIndex(of: character) else { return nil }
            codes.append(patterns[i])
        }
        codes.append(star)
        var runs: [Int] = []
        for (n, code) in codes.enumerated() {
            if n > 0 { runs.append(1) } // the gap between characters
            for bit in (0..<9).reversed() {
                runs.append(code >> bit & 1 == 1 ? wide : 1)
            }
        }
        return runs
    }

    /// The whole symbol's width in narrow widths, quiet zones included.
    static func modules(_ runs: [Int]) -> Int { runs.reduce(0, +) + 2 * quietZone }
}
