import RealityKit
import Metal

/// The tube's buffers are immutable after construction. Only its visible index
/// range changes during a telemetry transition.
@MainActor enum RealityRingMesh {
    private struct Vertex { var position, normal: SIMD3<Float> }
    static let segments = 360
    private static let sides = 8

    static func make(size: CGSize, fraction: Double) throws -> MeshResource {
        let outer = max(0.001, Float(min(size.width, size.height)) / 2000)
        let tube = min(0.0025, outer / 2), radius = outer - tube
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: segments * sides,
            vertexAttributes: [.init(semantic: .position, format: .float3, offset: 0),
                               .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: segments * sides * 6, indexType: .uint16)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: Vertex.self)
            for i in 0..<segments {
                let theta = Float(i) * 2 * .pi / Float(segments)
                // RealityKit's positive Y points up. Advance clockwise from six o'clock.
                let radial = SIMD3<Float>(-sin(theta), -cos(theta), 0)
                for j in 0..<sides {
                    let phi = Float(j) * 2 * .pi / Float(sides)
                    let normal = radial * cos(phi) + SIMD3<Float>(0, 0, sin(phi))
                    vertices[i*sides+j] = Vertex(position: radial * radius + normal * tube, normal: normal)
                }
            }
        }
        mesh.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt16.self)
            for i in 0..<segments {
                for j in 0..<sides {
                    let next = (i+1) % segments, k = (j+1) % sides
                    let a = i*sides+j, b = next*sides+j, c = next*sides+k, d = i*sides+k
                    for (offset, index) in [a,c,b,a,d,c].enumerated() { indices[a*6+offset] = UInt16(index) }
                }
            }
        }
        mesh.parts.append(.init(indexCount: visibleIndices(fraction), bounds: BoundingBox(
            min: [-outer,-outer,-tube], max: [outer,outer,tube])))
        return try MeshResource(from: mesh)
    }

    static func reveal(_ fraction: Double, on resource: MeshResource?) {
        guard let mesh = resource?.lowLevelMesh, var part = mesh.parts.first else { return }
        let count = visibleIndices(fraction)
        guard part.indexCount != count else { return }
        part.indexCount = count
        mesh.parts[0] = part
    }

    private static func visibleIndices(_ fraction: Double) -> Int {
        let amount = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return Int((amount * Double(segments)).rounded()) * sides * 6
    }
}
