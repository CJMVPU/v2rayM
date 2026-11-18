import AppKit
import SwiftUI
import RealityKit
import QuartzCore
import Accelerate

/// Keep SwiftUI's text metrics/accessibility, but animate cached glyph surfaces.
/// Only the changing characters roll and soften; unchanged characters stay still.
struct DashboardNumericText: View {
    let text: String
    let size: CGFloat
    var color: Color = DashboardTheme.text
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dashboardMotionEnabled) private var motion
    @Environment(\.realityParentSurface) private var parent
    var body: some View {
        Text(text).font(AppFont.size(size)).monospacedDigit().hidden()
            .overlay {
                GeometryReader { geometry in
                    let local = parent.map { geometry.frame(in: .named($0)) }
                    NativeNumericText(text: text, size: size, color: color, animate: motion && !reduced,
                        parent: parent, local: local)
                }.accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text).accessibilityHidden(false)
    }
}

private struct NativeNumericText: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let color: Color
    let animate: Bool
    let parent: UUID?
    let local: CGRect?
    @Environment(\.realityScene) private var scene
    func makeNSView(context: Context) -> NumericLayerView { NumericLayerView() }
    func updateNSView(_ view: NumericLayerView, context: Context) {
        view.configure(scene, parent: parent, local: local)
        view.update(text, size: size, color: NSColor(color), animate: animate)
    }
    static func dismantleNSView(_ view: NumericLayerView, coordinator: ()) { view.stop() }
}

@MainActor final class NumericLayerView: DashboardLayerView {
    private struct Glyph {
        let images: [CGImage]
        let width: CGFloat
        let height: CGFloat
    }
    private var cache: [Character: Glyph] = [:]
    private var glyphLayers: [CALayer] = []
    private var outgoing: [CALayer] = []
    private var text = ""
    private var fontSize: CGFloat = 14
    private var tint = NSColor(DashboardTheme.text)
    private var scale: CGFloat = 2
    private var layoutSize = CGSize.zero
    private var recover = false
    private var animationAllowed = false
    private(set) var glyphBuilds = 0
    private(set) var transitionCount = 0
    private let pad: CGFloat = 5
    override init(frame: NSRect = .zero) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    private let face = RealityNumberFace()
    private let anchor = RealitySurfaceAnchor()
    private weak var scene: RealityWindowScene?
    private var textures: [Character: RealityNumberFace.Glyph] = [:]

