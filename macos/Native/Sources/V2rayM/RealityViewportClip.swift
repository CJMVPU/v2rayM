import AppKit
import RealityKit

/// AppKit rectangles use a top-left origin. The box is in the entity's local metres.
enum RealityViewportClip {
    static var supported: Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    @MainActor static func apply(_ visible: CGRect, in frame: CGRect, to entity: Entity) {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            let min = SIMD3<Float>(Float(visible.minX-frame.midX)/1000, Float(frame.midY-visible.maxY)/1000, -1)
            let max = SIMD3<Float>(Float(visible.maxX-frame.midX)/1000, Float(frame.midY-visible.minY)/1000, 1)
            var clip = ClippingComponent(bounds: BoundingBox(min: min, max: max))
            clip.shouldClipSelf = true
            clip.shouldClipChildren = true
            entity.components.set(clip)
        }
        #endif
    }

    @MainActor static func clear(_ entity: Entity) {
        #if compiler(>=6.4)
        if #available(macOS 27, *) { entity.components.remove(ClippingComponent.self) }
        #endif
    }
}
