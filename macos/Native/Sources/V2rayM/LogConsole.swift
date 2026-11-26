import AppKit
import SwiftUI
import V2rayMKit

/// One native text document keeps scroll positions while SwiftUI refreshes.
struct LogConsole: NSViewRepresentable {
    var entries: [LogEntry]
    let position: NativeLogDocument.HistoryPosition?
    let document: NativeLogDocument
    func makeCoordinator() -> NativeLogDocument { document }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.scrollView
        // Redraw newly exposed tiles in the log well's own color during live
        // scrolling, including while the RealityKit surface is being composited.
        scroll.backgroundColor = InterfacePalette.well
        scroll.drawsBackground = true
        document.textView.backgroundColor = InterfacePalette.well
        document.textView.drawsBackground = true
        return scroll
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: NativeLogDocument) { coordinator.pauseFollowingAnimation() }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(entries, position: position) }
}
