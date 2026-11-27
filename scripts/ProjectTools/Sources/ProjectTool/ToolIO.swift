import CryptoKit
import Foundation

typealias Object = [String: Any]

func readObject(_ url: URL) throws -> Object {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object else {
        throw ToolFailure("Expected JSON object in \(url.path)")
    }
    return value
}

func writeObject(_ value: Object, to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: url, options: .atomic)
}

extension Dictionary where Key == String, Value == Any {
    func required<T>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let value = self[key] as? T else { throw ToolFailure("Missing or invalid field: \(key)") }
        return value
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fileDigest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func output(_ args: [String], at directory: URL? = nil, input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    process.standardOutput = stdout
    let stdin = Pipe()
    if input != nil { process.standardInput = stdin }
    try process.run()
    if let input {
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolFailure("\(args.first ?? "Command") exited with \(process.terminationStatus)") }
    return data
}

func commandText(_ args: [String], at directory: URL? = nil, input: Data? = nil) throws -> String {
    String(decoding: try output(args, at: directory, input: input), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func optionURL(_ name: String, in args: [String]) throws -> URL {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { throw ToolFailure("Missing \(name)") }
    return URL(fileURLWithPath: args[i + 1]).standardizedFileURL
}
