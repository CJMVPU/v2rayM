import AppKit
import RealityKit
import SwiftUI

/// Names are stable between the asset authoring tool and the presentation layer.
enum ControlAsset: String, CaseIterable {
    case shield, shieldActive, shieldCheck, sync, link, transfer, upload, download
    case sliders, branch, network, globe, package, folder, current, circle
    case back, down, close, minimize, notice, warning, desktop, topology
    case switchTrack, switchThumb, progressFill

    #if SWIFT_PACKAGE
    @MainActor private static var library: Entity?
    @MainActor func mesh() throws -> MeshResource {
        if Self.library == nil {
            guard let url = Bundle.module.url(forResource: "controls", withExtension: "reality", subdirectory: "Controls") else { throw CocoaError(.fileNoSuchFile) }
            Self.library = try Entity.load(contentsOf: url)
        }
        guard let model = Self.library?.findEntity(named: rawValue) as? ModelEntity,
              let mesh = model.model?.mesh else { throw CocoaError(.coderInvalidValue) }
        return mesh
    }
    #endif

    #if !SWIFT_PACKAGE
    /// Original outlines on a 24-unit grid. Extrusion closes the front, sides,
    /// holes and back into a single reusable mesh for each symbol.
    @MainActor func build() throws -> ModelEntity {
        var path = Path()
        func add(_ filled: Path) { path = path.union(filled) }
        func line(_ points: [CGPoint], close: Bool = false, width: CGFloat = 2) {
            var stroke = Path()
            stroke.addLines(points)
            if close { stroke.closeSubpath() }
            add(stroke.strokedPath(.init(lineWidth: width, lineCap: .round, lineJoin: .round)))
        }
        func polygon(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
            line(points.map { CGPoint(x: $0.0, y: $0.1) }, close: closed)
        }
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, filled: Bool = false) {
            let oval = Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
            add(filled ? oval : oval.strokedPath(.init(lineWidth: 1.9)))
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, filled: Bool = false) {
            let shape = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius)
            add(filled ? shape : shape.strokedPath(.init(lineWidth: 2)))
        }
        switch self {
        case .shield, .shieldActive, .shieldCheck:
            polygon([(12,2),(20,5),(20,12),(18,17),(12,22),(6,17),(4,12),(4,5)], closed: true)
            if self == .shieldActive {
                var half = Path(); half.addLines([.init(x:12,y:2),.init(x:12,y:22),.init(x:6,y:17),.init(x:4,y:12),.init(x:4,y:5)])
                half.closeSubpath(); add(half)
            }
            if self == .shieldCheck { polygon([(8,12),(11,15),(16,9)]) }
        case .sync:
            for offset in [0.0, Double.pi] {
                line((0...20).map { i in
                    let angle = offset + 0.25 + Double(i) * 0.126
                    return CGPoint(x: 12+8*cos(angle), y: 12+8*sin(angle))
                })
            }
            polygon([(2,13),(4,17),(8,15)]); polygon([(16,9),(20,7),(22,11)])
        case .link:
            rect(2,6,13,8,radius: 4); rect(9,10,13,8,radius: 4)
        case .transfer:
            polygon([(20,7),(4,7),(9,2)]); polygon([(4,17),(20,17),(15,22)])
        case .upload:
            polygon([(4,20),(19,5),(9,5)]); polygon([(19,5),(19,15)])
        case .download:
            polygon([(20,4),(5,19),(15,19)]); polygon([(5,19),(5,9)])
        case .sliders:
            for (y,x) in [(5,15),(12,7),(19,14)] {
                polygon([(3,CGFloat(y)),(21,CGFloat(y))]); ellipse(CGFloat(x-2),CGFloat(y-2),4,4,filled:true)
            }
        case .branch:
            polygon([(12,21),(12,12),(4,4)]); polygon([(12,12),(20,4)])
            for x in [4,20] { ellipse(CGFloat(x-2),2,4,4,filled:true) }
        case .network, .globe:
            ellipse(2,2,20,20); ellipse(7,2,10,20); polygon([(3,12),(21,12)])
        case .package:
            polygon([(12,2),(21,7),(21,17),(12,22),(3,17),(3,7)],closed:true)
            polygon([(3,7),(12,12),(21,7)]); polygon([(12,12),(12,22)])
        case .folder: polygon([(2,6),(9,6),(11,9),(22,9),(22,20),(2,20)],closed:true)
        case .current: ellipse(2,2,20,20); polygon([(7,12),(10,15),(17,8)])
        case .circle: ellipse(2,2,20,20)
        case .back: polygon([(15,4),(7,12),(15,20)])
        case .down: polygon([(4,8),(12,16),(20,8)])
        case .close: polygon([(5,5),(19,19)]); polygon([(19,5),(5,19)])
        case .minimize: polygon([(4,12),(20,12)])
        case .notice, .warning:
            ellipse(2,2,20,20)
            if self == .warning { polygon([(12,6),(12,13)]); ellipse(11,16,2,2,filled:true) }
            else { ellipse(11,6,2,2,filled:true); polygon([(12,11),(12,17)]) }
        case .desktop:
            rect(2,3,20,14,radius: 2); polygon([(12,17),(12,21)]); polygon([(7,21),(17,21)])
        case .topology:
            polygon([(5,5),(12,19),(19,5)],closed:true)
            for (x,y) in [(5,5),(12,19),(19,5)] { ellipse(CGFloat(x-2),CGFloat(y-2),4,4,filled:true) }
        case .switchTrack: rect(0,0,30,18,radius: 9,filled:true)
        case .switchThumb: ellipse(0,0,14,14,filled:true)
        case .progressFill: rect(0,0,24,4,radius: 2,filled:true)
        }
        var options = MeshResource.ShapeExtrusionOptions()
        options.extrusionMethod = .linear(depth: self == .switchTrack ? 3 : 1.8)
        options.chamferRadius = 0.20
        options.chamferMode = .both
        let bounds = path.boundingRect
        let centered = path.offsetBy(dx: -bounds.midX, dy: -bounds.midY)
        let model = try ModelEntity(mesh: MeshResource(extruding: centered.applying(CGAffineTransform(scaleX: 1, y: -1)), extrusionOptions: options),
            materials: [SimpleMaterial(color: .white, roughness: 0.78, isMetallic: false)])
        model.name = rawValue
        return model
    }
    #endif
}
