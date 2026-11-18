import RealityKit
import AppKit
import Combine

/// Text metrics and bitmaps come from AppKit. Each character is an instance
/// on the card's front face. Only a changed digit rolls and softens.
@MainActor final class RealityNumberFace {
    struct Glyph {
        let width: CGFloat
        let height: CGFloat
        let mesh: MeshResource
        let frames: [UnlitMaterial]
        @MainActor init(images: [CGImage], width: CGFloat, height: CGFloat, padding: CGFloat) throws {
            self.width = width
            self.height = height
            mesh = .generatePlane(width: Float(width+2*padding)/1000, height: Float(height)/1000)
            frames = try images.map { image in
                let texture = try TextureResource(image: image, options: .init(semantic: .color))
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                material.blending = .transparent(opacity: .init(floatLiteral: 1))
                return material
            }
        }
    }
    private struct Letter {
        let char: Character
        let glyph: Glyph
        let model: ModelEntity
    }
    private struct Transition {
        let letter: Letter
        let incoming: Bool
        let distance: Float
    }
    let root = Entity()
    private var current: [Letter] = []
    private var moving: [Transition] = []
    private var elapsed = 0.0
    private var subscription: (any Cancellable)?

    func reset() {
        settle()
        root.children.removeAll()
        current.removeAll()
    }
    func settle() {
        subscription?.cancel()
        subscription = nil
        for change in moving {
            if change.incoming {
                change.letter.model.position.y = 0
                change.letter.model.components.remove(OpacityComponent.self)
                change.letter.model.model?.materials = [change.letter.glyph.frames[0]]
            } else { change.letter.model.removeFromParent() }
        }
        moving.removeAll()
    }
    func display(_ text: String, size: CGFloat, roll: Bool, fade: Bool, scene: RealityWindowScene,
                 glyphFor: (Character) -> Glyph?) {
        settle()
        let chars = Array(text), old = current
        let shift = chars.count - old.count
        current.removeAll(keepingCapacity: true)
        for (index, char) in chars.enumerated() {
            let prior = index - shift
            if !fade, old.indices.contains(prior), old[prior].char == char {
                current.append(old[prior]); continue
            }
            guard let glyph = glyphFor(char) else { continue }
            let letter = Letter(char: char, glyph: glyph, model: ModelEntity(mesh: glyph.mesh, materials: [glyph.frames[0]]))
            root.addChild(letter.model)
            current.append(letter)
            if roll || fade {
                moving.append(.init(letter: letter, incoming: true, distance: roll && char.isNumber ? Float(size)*0.00055 : 0))
            }
        }
        for letter in old where !current.contains(where: { $0.model === letter.model }) {
            if roll || fade {
                moving.append(.init(letter: letter, incoming: false, distance: roll && letter.char.isNumber ? Float(size)*0.00055 : 0))
            } else { letter.model.removeFromParent() }
        }
        var x = -current.reduce(CGFloat.zero) { $0+$1.glyph.width } / 2
        for letter in current {
            letter.model.position.x = Float(x + letter.glyph.width/2) / 1000
            x += letter.glyph.width
        }
        guard !moving.isEmpty, let stage = scene.stage, !stage.suspended else { settle(); return }
        elapsed = 0
        draw(0)
        subscription = stage.renderer.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed += max(0, event.deltaTime)
                if self.elapsed >= 0.45 { self.settle() }
                else { self.draw(Float(self.elapsed / 0.45)) }
            }
        }
    }
    private func draw(_ t: Float) {
        let eased = t*t*(3-2*t)
        for change in moving {
            let opacity = change.incoming ? eased : 1-eased
            let model = change.letter.model
            model.components.set(OpacityComponent(opacity: opacity))
            model.position.y = change.distance * (change.incoming ? eased-1 : eased)
            let frames = change.letter.glyph.frames
            if change.distance > 0 {
                model.model?.materials = [frames[Int(((1-opacity)*Float(frames.count-1)).rounded())]]
            }
        }
    }
}
