import Darwin
import Foundation

private extension Data {
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

private struct Place: Hashable {
    let country: Data
    let city: Data
    let latitude: Double
    let longitude: Double
}

private struct RangeWriter {
    let width: Int
    var previous: [UInt8]?
    var previousPlace: UInt32?
    var count: UInt32 = 0
    var buffer = Data()
    let output: FileHandle

    init(width: Int, url: URL) throws {
        self.width = width
        try Data(repeating: 0, count: 16).write(to: url)
        output = try FileHandle(forWritingTo: url)
        try output.seekToEnd()
    }

    func successor(_ input: [UInt8]) -> [UInt8]? {
        var value = input
        for i in value.indices.reversed() {
            value[i] &+= 1
            if value[i] != 0 { return value }
        }
        return nil
    }

    mutating func emit(_ start: [UInt8], _ place: UInt32) throws {
        buffer.append(contentsOf: start)
        buffer.integer(place)
        count += 1
        if buffer.count >= 128 * 1024 {
            try output.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    mutating func add(start: [UInt8], end: [UInt8], place: UInt32) throws {
        guard !end.lexicographicallyPrecedes(start), previous?.lexicographicallyPrecedes(start) != false else {
            throw ToolFailure("Geo ranges must be sorted and disjoint")
        }
        let next = previous.flatMap(successor)
        if let next, next != start { try emit(next, UInt32.max) }
        if next != start || previousPlace != place { try emit(start, place) }
        previous = end
        previousPlace = place
    }

    mutating func finish() throws {
        if let next = previous.flatMap(successor) { try emit(next, UInt32.max) }
        try output.write(contentsOf: buffer)
        var header = Data("V2MRNG02".utf8)
        header.integer(count)
        header.integer(UInt32(width + 4))
        try output.seek(toOffset: 0)
        try output.write(contentsOf: header)
        try output.close()
    }
}

private func address(_ field: Data) throws -> [UInt8] {
    let family = field.contains(58) ? AF_INET6 : AF_INET
    let size = family == AF_INET6 ? 16 : 4
    var result = [UInt8](repeating: 0, count: size)
    guard inet_pton(family, String(decoding: field, as: UTF8.self), &result) == 1 else { throw ToolFailure("Invalid Geo IP address") }
    return result
}

private func readCSV(_ archive: URL, row: ([Data]) throws -> Void) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-dc", archive.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    defer {
        try? pipe.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    var fields = [Data]()
    var field = Data()
    var quoted = false
    var afterQuote = false
    var afterCR = false
    while let block = try pipe.fileHandleForReading.read(upToCount: 1 << 17), !block.isEmpty {
        for byte in block {
            if afterCR { afterCR = false; if byte == 10 { continue } }
            if quoted {
                if byte == 34 { quoted = false; afterQuote = true } else { field.append(byte) }
            } else if byte == 34 && (afterQuote || field.isEmpty) {
                if afterQuote { field.append(byte) }
                quoted = true
                afterQuote = false
            } else if byte == 44 || byte == 10 || byte == 13 {
                fields.append(field)
                field = Data()
                afterQuote = false
                if byte != 44 {
                    try row(fields)
                    fields.removeAll(keepingCapacity: true)
                    afterCR = byte == 13
                }
            } else {
                guard !afterQuote else { throw ToolFailure("Unexpected data after quoted CSV field") }
                field.append(byte)
            }
        }
    }
    guard !quoted else { throw ToolFailure("Unterminated CSV field") }
    if !fields.isEmpty || !field.isEmpty || afterQuote { fields.append(field); try row(fields) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolFailure("Invalid compressed Geo input") }
}

let geoNames = ["ipv4.bin", "ipv6.bin", "places.bin"]

func compileGeo(_ input: URL, to directory: URL, sourceURL: String? = nil) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var ipv4 = try RangeWriter(width: 4, url: directory.appendingPathComponent(geoNames[0]))
    var ipv6 = try RangeWriter(width: 16, url: directory.appendingPathComponent(geoNames[1]))
    var places = [Place: UInt32]()
    var strings = Data(), records = Data()
    try readCSV(input) { fields in
        guard fields.count >= 8,
              let latitude = Double(String(decoding: fields[6], as: UTF8.self)), (-90...90).contains(latitude),
              let longitude = Double(String(decoding: fields[7], as: UTF8.self)), (-180...180).contains(longitude),
              let country = UInt16(exactly: fields[3].count), let city = UInt16(exactly: fields[5].count) else { throw ToolFailure("Invalid city coordinates or labels") }
        let start = try address(fields[0]), end = try address(fields[1])
        guard start.count == end.count else { throw ToolFailure("Mismatched Geo address families") }
        let place = Place(country: fields[3], city: fields[5], latitude: latitude, longitude: longitude)
        let index: UInt32
        if let existing = places[place] { index = existing } else {
            guard let offset = UInt32(exactly: strings.count), let new = UInt32(exactly: places.count), new != UInt32.max else { throw ToolFailure("Geo index too large") }
            index = new
            places[place] = index
            records.integer(offset)
            records.integer(country)
            records.integer(city)
            records.integer(latitude.bitPattern)
            records.integer(longitude.bitPattern)
            strings.append(place.country)
            strings.append(place.city)
        }
        if start.count == 4 { try ipv4.add(start: start, end: end, place: index) }
        else { try ipv6.add(start: start, end: end, place: index) }
    }
    try ipv4.finish()
    try ipv6.finish()
    var locations = Data("V2MLOC01".utf8)
    locations.integer(UInt32(places.count))
    locations.integer(UInt32(24))
    locations.append(records)
    locations.append(strings)
    try locations.write(to: directory.appendingPathComponent("places.bin"))
    var outputs = Object()
    for name in geoNames {
        let file = directory.appendingPathComponent(name)
        outputs[name] = ["sha256": try fileDigest(file), "bytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!] as Object
    }
    try writeObject(["formatVersion": 2, "input": ["file": input.lastPathComponent, "sourceURL": sourceURL ?? ("https://download.db-ip.com/free/" + input.lastPathComponent), "sha256": try fileDigest(input)], "outputs": outputs], to: directory.appendingPathComponent("geodata-manifest.json"))
}

func verifyGeo(directory: URL, lock: Object) throws {
    let manifest = try readObject(directory.appendingPathComponent("geodata-manifest.json"))
    let input: [String: String] = try manifest.required("input")
    guard manifest["formatVersion"] as? Int == 2, let pinned = lock["sha256"] as? String,
          input["sha256"] == pinned, let source = lock["sourceURL"] as? String, input["sourceURL"] == source else {
        throw ToolFailure("Geo input does not match the reviewed lock or format")
    }
    let outputs: [String: Object] = try manifest.required("outputs")
    for name in geoNames {
        let file = directory.appendingPathComponent(name)
        guard let item = outputs[name], let bytes = item["bytes"] as? Int, try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes,
              try fileDigest(file) == item["sha256"] as? String else { throw ToolFailure("Unexpected Geo output: " + name) }
    }
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ATTRIBUTION.txt").path) else { throw ToolFailure("Missing DB-IP attribution") }
}

func prepareGeo(root: URL, args: [String]) throws {
    let fm = FileManager.default
    let target = root.appendingPathComponent("macos/Native/Sources/V2rayM/Resources/Globe")
    let lock: Object = try readObject(lockFile(root)).required("geolocation")
    if args.contains("--verify-only") { try verifyGeo(directory: target, lock: lock); return }
    let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }
    let source: URL
    if args.contains("--source") { source = try optionURL("--source", in: args) } else {
        source = temp.appendingPathComponent(try lock.required("file", as: String.self))
        _ = try output(["/usr/bin/curl", "--fail", "--location", "--connect-timeout", "30", "--user-agent", "v2rayM-build/1.0 (+https://github.com/CJMVPU/v2rayM)", "--output", source.path, try lock.required("sourceURL", as: String.self)])
    }
    guard try fileDigest(source) == lock["sha256"] as? String else { throw ToolFailure("Pinned DB-IP archive checksum mismatch") }
    let staging = temp.appendingPathComponent("tables")
    try compileGeo(source, to: staging, sourceURL: lock.required("sourceURL", as: String.self))
    try fm.copyItem(at: target.appendingPathComponent("ATTRIBUTION.txt"), to: staging.appendingPathComponent("ATTRIBUTION.txt"))
    try verifyGeo(directory: staging, lock: lock)
    for name in geoNames + ["geodata-manifest.json"] {
        let file = target.appendingPathComponent(name)
        let staged = staging.appendingPathComponent(name)
        if name == "geodata-manifest.json", let existing = try? readObject(file),
           try NSDictionary(dictionary: existing).isEqual(to: readObject(staged)) { continue }
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: file)
        }
    }
}
