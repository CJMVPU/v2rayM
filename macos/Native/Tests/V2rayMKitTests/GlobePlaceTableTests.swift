import XCTest
@testable import V2rayMKit

func encodePlaces(_ places: [GlobePlace]) -> Data {
    func encoded(_ value: UInt64, _ width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    var records = Data(), payload = Data()
    for place in places {
        let country = Data(place.country.utf8), city = Data(place.city.utf8)
        records += encoded(UInt64(payload.count), 4) + encoded(UInt64(country.count), 2) + encoded(UInt64(city.count), 2)
        records += encoded(place.latitude.bitPattern, 8) + encoded(place.longitude.bitPattern, 8)
        payload += country + city
    }
    return Data("V2MLOC01".utf8) + encoded(UInt64(places.count), 4) + encoded(24, 4) + records + payload
}
final class GlobePlaceTableTests: XCTestCase {
    func testLazyUnicodeAndExactCoordinateRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let places = [GlobePlace(country: "CN", city: "上海", latitude: 31.230416789, longitude: 121.47371234),
                      GlobePlace(country: "XX", city: "", latitude: -90, longitude: 180)]
        try encodePlaces(places).write(to: url)
        let table = try GlobePlaceTable(url: url)
        XCTAssertEqual(table.count, 2)
        for (i, place) in places.enumerated() { XCTAssertEqual(table.place(at: i), place) }
        XCTAssertNil(table.place(at: -1)); XCTAssertNil(table.place(at: 2))
    }
    func testCorruptHeadersRecordsAndCoordinatesFailClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for data in [Data(), Data("V2MLOC02".utf8), encodePlaces([GlobePlace(city: "A", latitude: 0, longitude: 0)]).prefix(20)] {
            try data.write(to: url); XCTAssertThrowsError(try GlobePlaceTable(url: url))
        }
        var data = encodePlaces([GlobePlace(city: "A", latitude: 0, longitude: 0)])
        data[16] = 255
        try data.write(to: url); XCTAssertNil(try GlobePlaceTable(url: url).place(at: 0))
        try encodePlaces([GlobePlace(city: "A", latitude: .nan, longitude: 0)]).write(to: url)
        XCTAssertNil(try GlobePlaceTable(url: url).place(at: 0))
    }
    func testIPv6RangeLookupUsesTheSameOfflineTable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let address = GlobeGeoDatabase.addressBytes("2606:4700::1111")!
        try Data().write(to: root.appendingPathComponent("ipv4.bin"))
        try Data(address + address + [0, 0, 0, 0]).write(to: root.appendingPathComponent("ipv6.bin"))
        try encodePlaces([GlobePlace(country: "US", city: "IPv6 fixture", latitude: 1, longitude: 2)])
            .write(to: root.appendingPathComponent("places.bin"))
        let db = try GlobeGeoDatabase(directory: root)
        XCTAssertEqual(db.lookup("2606:4700::1111")?.city, "IPv6 fixture")
        XCTAssertNil(db.lookup("2606:4700::1112"))
    }
    func testMeasuredRealDataLoadingAndExactRecordParity() throws {
        guard let root = ProcessInfo.processInfo.environment["V2RAYM_GEO_BENCHMARK"] else {
            throw XCTSkip("Set V2RAYM_GEO_BENCHMARK to the comparison directory")
        }
        let directory = URL(fileURLWithPath: root)
        let before = directory.appendingPathComponent("places-before.json")
        let after = directory.appendingPathComponent("places.bin")
        let start = ProcessInfo.processInfo.systemUptime
        let old = try JSONDecoder().decode([GlobePlace].self, from: Data(contentsOf: before))
        let decoded = ProcessInfo.processInfo.systemUptime
        let table = try GlobePlaceTable(url: after)
        let first = table.place(at: 0)
        let mapped = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(table.count, old.count); XCTAssertEqual(first, old.first)
        for (index, expected) in old.enumerated() { XCTAssertEqual(table.place(at: index), expected) }
        let oldBytes = try FileManager.default.attributesOfItem(atPath: before.path)[.size] as! NSNumber
        let newBytes = try FileManager.default.attributesOfItem(atPath: after.path)[.size] as! NSNumber
        let evidence: [String: Any] = [
            "schemaVersion": 1, "measuredAt": ISO8601DateFormatter().string(from: Date()),
            "method": "Single local debug XCTest run; JSON eager decode versus mmap header plus first lookup. Filesystem cache uncontrolled; not an RSS measurement.",
            "records": old.count, "exactRecordParity": old.enumerated().allSatisfy { table.place(at: $0.offset) == $0.element },
            "jsonBytes": oldBytes, "binaryBytes": newBytes,
            "savedBytes": oldBytes.intValue - newBytes.intValue,
            "savedPercent": 100 * (1 - newBytes.doubleValue / oldBytes.doubleValue),
            "jsonLoadMilliseconds": (decoded - start) * 1000,
            "binaryLoadAndFirstLookupMilliseconds": (mapped - decoded) * 1000,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("measurement.json"))
        print("GEO_BENCHMARK records=\(old.count) jsonBytes=\(oldBytes) binaryBytes=\(newBytes) jsonLoadMs=\((decoded-start)*1000) binaryLoadAndFirstLookupMs=\((mapped-decoded)*1000) exactParity=true")
    }
}
