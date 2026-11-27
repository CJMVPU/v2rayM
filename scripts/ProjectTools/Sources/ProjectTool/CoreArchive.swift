import ArchiveReader
import Foundation

func unpackArchive(_ file: URL, to destination: URL, sourceTar: Bool, prefix: String = "", files: Set<String>? = nil) throws -> Set<String> {
    guard let reader = archive_read_new() else { throw ToolFailure("Cannot create archive reader") }
    defer { archive_read_free(reader) }
    if sourceTar {
        guard archive_read_support_filter_gzip(reader) == 0, archive_read_support_format_tar(reader) == 0 else { throw ToolFailure("Cannot read compressed tar") }
    } else if archive_read_support_format_zip_seekable(reader) != 0 { throw ToolFailure("Cannot read zip") }
    guard archive_read_open_filename(reader, file.path, 65536) == 0 else { throw ToolFailure("Cannot open archive") }
    var written = Set<String>(), count = 0, size: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        var entry: OpaquePointer?
        let result = archive_read_next_header(reader, &entry)
        if result == 1 { break }
        guard result == 0, let entry, let cpath = archive_entry_pathname(entry), let path = String(validatingUTF8: cpath) else { throw ToolFailure("Invalid archive header") }
        guard path.hasPrefix(prefix) else { continue }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.split(separator: "/").contains(".."),
              archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
              archive_entry_is_encrypted(entry) != 1 else { throw ToolFailure("Unsafe archive entry: \(path)") }
        let kind = archive_entry_filetype(entry)
        if kind == S_IFDIR { continue }
        let length = archive_entry_size(entry)
        count += 1
        guard kind == S_IFREG, length >= 0, length <= (1 << 30) - size, count <= (sourceTar ? 100_000 : 4096) else { throw ToolFailure("Unexpected archive contents") }
        size += length
        guard files?.contains(relative) != false else { continue }
        let target = destination.appendingPathComponent(relative)
        guard written.insert(relative).inserted, !FileManager.default.fileExists(atPath: target.path) else { throw ToolFailure("Duplicate archive entry") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: target, options: .withoutOverwriting)
        let sink = try FileHandle(forWritingTo: target)
        defer { try? sink.close() }
        var received: Int64 = 0
        while true {
            let n = archive_read_data(reader, &buffer, buffer.count)
            guard n >= 0, received + Int64(n) <= length else { throw ToolFailure("Corrupt archive entry") }
            if n == 0 { break }
            received += Int64(n)
            try sink.write(contentsOf: Data(buffer.prefix(n)))
        }
        guard received == length else { throw ToolFailure("Truncated archive entry") }
    }
    return written
}

func extractCoreBundle(_ args: [String]) throws {
    guard args.count == 5, ["full", "--data-only"].contains(args[4]) else { throw ToolFailure("Expected archive, bundle, destination, commit and mode") }
    let archive = URL(fileURLWithPath: args[0]), dest = URL(fileURLWithPath: args[2])
    let fm = FileManager.default
    guard !fm.fileExists(atPath: dest.path) else { throw ToolFailure("Destination already exists") }
    let staging = dest.deletingLastPathComponent().appendingPathComponent(".cores-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    var wanted: Set<String> = ["geoip.dat", "geosite.dat"]
    if args[4] == "full" { wanted.formUnion(["xray/xray", "xray/LICENSE"]) }
    let written = try unpackArchive(archive, to: staging, sourceTar: false, prefix: args[1] + "/bin/", files: wanted)
    guard wanted.subtracting(["xray/LICENSE"]).isSubset(of: written) else { throw ToolFailure("Missing required cores or Geo data") }
    if written.contains("xray/xray") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent("xray/xray").path) }
    var sums = [String: String]()
    for name in written { sums[name] = try fileDigest(staging.appendingPathComponent(name)) }
    try writeObject(["repository": "2dust/v2rayN-core-bin", "commit": args[3], "archiveSHA256": fileDigest(archive), "files": sums],
                    to: staging.appendingPathComponent("core-bundle-source.json"))
    try fm.moveItem(at: staging, to: dest)
}
