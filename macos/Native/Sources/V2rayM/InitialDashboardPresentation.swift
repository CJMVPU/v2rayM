import AppKit

/// WindowServer can display native labels several frames before the first
/// dashboard drawable. Keep the opening window transparent until the two agree.
@MainActor final class InitialDashboardPresentation {
    private weak var window: NSWindow?
    private var alpha: CGFloat = 1
    private var generation = 0
    private var capturing = false
    private var deadline: DispatchWorkItem?
    private var completion: ((NSImage?) -> Void)?

    func attach(to window: NSWindow, timeout: TimeInterval = 1.5, completed: @escaping (NSImage?) -> Void) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        completion = completed
        alpha = window.alphaValue
        window.alphaValue = 0
        // Keep native controls reachable if Metal never returns a frame.
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    typealias Snapshot = (@escaping (NSImage?) -> Void) -> Void

    func render(gauge: CGRect, stageSize: CGSize, snapshot: @escaping Snapshot) {
        guard !capturing, completion != nil else { return }
        capturing = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            self?.capture(generation: generation, gauge: gauge, size: stageSize, snapshot: snapshot)
        }
    }

    private func capture(generation: Int, gauge: CGRect, size: CGSize, snapshot: @escaping Snapshot) {
        guard self.generation == generation, completion != nil else { return }
        snapshot { [weak self] image in
            guard let self, self.generation == generation, self.completion != nil else { return }
            if let image, Self.containsGauge(image, frame: gauge, stageSize: size) {
                self.finish(image)
            } else {
                // Geometry registration can lead the drawable by a frame.
                // Inactive windows may not deliver SceneEvents.Update.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 30) { [weak self] in
                    self?.capture(generation: generation, gauge: gauge, size: size, snapshot: snapshot)
                }
            }
        }
    }

    /// Inspect a small radial strip of the real GPU image. Four always-visible
    /// gauge tracks cross this strip even when there is no traffic or selection.
    static func containsGauge(_ image: NSImage, frame: CGRect, stageSize: CGSize) -> Bool {
        guard stageSize.width > 0, stageSize.height > 0,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let sx = CGFloat(source.width) / stageSize.width, sy = CGFloat(source.height) / stageSize.height
        let strip = CGRect(x: (frame.minX - 2) * sx, y: (frame.midY - 1) * sy,
                          width: min(frame.width / 3, 44) * sx, height: 2 * sy)
        guard let pixels = source.cropping(to: strip.integral) else { return false }
        var samples = [UInt8](repeating: 0, count: 64)
        return samples.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: bytes.count, height: 1,
                bitsPerComponent: 8, bytesPerRow: bytes.count, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: bytes.count, height: 1))
            return Int(bytes.max() ?? 0) - Int(bytes.min() ?? 0) > 8
        }
    }

    private func finish(_ image: NSImage?) {
        let completed = completion
        let target = window, value = alpha
        completion = nil
        deadline?.cancel()
        deadline = nil
        window = nil
        generation += 1
        capturing = false
        completed?(image)
        target?.alphaValue = value
    }

    func detach() {
        completion = nil
        finish(nil)
    }
}
