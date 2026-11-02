import UIKit

/// Display-only clipping by rendered lines, including proportional text and emoji.
enum PartialTranscriptTail {
    static let font = UIFont.systemFont(ofSize: 15)
    static let lineSpacing: CGFloat = 6
    static var panelHeight: CGFloat { font.lineHeight * 2 + lineSpacing + 8 }

    static func latest(_ text: String, width: CGFloat) -> String {
        guard width > 0 else { return "" }
        let text = text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return "" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            starts.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location)
        }
        guard starts.count > 2 else { return text }
        return (text as NSString).substring(from: starts[starts.count - 2])
    }
}
