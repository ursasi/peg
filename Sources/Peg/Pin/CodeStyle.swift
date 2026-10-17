import AppKit

/// The look of a pinned piece of text: a dark code window, the way a code
/// screenshot tool presents a snippet. Colours follow the usual "one dark"
/// family so pasted code and pasted terminal output both read well.
enum CodeStyle {
    static let background = NSColor(calibratedRed: 0.114, green: 0.118, blue: 0.129, alpha: 1)
    static let border = NSColor.white.withAlphaComponent(0.08)
    static let plain = NSColor(calibratedRed: 0.84, green: 0.86, blue: 0.88, alpha: 1)
    static let gutter = NSColor(calibratedWhite: 1, alpha: 0.22)
    static let keyword = NSColor(calibratedRed: 0.78, green: 0.53, blue: 0.86, alpha: 1)
    static let type = NSColor(calibratedRed: 0.34, green: 0.80, blue: 0.71, alpha: 1)
    static let string = NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.48, alpha: 1)
    static let number = NSColor(calibratedRed: 0.83, green: 0.86, blue: 0.60, alpha: 1)
    static let comment = NSColor(calibratedWhite: 1, alpha: 0.32)

    static let trafficLights = [
        NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)
    ]

    static func font(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func lineHeight(size: CGFloat) -> CGFloat {
        let font = font(size: size)
        return (font.ascender - font.descender + font.leading).rounded() + 3
    }

    private static let keywords: Set<String> = [
        "if", "else", "for", "while", "return", "func", "function", "class", "struct", "enum",
        "import", "from", "let", "var", "const", "public", "private", "protected", "static",
        "void", "int", "bool", "float", "double", "char", "self", "this", "new", "def",
        "async", "await", "try", "catch", "throw", "switch", "case", "default", "break",
        "continue", "guard", "defer", "nil", "null", "true", "false", "in", "init", "override",
        "protocol", "extension", "typedef", "namespace", "template", "typename", "explicit",
        "operator", "virtual", "inline", "sizeof", "using", "package", "end", "then", "do"
    ]

    /// Applies colour on top of a plain attributed string. The rules are
    /// deliberately simple: comments, strings, numbers, then keywords and
    /// types — enough to make code look like code without pretending to parse it.
    static func highlight(_ code: String, size: CGFloat) -> NSAttributedString {
        let font = font(size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight(size: size)
        paragraph.maximumLineHeight = lineHeight(size: size)
        paragraph.lineBreakMode = .byWordWrapping

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: plain,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString(string: code, attributes: base)
        let ns = code as NSString

        func paint(_ pattern: String, _ colour: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                result.addAttribute(.foregroundColor, value: colour, range: match.range)
            }
        }

        // Strings first, comments second: a `//` inside a string stays a
        // string, which is the case that looks obviously wrong when missed.
        paint(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, string)
        paint(#"//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/"#, comment)
        paint(#"\b\d+(\.\d+)?\b"#, number)
        paint(#"\b[A-Z][A-Za-z0-9_]*\b"#, type)
        for keyword in keywords {
            paint("\\b\(keyword)\\b", keywordColour)
        }
        return result
    }

    private static var keywordColour: NSColor { Self.keyword }
}