    func configure(_ owner: RealityWindowScene?, parent: UUID?, local: CGRect?) {
        guard let owner, let parent, let local else {
            if scene != nil { anchor.detach(); anchor.removeFromSuperview(); face.reset(); recover = true }
            scene = nil
            return
        }
        if scene !== owner {
            scene = owner; recover = true
            glyphLayers.forEach { $0.removeFromSuperlayer() }
            outgoing.forEach { $0.removeFromSuperlayer() }
            glyphLayers.removeAll(); outgoing.removeAll()
        }
        if anchor.superview == nil { addSubview(anchor) }
        anchor.frame = bounds
        anchor.drawing = face.root
        anchor.configure(scene: owner, style: .init(shape: .group, depth: 0.3, parentID: parent,
            facePoint: CGPoint(x: local.midX, y: local.midY)))
    }
    func stop() { freeze(); anchor.detach(); face.reset() }
    private func texturedGlyph(_ character: Character) -> RealityNumberFace.Glyph? {
        if let cached = textures[character] { return cached }
        guard let scene else { return nil }
        let key = RealityWindowScene.GlyphKey(character: character, size: fontSize, scale: scale, tint: tint)
        guard let result = try? scene.numericGlyphs.value(for: key, make: {
            guard let source = glyph(character) else { throw CocoaError(.coderInvalidValue) }
            return try RealityNumberFace.Glyph(images: source.images, width: source.width,
                                               height: source.height, padding: pad)
        }) else { return nil }
        textures[character] = result
        return result
    }
    func update(_ value: String, size: CGFloat, color: NSColor, animate: Bool) {
        guard !frozen else { return }
        let motionStopped = animationAllowed && !animate
        animationAllowed = animate
        var resolved = color
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        let newScale = window?.backingScaleFactor ?? 2
        let styleChanged = size != fontSize || resolved != tint || scale != newScale
        guard value != text || styleChanged || recover || motionStopped else { return }
        if styleChanged { fontSize = size; tint = resolved; scale = newScale; cache.removeAll(); textures.removeAll(); face.reset() }
        let previous = styleChanged ? "" : text
        text = value
        let rolling = animate && !previous.isEmpty && !styleChanged && !recover
        let crossfade = animate && recover && !previous.isEmpty
        recover = false
        if let scene {
            face.display(text, size: size, roll: rolling, fade: crossfade, scene: scene, glyphFor: texturedGlyph)
            if rolling || crossfade { transitionCount += 1 }
        } else { replace(previous: previous, rolling: rolling, crossfade: crossfade) }
    }
    override func layout() {
        super.layout()
        guard bounds.size != layoutSize else { return }
        layoutSize = bounds.size
        if scene != nil { anchor.frame = bounds; anchor.synchronize() }
        else { withoutActions { positionLayers() } }
    }
    private func positionLayers() {
        let characters = Array(text)
        let widths = characters.map { glyph($0)?.width ?? 0 }
        var x = bounds.midX - widths.reduce(0, +) / 2
        for (index, item) in glyphLayers.enumerated() where index < widths.count {
            let g = glyph(characters[index])
            item.bounds = CGRect(x: 0, y: 0, width: widths[index] + pad * 2, height: g?.height ?? bounds.height)
            item.position = CGPoint(x: x + widths[index] / 2, y: bounds.midY)
            x += widths[index]
        }
    }
    private func replace(previous: String, rolling: Bool, crossfade: Bool) {
        let oldCharacters = Array(previous), characters = Array(text)
        let oldLayers = glyphLayers
        let shift = characters.count - oldCharacters.count
        outgoing.forEach { $0.removeFromSuperlayer() }; outgoing.removeAll()
        glyphLayers.removeAll(keepingCapacity: true)
        withoutActions {
            for (index, character) in characters.enumerated() {
                let oldIndex = index - shift
                let same = !crossfade && oldCharacters.indices.contains(oldIndex) && oldCharacters[oldIndex] == character
                let item: CALayer
                if same, oldLayers.indices.contains(oldIndex) {
                    item = oldLayers[oldIndex]; item.removeAllAnimations()
                    item.opacity = 1; item.transform = CATransform3DIdentity
                    item.contents = glyph(character)?.images.first
                } else {
                    item = CALayer(); item.contentsScale = scale
                    item.contents = glyph(character)?.images.first
                    layer?.addSublayer(item)
                }
                glyphLayers.append(item)
                if (!same && rolling) || crossfade {
                    transition(item, character: character, incoming: true, roll: rolling)
                }
            }
            positionLayers()
            for (index, item) in oldLayers.enumerated() where !glyphLayers.contains(where: { $0 === item }) {
                if (rolling || crossfade), oldCharacters.indices.contains(index) {
                    outgoing.append(item)
                    transition(item, character: oldCharacters[index], incoming: false, roll: rolling)
                } else { item.removeFromSuperlayer() }
            }
        }
        if rolling || crossfade { transitionCount += 1 }
    }
    private func transition(_ item: CALayer, character: Character, incoming: Bool, roll: Bool) {
        let duration = 0.45
        let alpha = CABasicAnimation(keyPath: "opacity")
        alpha.fromValue = incoming ? 0 : item.opacity; alpha.toValue = incoming ? 1 : 0
        item.opacity = incoming ? 1 : 0
        var animations: [CAAnimation] = [alpha]
        if roll, character.isNumber {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            // Match the previous numericText(countsDown: false) direction.
            slide.fromValue = incoming ? fontSize * 0.55 : 0
            slide.toValue = incoming ? 0 : -fontSize * 0.55
            animations.append(slide)
            if let images = glyph(character)?.images {
                let soften = CAKeyframeAnimation(keyPath: "contents")
                soften.values = incoming ? Array(images.reversed()) : images
                soften.keyTimes = [0, 0.3, 0.65, 1]
                soften.calculationMode = .linear
                animations.append(soften)
            }
        }
        let group = CAAnimationGroup(); group.animations = animations
        group.duration = duration; group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        item.add(group, forKey: "number")
    }
    override func freeze() {
        guard !frozen else { return }
        face.settle()
        withoutActions {
            for item in glyphLayers + outgoing {
                if let shown = item.presentation() {
                    item.opacity = shown.opacity; item.transform = shown.transform; item.contents = shown.contents
                }
                item.removeAllAnimations()
            }
        }
        recover = true
        super.freeze()
    }
    private func glyph(_ character: Character) -> Glyph? {
        if let existing = cache[character] { return existing }
        let font = NSFont(name: AppFont.postScriptName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let string = String(character) as NSString
        let width = string.size(withAttributes: attrs).width
        let height = ceil(font.ascender - font.descender + font.leading) + pad * 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil((width + pad * 2) * scale)),
            pixelsHigh: Int(ceil(height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        string.draw(at: CGPoint(x: pad, y: pad), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        let images = [image] + [0.65, 1.3, 2.0].map { radius in
            Self.gaussianBlur(bitmap, radius: radius * scale) ?? image
        }
        let result = Glyph(images: images, width: width, height: height)
        cache[character] = result; glyphBuilds += 1
        return result
    }
    /// Tiny glyph buffers do not need a Metal render/texture readback. A
    /// separable Gaussian preserves the softening while keeping a cache miss
    /// bounded to two short vectorized passes over the existing bitmap.
    static func gaussianBlur(_ bitmap: NSBitmapImageRep, radius: Double) -> CGImage? {
        guard let pixels = bitmap.bitmapData, let original = bitmap.cgImage else { return nil }
        let extent = max(1, Int(ceil(radius * 3)))
        var kernel = (-extent...extent).map { Float(exp(-Double($0 * $0) / (2 * radius * radius))) }
        let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
        var source = vImage_Buffer(data: pixels, height: vImagePixelCount(bitmap.pixelsHigh),
                                   width: vImagePixelCount(bitmap.pixelsWide), rowBytes: bitmap.bytesPerRow)
        var bytes = [UInt8](repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let error = bytes.withUnsafeMutableBytes { storage -> vImage_Error in
            var destination = vImage_Buffer(data: storage.baseAddress!, height: source.height,
                                            width: source.width, rowBytes: source.rowBytes)
            return kernel.withUnsafeBufferPointer { weights in
                [UInt8](repeating: 0, count: 4).withUnsafeBufferPointer { background in
                    vImageSepConvolve_ARGB8888(&source, &destination, nil, 0, 0,
                        weights.baseAddress!, UInt32(kernel.count), weights.baseAddress!, UInt32(kernel.count),
                        0, background.baseAddress!, vImage_Flags(kvImageBackgroundColorFill | kvImageDoNotTile))
                }
            }
        }
        guard error == kvImageNoError, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: bitmap.bytesPerRow, space: original.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: original.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

}
