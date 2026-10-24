import AppKit
import Foundation

/// User gestures interrupt tail animation before AppKit moves the viewport.
@MainActor private final class LogScrollView: NSScrollView {
    var willScrollManually: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        willScrollManually?()
        super.scrollWheel(with: event)
    }
}

@MainActor public final class NativeLogDocument {
    public let scrollView: NSScrollView
    private struct TailAnimation {
        let started: TimeInterval
        let from: CGFloat
        let target: CGFloat
    }
    private let now: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private let automaticallyTick: Bool
    private var animation: TailAnimation?
    private var animationTimer: Timer?
    private var boundsObserver: NSObjectProtocol?
    private var adjustingViewport = false
    var isAnimatingTail: Bool { animation != nil }

    public convenience init() {
        self.init(now: { ProcessInfo.processInfo.systemUptime },
                  reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
    }
    init(now: @escaping () -> TimeInterval, reduceMotion: @escaping () -> Bool, automaticallyTick: Bool = true) {
        self.now = now; self.reduceMotion = reduceMotion; self.automaticallyTick = automaticallyTick
        let scroll = LogScrollView()
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
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.willScrollManually = { [weak self] in self?.stopFollowingAnimation() }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.adjustingViewport else { return }
                    // Includes keyboard navigation, selection autoscroll and accessibility scrolling.
                    self.stopFollowingAnimation()
                }
            }
    }
    deinit {
        animationTimer?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
    public func stopFollowingAnimation() {
        animationTimer?.invalidate(); animationTimer = nil; animation = nil
    }
    private func moveViewport(y: CGFloat) {
        let clip = scrollView.contentView
        let size = scrollView.documentView?.frame.size ?? .zero
        let wasAdjusting = adjustingViewport
        adjustingViewport = true
        defer { adjustingViewport = wasAdjusting }
        clip.scroll(to: NSPoint(x: min(max(0, clip.bounds.origin.x), max(0, size.width - clip.bounds.width)),
                                y: min(max(0, y), max(0, size.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
    }
    private func followTail(to target: CGFloat) {
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
        let progress = min(1, max(0, (now() - animation.started) / 0.22))
        if reduceMotion() || progress >= 1 {
            stopFollowingAnimation(); moveViewport(y: animation.target)
        } else {
            let eased = 1 - pow(1 - progress, 3)
            moveViewport(y: animation.from + (animation.target - animation.from) * eased)
        }
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
        let initial = ids.isEmpty
        let followsTail = initial || animation != nil || clip.bounds.maxY >= text.bounds.maxY - 1
        stopFollowingAnimation()
        // Layout may constrain the clip bounds while deleting old lines. Those
        // changes are ours, not a user request to stop following the tail.
        let wasAdjusting = adjustingViewport
        adjustingViewport = true
        defer { adjustingViewport = wasAdjusting }
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
        let compensated = NSPoint(x: min(origin.x, max(0, size.width - clip.bounds.width)),
                                  y: min(max(0, origin.y - removedHeight), max(0, size.height - clip.bounds.height)))
        clip.scroll(to: compensated)
        scroll.reflectScrolledClipView(clip)
        if followsTail {
            let bottom = max(0, size.height - clip.bounds.height)
            if initial { moveViewport(y: bottom) }
            else { followTail(to: bottom) }
        }
    }
}
