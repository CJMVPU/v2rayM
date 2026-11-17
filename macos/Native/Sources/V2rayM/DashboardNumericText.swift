import AppKit
import SwiftUI
import QuartzCore
import CoreImage

/// Keep SwiftUI's text metrics/accessibility, but animate cached glyph surfaces.
/// Only the changing characters roll and soften; unchanged characters stay still.
struct DashboardNumericText: View {
    let text: String
    let size: CGFloat
    var color: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dashboardMotionEnabled) private var motion
    var body: some View {
        Text(text).font(AppFont.size(size)).monospacedDigit().hidden()
            .overlay {
                NativeNumericText(text: text, size: size, color: color, animate: motion && !reduced)
                    .accessibilityHidden(true)
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
    func makeNSView(context: Context) -> NumericLayerView { NumericLayerView() }
    func updateNSView(_ view: NumericLayerView, context: Context) {
        view.update(text, size: size, color: NSColor(color), animate: animate)
    }
    static func dismantleNSView(_ view: NumericLayerView, coordinator: ()) { view.freeze() }
}

@MainActor final class NumericLayerView: DashboardLayerView {
    private struct Glyph {
        let images: [CGImage]
        let width: CGFloat
        let height: CGFloat
    }
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var cache: [Character: Glyph] = [:]
    private var glyphLayers: [CALayer] = []
    private var outgoing: [CALayer] = []
    private var text = ""
    private var fontSize: CGFloat = 14
    private var tint = NSColor.labelColor
    private var scale: CGFloat = 2
    private var layoutSize = CGSize.zero
    private var recover = false
    private var animationAllowed = false
    private(set) var glyphBuilds = 0
    private(set) var transitionCount = 0
    private let pad: CGFloat = 5
    override init(frame: NSRect = .zero) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
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
        if styleChanged { fontSize = size; tint = resolved; scale = newScale; cache.removeAll() }
        let previous = styleChanged ? "" : text
        text = value
        let rolling = animate && !previous.isEmpty && !styleChanged && !recover
        let crossfade = animate && recover
        recover = false
        replace(previous: previous, rolling: rolling, crossfade: crossfade)
    }
    override func layout() {
        super.layout()
        guard bounds.size != layoutSize else { return }
        layoutSize = bounds.size
        withoutActions { positionLayers() }
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
        let source = CIImage(cgImage: image)
        let images = [image] + [0.65, 1.3, 2.0].map { radius in
            let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
            return Self.imageContext.createCGImage(blurred, from: source.extent) ?? image
        }
        let result = Glyph(images: images, width: width, height: height)
        cache[character] = result; glyphBuilds += 1
        return result
    }
}
