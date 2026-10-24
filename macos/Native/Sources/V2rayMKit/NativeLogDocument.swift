import AppKit
import Foundation

@MainActor public final class NativeLogDocument {
    public let scrollView: NSScrollView
    public init() {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .allowed
        scroll.backgroundColor = .textBackgroundColor
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.font = font; text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.setAccessibilityLabel("代理日志")
        scroll.documentView = text
        scrollView = scroll
    }
    let font = NSFont(name: "LXGWWenKaiMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
    private var ids: [String] = []
    private var lengths: [Int] = []
    public func update(_ entries: [LogEntry]) {
        let scroll = scrollView
        let newIDs = entries.map(\.id)
        guard newIDs != ids, let text = scroll.documentView as? NSTextView,
              let storage = text.textStorage, let layout = text.layoutManager,
              let container = text.textContainer else { return }
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let followsTail = ids.isEmpty || clip.bounds.maxY >= text.bounds.maxY - 24
        var removed = 0, shared = 0
        if let first = newIDs.first, let index = ids.firstIndex(of: first),
           Array(newIDs.prefix(ids.count - index)) == Array(ids.dropFirst(index)) {
            removed = index; shared = ids.count - index
        } else { removed = ids.count }
        let cut = lengths.prefix(removed).reduce(0, +)
        // An entry can contain more than one physical line (for example a
        // stack trace). Preserve the visible surviving line by its layout,
        // rather than subtracting one line height per removed entry.
        layout.ensureLayout(for: container)
        let removedHeight: CGFloat
        if cut > 0 && cut < storage.length {
            let glyph = layout.glyphIndexForCharacter(at: cut)
            removedHeight = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        } else { removedHeight = cut > 0 ? layout.usedRect(for: container).height : 0 }
        let incoming = entries.dropFirst(shared)
        let added = incoming.map { $0.displayMessage + "\n" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left; paragraph.lineBreakMode = .byClipping; paragraph.lineSpacing = 3
        storage.beginEditing()
        if cut > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: cut)) }
        for (entry, line) in zip(incoming, added) {
            storage.append(NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: LogKind.classify(entry).color, .paragraphStyle: paragraph]))
        }
        storage.endEditing()
        lengths = Array(lengths.dropFirst(removed)) + added.map { $0.utf16.count }
        ids = newIDs
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: max(clip.bounds.width, ceil(used.maxX) + 24),
                          height: max(clip.bounds.height, ceil(used.maxY) + 20))
        text.setFrameSize(size)
        let y = followsTail ? max(0, size.height - clip.bounds.height) : max(0, origin.y - removedHeight)
        clip.scroll(to: NSPoint(x: min(origin.x, max(0, size.width - clip.bounds.width)),
                                y: min(y, max(0, size.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }
}
