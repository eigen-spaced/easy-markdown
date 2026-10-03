import AppKit

/// Lightweight regex-based markdown colouring for the editor. It only touches attributes,
/// so undo and the text itself are unaffected.
final class MarkdownHighlighter {
    var colors: ThemeColors?
    var fontSize: CGFloat = 13

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fence = regex(#"^ {0,3}(```|~~~)[^\n]*\n[\s\S]*?(?:^ {0,3}\1[ \t]*$|\z)"#)
    private static let mathBlock = regex(#"^\$\$[\s\S]*?^\$\$[ \t]*$"#)
    private static let frontMatter = regex(#"\A---\n[\s\S]*?\n(?:---|\.\.\.)[ \t]*$"#)
    private static let heading = regex(#"^ {0,3}(#{1,6})[ \t]+.*$"#)
    private static let setextUnderline = regex(#"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let quote = regex(#"^ {0,3}>.*$"#)
    private static let listMarker = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let rule = regex(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let inlineCode = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let inlineMath = regex(#"(?<![\\$])\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\d)"#)
    private static let link = regex(#"(!?\[)([^\]\n]*)(\]\()([^)\n]*)(\))"#)
    private static let autolink = regex(#"<https?://[^>\s]+>|https?://[^\s)>\]]+"#)
    private static let htmlTag = regex(#"</?[a-zA-Z][^>\n]*>"#)

    func highlight(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let fg = colors?.foreground ?? .textColor
        let muted = colors?.muted ?? .secondaryLabelColor
        let link = colors?.link ?? .linkColor
        let heading = colors?.heading ?? .labelColor
        let code = colors?.code ?? .systemPink
        let accent = colors?.accent ?? .systemPurple

        let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let italicFont = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)

        storage.beginEditing()
        storage.setAttributes([.font: regular, .foregroundColor: fg, .paragraphStyle: Self.paragraphStyle], range: full)

        // Block-level regions whose contents shouldn't get inline styling.
        var protected: [NSRange] = []
        func each(_ re: NSRegularExpression, in range: NSRange = full, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: storage.string, range: range) { m, _, _ in
                guard let m, !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
                body(m)
            }
        }
        func color(_ range: NSRange, _ c: NSColor) {
            if range.location != NSNotFound { storage.addAttribute(.foregroundColor, value: c, range: range) }
        }

        each(Self.frontMatter) { color($0.range, muted); protected.append($0.range) }
        // Fenced code gets a soft tint rather than the full inline-code colour.
        let fencedCode = fg.blended(withFraction: 0.3, of: code) ?? code
        each(Self.fence) { m in
            color(m.range, fencedCode)
            let firstLine = text.lineRange(for: NSRange(location: m.range.location, length: 0))
            color(NSIntersectionRange(firstLine, m.range), muted)
            protected.append(m.range)
        }
        each(Self.mathBlock) { color($0.range, accent); protected.append($0.range) }

        each(Self.heading) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            color(m.range, heading)
            color(m.range(at: 1), muted)
        }
        each(Self.setextUnderline) { color($0.range, muted) }
        each(Self.rule) { color($0.range, muted) }
        each(Self.quote) { m in
            color(m.range, muted)
            storage.addAttribute(.font, value: italicFont, range: m.range)
        }
        each(Self.listMarker) { color($0.range, accent) }
        each(Self.htmlTag) { color($0.range, muted) }

        each(Self.bold) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            color(NSRange(location: m.range.location, length: m.range(at: 1).length), muted)
            color(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length), muted)
        }
        each(Self.italic) { m in
            storage.addAttribute(.font, value: italicFont, range: m.range)
        }
        each(Self.strike) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            color(m.range, muted)
        }
        each(Self.link) { m in
            color(m.range(at: 1), muted)
            color(m.range(at: 2), link)
            color(m.range(at: 3), muted)
            color(m.range(at: 4), muted)
            color(m.range(at: 5), muted)
        }
        each(Self.autolink) { color($0.range, link) }
        each(Self.inlineMath) { color($0.range, accent) }
        each(Self.inlineCode) { m in
            storage.addAttribute(.font, value: regular, range: m.range)
            color(m.range, code)
        }
        storage.endEditing()
    }

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.18
        return style
    }()
}
