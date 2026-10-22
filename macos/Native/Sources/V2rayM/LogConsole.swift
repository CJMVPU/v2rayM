import AppKit
import SwiftUI
import V2rayMKit

/// One native text document keeps scroll positions while SwiftUI refreshes.
struct LogConsole: NSViewRepresentable {
    var entries: [LogEntry]
    func makeCoordinator() -> NativeLogDocument { NativeLogDocument() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(entries) }
}
