import AppKit
import Foundation

/// User gestures interrupt tail animation before AppKit moves the viewport.
@MainActor private final class LogScrollView: NSScrollView {
    let wheel = SmoothWheelScroll()
    var willScrollManually: (() -> Void)?
    var willLeaveWindow: (() -> Void)?
    var didEnterWindow: (() -> Void)?
    var visibilityChanged: (() -> Void)?
    private var visibilityObservers: [NSObjectProtocol] = []
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow == nil { willLeaveWindow?() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func scrollWheel(with event: NSEvent) {
        willScrollManually?()
        if !wheel.handle(event, in: self) { super.scrollWheel(with: event) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        visibilityObservers.forEach(center.removeObserver)
        visibilityObservers.removeAll()
        guard let window else { wheel.cancel(); return }
        func observe(_ name: Notification.Name, _ object: AnyObject?) {
            visibilityObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged?() }
            })
        }
        observe(NSWindow.didChangeOcclusionStateNotification, window)
        observe(NSWindow.didMiniaturizeNotification, window)
        observe(NSWindow.didDeminiaturizeNotification, window)
        observe(NSApplication.didResignActiveNotification, NSApp)
        observe(NSApplication.didBecomeActiveNotification, NSApp)
        observe(NSApplication.didHideNotification, NSApp)
        observe(NSApplication.didUnhideNotification, NSApp)
        didEnterWindow?()
    }
    deinit { visibilityObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// This view owns the logical extent only. A TextKit view covering 170,000
/// points can exceed the compositor's backing limits and leave an empty tile.
private final class LogCanvas: NSView {
    private var measuredSize: CGSize = .zero
    override var isFlipped: Bool { true }

    func setDocumentSize(_ size: CGSize) {
        measuredSize = size
        setFrameSize(size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let viewport = enclosingScrollView?.contentView.bounds.size ?? newSize
        super.setFrameSize(CGSize(width: max(viewport.width, measuredSize.width),
                                  height: max(viewport.height, measuredSize.height)))
    }
}

/// TextKit retains the complete selectable string. Moving its text-container
/// origin maps full-document glyph coordinates into a viewport-sized drawable.
private final class LogTextView: NSTextView {
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width - frame.minX, y: textContainerInset.height - frame.minY)
    }
    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        let origin = textContainerOrigin
        let logical = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        return (layoutManager as? LogLayoutManager)?.insertionIndex(at: logical) ?? super.characterIndexForInsertion(at: point)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer else { return }
        if drawsBackground { backgroundColor.setFill(); dirtyRect.fill() }
        let origin = textContainerOrigin
        let logical = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = manager.glyphRange(forBoundingRect: logical, in: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

/// Native TextKit estimates can scroll the clip view while materializing a
/// distant fragment. The document explicitly preserves its visual anchor.
@MainActor private final class LogClipView: NSClipView {
    var preservingOrigin = false
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        if !preservingOrigin { super.setBoundsOrigin(newOrigin) }
    }
    override func scroll(to newOrigin: NSPoint) {
        if !preservingOrigin { super.scroll(to: newOrigin) }
    }
}

/// Unwrapped log lines have a known height. TextKit's estimates for skipped
/// paragraphs would otherwise move distant fragments when the user jumps.
private final class LogLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var lineStarts: [Int] = []
    var lineHeight: CGFloat = 1
    private var prepared: Range<Int>?

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
        backgroundLayoutEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("LogLayoutManager requires programmatic initialization") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in container: NSTextContainer, forGlyphRange range: NSRange) -> Bool {
        let y = CGFloat(lineIndex(forGlyph: range.location)) * lineHeight
        rect.pointee.origin.y = y
        used.pointee.origin.y = y
        return true
    }

    private func lineIndex(forGlyph glyph: Int) -> Int {
        let character = characterIndexForGlyph(at: glyph)
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    override func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange effectiveGlyphRange: NSRangePointer?) -> NSRect {
        // A geometry query about an offscreen selection must not typeset the
        // gap and cause AppKit to scroll the reader back to the insertion point.
        if let prepared, let storage = textStorage, let container = textContainers.first, !lineStarts.isEmpty {
            let index = lineIndex(forGlyph: glyphIndex)
            if !prepared.contains(index) {
                if let effectiveGlyphRange {
                    let start = lineStarts[index]
                    let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : storage.length
                    effectiveGlyphRange.pointee = glyphRange(forCharacterRange: NSRange(location: start, length: end - start),
                                                              actualCharacterRange: nil)
                }
                return NSRect(x: 0, y: CGFloat(index) * lineHeight, width: container.size.width, height: lineHeight)
            }
        }
        return super.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: effectiveGlyphRange)
    }

    // TextKit's spatial index is estimated for unlaid paragraphs. It can
    // return an empty range for a perfectly valid scrolled viewport even
    // after those individual line fragments have been placed on our grid.
    private func indexedGlyphs(in bounds: CGRect) -> NSRange? {
        guard !lineStarts.isEmpty, bounds.minY.isFinite, bounds.maxY.isFinite, let storage = textStorage else { return nil }
        let top = max(0, min(CGFloat(lineStarts.count), floor(bounds.minY / lineHeight)))
        let bottom = max(top, min(CGFloat(lineStarts.count), ceil(bounds.maxY / lineHeight)))
        let first = Int(top), end = Int(bottom)
        guard first < end else { return NSRange(location: 0, length: 0) }
        let start = lineStarts[first]
        let limit = end < lineStarts.count ? lineStarts[end] : storage.length
        guard start <= limit, limit <= storage.length else { return nil }
        return glyphRange(forCharacterRange: NSRange(location: start, length: limit - start), actualCharacterRange: nil)
    }

    override func glyphRange(forBoundingRect bounds: NSRect, in container: NSTextContainer) -> NSRange {
        indexedGlyphs(in: bounds) ?? super.glyphRange(forBoundingRect: bounds, in: container)
    }

    override func glyphRange(forBoundingRectWithoutAdditionalLayout bounds: NSRect, in container: NSTextContainer) -> NSRange {
        indexedGlyphs(in: bounds) ?? super.glyphRange(forBoundingRectWithoutAdditionalLayout: bounds, in: container)
    }

    func insertionIndex(at point: NSPoint) -> Int? {
        guard let storage = textStorage, !lineStarts.isEmpty else { return nil }
        guard point.y >= 0 else { return 0 }
        guard point.y < CGFloat(lineStarts.count) * lineHeight else { return storage.length }
        let first = lineStarts[Int(floor(point.y / lineHeight))]
        guard first < storage.length else { return storage.length }
        // TextKit supplies the grapheme boundaries and display order. Its
        // estimated vertical index for unlaid paragraphs cannot locate this line.
        let count = getLineFragmentInsertionPoints(forCharacterAt: first, alternatePositions: false, inDisplayOrder: true,
                                                   positions: nil, characterIndexes: nil)
        guard count > 0 else { return first }
        var positions = [CGFloat](repeating: 0, count: count)
        var characters = [Int](repeating: 0, count: count)
        getLineFragmentInsertionPoints(forCharacterAt: first, alternatePositions: false, inDisplayOrder: true,
                                       positions: &positions, characterIndexes: &characters)
        let nearest = positions.indices.min { abs(positions[$0] - point.x) < abs(positions[$1] - point.x) }!
        return characters[nearest]
    }

    func resetViewport() { prepared = nil }

    func prepareViewport(_ bounds: CGRect, inset: CGFloat) {
        guard !lineStarts.isEmpty, let storage = textStorage else { return }
        let first = max(0, min(lineStarts.count - 1, Int(floor((bounds.minY - inset) / lineHeight))))
        let end = min(lineStarts.count, max(first + 1, Int(ceil((bounds.maxY - inset) / lineHeight))))
        if let prepared, prepared.lowerBound <= first, prepared.upperBound >= end { return }
        // Keep one screenful on each side for smooth wheel scrolling. Dropping
        // the old fragments prevents TextKit from shifting them when filling a gap.
        let margin = max(2, end - first)
        let lines = max(0, first - margin)..<min(lineStarts.count, end + margin)
        prepared = lines
        let start = lineStarts[lines.lowerBound]
        let limit = lines.upperBound < lineStarts.count ? lineStarts[lines.upperBound] : storage.length
        let range = NSRange(location: start, length: limit - start)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        ensureLayout(forCharacterRange: range)
        // While filling an isolated range AppKit may rebase a whole run of
        // fragments after the typesetter returns, especially with long lines.
        // Place the realized fragments on the same grid used by the clip view.
        for index in lines {
            let glyph = glyphIndexForCharacter(at: lineStarts[index])
            var range = NSRange()
            var rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let y = CGFloat(index) * lineHeight
            guard rect.minY != y else { continue }
            var used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y = y
            used.origin.y = y
            setLineFragmentRect(rect, forGlyphRange: range, usedRect: used)
        }
    }
}

