import Foundation

/// Memory-mapped, versioned location table. Loading is constant work; country
/// and city strings are decoded only when a matching IP range is requested.
public struct GlobePlaceTable: Sendable {
    private let bytes: Data
    public let count: Int
    private let payload: Int
    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 16, data.prefix(8) == Data("V2MLOC01".utf8),
              Self.uint(data, 12, 4) == 24 else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(Self.uint(data, 8, 4))
        guard count <= (data.count - 16) / 24 else { throw CocoaError(.fileReadCorruptFile) }
        bytes = data; self.count = count; payload = 16 + count * 24
    }
    public func place(at index: Int) -> GlobePlace? {
        guard index >= 0, index < count else { return nil }
        let record = 16 + index * 24
        let offset = Int(Self.uint(bytes, record, 4))
        let countryLength = Int(Self.uint(bytes, record + 4, 2))
        let cityLength = Int(Self.uint(bytes, record + 6, 2))
        guard offset <= bytes.count - payload,
              countryLength + cityLength <= bytes.count - payload - offset else { return nil }
        let latitude = Double(bitPattern: Self.uint(bytes, record + 8, 8))
        let longitude = Double(bitPattern: Self.uint(bytes, record + 16, 8))
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let start = payload + offset
        guard let country = String(data: bytes[start..<(start + countryLength)], encoding: .utf8),
              let city = String(data: bytes[(start + countryLength)..<(start + countryLength + cityLength)], encoding: .utf8) else { return nil }
        return GlobePlace(country: country, city: city, latitude: latitude, longitude: longitude)
    }
    private static func uint(_ data: Data, _ start: Int, _ width: Int) -> UInt64 {
        data[start..<(start + width)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