@MainActor public final class NativeLogDocument {
    private let logScrollView: LogScrollView
    public var scrollView: NSScrollView { logScrollView }
    private let canvas = LogCanvas()
    public let textView: NSTextView
    private struct TailAnimation {
        let started: TimeInterval
        let from: CGFloat
        let target: CGFloat
    }
    private let now: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private let automaticallyTick: Bool
    private let canPresent: (NSWindow?) -> Bool
    private var deferredTail = false
    private var animation: TailAnimation?
    private var animationTimer: Timer?
    private var boundsObserver: NSObjectProtocol?
    private var adjustingViewport = false
    private var detachedPosition: (origin: CGPoint, atTail: Bool)?
    var isAnimatingTail: Bool { animation != nil }

    public convenience init() {
        self.init(now: { ProcessInfo.processInfo.systemUptime },
                  reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                  canPresent: { window in
                      guard let window else { return false }
                      return NSApp.isActive && !NSApp.isHidden && window.isVisible && !window.isMiniaturized &&
                          window.occlusionState.contains(.visible)
                  })
    }
    init(now: @escaping () -> TimeInterval, reduceMotion: @escaping () -> Bool, automaticallyTick: Bool = true,
         canPresent: @escaping (NSWindow?) -> Bool = { _ in true }) {
        self.now = now; self.reduceMotion = reduceMotion; self.automaticallyTick = automaticallyTick
        self.canPresent = canPresent
        let scroll = LogScrollView()
        scroll.contentView = LogClipView()
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .allowed
        scroll.backgroundColor = .textBackgroundColor
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        layout.addTextContainer(container)
        let text = LogTextView(frame: .zero, textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        // Size from the unwrapped line index, so appending or trimming the
        // document does not cause NSTextView to typeset the whole history.
        text.isHorizontallyResizable = false; text.isVerticallyResizable = false
        text.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.font = font; text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.setAccessibilityLabel("代理日志")
        textView = text
        canvas.addSubview(text)
        scroll.documentView = canvas
        logScrollView = scroll
        layout.lineHeight = lineHeight
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.visibilityChanged = { [weak self] in self?.reconcileVisibility() }
        scroll.willScrollManually = { [weak self] in self?.stopFollowingAnimation() }
        scroll.willLeaveWindow = { [weak self] in
            guard let self, self.detachedPosition == nil else { return }
            let clip = self.scrollView.contentView
            let atTail = self.deferredTail || self.isAnimatingTail || clip.bounds.maxY >= (self.scrollView.documentView?.bounds.maxY ?? 0) - 1
            self.detachedPosition = (clip.bounds.origin, atTail)
            self.stopFollowingAnimation()
        }
        scroll.didEnterWindow = { [weak self] in
            // SwiftUI installs the existing NSScrollView in a new host, then
            // AppKit restores its insertion point. Restore the reader after layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scrollView.window != nil else { return }
                guard let saved = self.detachedPosition else { self.reconcileVisibility(); return }
                self.scrollView.layoutSubtreeIfNeeded()
                let clip = self.scrollView.contentView
                let bottom = max(0, (self.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                self.layout.resetViewport()
                self.moveViewport(y: saved.atTail ? bottom : saved.origin.y, x: saved.origin.x)
                self.scrollView.documentView?.needsDisplay = true
                self.detachedPosition = nil
            }
        }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.adjustingViewport else { return }
                    // Includes keyboard navigation, selection autoscroll and accessibility scrolling.
                    if self.lastOrigin != scroll.contentView.bounds.origin { self.stopFollowingAnimation() }
                    self.lastOrigin = scroll.contentView.bounds.origin
                    self.prepareViewport()
                }
            }
    }
    deinit {
        animationTimer?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
    public func pauseFollowingAnimation() {
        guard isAnimatingTail else { return }
        stopFollowingAnimation()
        deferredTail = true
    }
    private func reconcileVisibility() {
        guard canPresent(scrollView.window) else { pauseFollowingAnimation(); return }
        if deferredTail, detachedPosition == nil {
            deferredTail = false
            moveViewport(y: max(0, canvas.frame.height - scrollView.contentView.bounds.height))
        }
    }
    public func stopFollowingAnimation() {
        deferredTail = false
        animationTimer?.invalidate(); animationTimer = nil; animation = nil
    }
    private func moveViewport(y: CGFloat, x: CGFloat? = nil) {
        let clip = scrollView.contentView
        let size = scrollView.documentView?.frame.size ?? .zero
        let wasAdjusting = adjustingViewport
        adjustingViewport = true
        defer { adjustingViewport = wasAdjusting }
        clip.scroll(to: NSPoint(x: min(max(0, x ?? clip.bounds.origin.x), max(0, size.width - clip.bounds.width)),
                                y: min(max(0, y), max(0, size.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
        lastOrigin = clip.bounds.origin
        prepareViewport()
    }
    private func followTail(to target: CGFloat) {
        guard canPresent(scrollView.window) else { deferredTail = true; return }
        let origin = scrollView.contentView.bounds.origin.y
        guard !reduceMotion(), target > origin + 0.5 else { moveViewport(y: target); return }
        animation = TailAnimation(started: now(), from: origin, target: target)
        guard automaticallyTick else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceTailAnimation() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// The single tween is retargeted from the displayed position on every append.
    /// A deterministic clock keeps cancellation and coalescing tests independent of wall time.
    func advanceTailAnimation() {
        guard let animation else { return }
        guard canPresent(scrollView.window) else { pauseFollowingAnimation(); return }
        let progress = min(1, max(0, (now() - animation.started) / 0.22))
        if reduceMotion() || progress >= 1 {
            stopFollowingAnimation(); moveViewport(y: animation.target)
        } else {
            let eased = 1 - pow(1 - progress, 3)
            moveViewport(y: animation.from + (animation.target - animation.from) * eased)
        }
    }
    let font = NSFont(name: "LXGWWenKaiMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
    private struct Extent {
        let characters: Int
        let lines: Int
        let width: CGFloat
    }
    private let layout = LogLayoutManager()
    private var lastOrigin = CGPoint.zero
    public struct HistoryPosition: Equatable {
        public let epoch: UUID
        public let headOffset: Int
        public init(epoch: UUID, headOffset: Int) { self.epoch = epoch; self.headOffset = headOffset }
    }
    private var previousPosition: HistoryPosition?
    private var previous: [LogEntry] = []
    private var extents: [Extent] = []
    private lazy var lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 3
    private lazy var paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()
    private lazy var baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
    private var colors = [LogKind: NSColor]()
    private lazy var asciiAdvance: CGFloat? = font.isFixedPitch ? ("0" as NSString).size(withAttributes: baseAttributes).width : nil

    public func update(_ entries: [LogEntry], position: HistoryPosition? = nil) {
        let scroll = scrollView
        let text = textView
        guard let storage = text.textStorage else { return }
        var removed = previous.count
        if let position, let old = previousPosition, position.epoch == old.epoch,
           position.headOffset >= old.headOffset {
            // The bounded FIFO only appends or evicts a prefix. This also
            // covers several deliveries while the reader was on another page.
            removed = min(previous.count, position.headOffset - old.headOffset)
            if removed == 0 && entries.count == previous.count { return }
        } else {
            if previous == entries { previousPosition = position; return }
            if let first = entries.first, let index = previous.firstIndex(of: first) {
                let overlap = previous[index...]
                if entries.prefix(overlap.count).elementsEqual(overlap) { removed = index }
            }
        }
        let shared = previous.count - removed
        previousPosition = position
        let clip = scroll.contentView
        let origin = detachedPosition?.origin ?? clip.bounds.origin
        let initial = previous.isEmpty
        let followsTail = detachedPosition?.atTail ?? (initial || (!logScrollView.wheel.isMoving && (deferredTail || animation != nil || clip.bounds.maxY >= canvas.bounds.maxY - 1)))
        stopFollowingAnimation()
        // Layout may constrain the clip bounds while deleting old lines. Those
        // changes are ours, not a user request to stop following the tail.
        let wasAdjusting = adjustingViewport
        adjustingViewport = true
        defer { adjustingViewport = wasAdjusting }
        let expired = extents.prefix(removed)
        let cut = expired.reduce(0) { $0 + $1.characters }
        let removedLines = expired.reduce(0) { $0 + $1.lines }
        let removedHeight = CGFloat(removedLines) * lineHeight
        extents.removeFirst(removed)
        if removedLines > 0 { layout.lineStarts = layout.lineStarts.dropFirst(removedLines).map { $0 - cut } }
        var character = storage.length - cut
        var appendedText = ""
        var colorRuns: [(kind: LogKind, start: Int)] = []
        let appendStart = character
        for entry in entries.dropFirst(shared) {
            let message = entry.message.utf8.contains(13) ? entry.displayMessage : entry.message
            let kind = LogKind.classify(entry)
            if colorRuns.last?.kind != kind { colorRuns.append((kind, character - appendStart)) }
            let length: Int
            let width: CGFloat
            let oldCount = layout.lineStarts.count
            if let asciiAdvance, message.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) {
                let count = message.utf8.count
                layout.lineStarts.append(character)
                length = count + 1
                width = CGFloat(count) * asciiAdvance
            } else {
                let content = (message + "\n") as NSString
                var offset = 0, widest: CGFloat = 0
                while offset < content.length {
                    layout.lineStarts.append(character + offset)
                    var next = 0, end = 0
                    content.getLineStart(nil, end: &next, contentsEnd: &end, for: NSRange(location: offset, length: 0))
                    let line = content.substring(with: NSRange(location: offset, length: end - offset)) as NSString
                    widest = max(widest, line.size(withAttributes: baseAttributes).width)
                    offset = next
                }
                length = content.length
                width = widest
            }
            character += length
            extents.append(Extent(characters: length, lines: layout.lineStarts.count - oldCount, width: width))
            appendedText.append(message)
            appendedText.append("\n")
        }
        let appended = NSMutableAttributedString(string: appendedText, attributes: baseAttributes)
        for (index, run) in colorRuns.enumerated() {
            let end = index + 1 < colorRuns.count ? colorRuns[index + 1].start : appended.length
            let color = colors[run.kind] ?? run.kind.color
            colors[run.kind] = color
            appended.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.start, length: end - run.start))
        }
        let selection = text.selectedRanges.map(\.rangeValue)
        layout.resetViewport()
        // A single begin/endEditing would report deletion at the head and
        // insertion at the tail as one changed range spanning the whole document.
        if cut > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: cut)) }
        if appended.length > 0 { storage.append(appended) }
        if cut > 0 {
            text.selectedRanges = selection.map { range in
                let start = max(0, range.location - cut), end = max(0, NSMaxRange(range) - cut)
                return NSValue(range: NSRange(location: start, length: end - start))
            }
        }
        previous = entries
        let padding = (text.textContainer?.lineFragmentPadding ?? 0) + text.textContainerInset.width
        canvas.setDocumentSize(NSSize(width: ceil(extents.lazy.map(\.width).max() ?? 0) + padding * 2,
                                    height: CGFloat(layout.lineStarts.count + 1) * lineHeight + text.textContainerInset.height * 2))
        let size = canvas.frame.size
        if removedHeight > 0 { logScrollView.wheel.compensateForRemovedHeight(removedHeight) }
        let compensated = NSPoint(x: min(origin.x, max(0, size.width - clip.bounds.width)),
                                  y: min(max(0, origin.y - removedHeight), max(0, size.height - clip.bounds.height)))
        if detachedPosition != nil { detachedPosition = (compensated, followsTail) }
        clip.scroll(to: compensated)
        scroll.reflectScrolledClipView(clip)
        if followsTail {
            let bottom = max(0, size.height - clip.bounds.height)
            if initial { moveViewport(y: bottom) }
            else { followTail(to: bottom) }
        }
        lastOrigin = clip.bounds.origin
        prepareViewport()
    }

    private func prepareViewport() {
        guard let clip = scrollView.contentView as? LogClipView, !clip.preservingOrigin else { return }
        clip.preservingOrigin = true
        defer { clip.preservingOrigin = false }
        if textView.frame != clip.bounds {
            textView.frame = clip.bounds
            textView.needsDisplay = true
        }
        layout.prepareViewport(clip.bounds, inset: textView.textContainerInset.height)
    }
}
