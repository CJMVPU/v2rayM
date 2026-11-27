import Foundation

let embeddedLibrary = "Contents/Frameworks/libV2rayMXray.dylib"
private let helperExecutable = "Contents/MacOS/V2rayMHelper"
private let runtimeDataDirectory = "Contents/Resources/Backend/bin"

func sourceSnapshot(_ root: URL) throws -> Object {
    let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.range(of: #"^[0-9]\.[0-9]\.[0-9]$"#, options: .regularExpression) != nil else { throw ToolFailure("Invalid three-component VERSION") }
    func gitFiles(_ options: [String]) throws -> [String] {
        String(decoding: try output(["git", "ls-files", "-z"] + options, at: root), as: UTF8.self).split(separator: "\0").map(String.init)
    }
    var files = [String: String]()
    for name in Set(try gitFiles(["--cached", "--others", "--exclude-standard"])) {
        let file = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { files[name] = try fileDigest(file) }
    }
    let groups = ["xray": ["scripts/xray/library/", "patches/xray/", "contracts/macos-build-inputs.json"],
                  "native": ["macos/Native/", "macos/SystemArchive/"], "helper": ["macos/TunHelper/", "macos/Resources/", "contracts/"],
                  "build": ["scripts/", "macos/SystemArchive/", ".github/", "VERSION"]]
    let parts = groups.mapValues { prefixes in
        digest(canonicalDigests(files.filter { field in prefixes.contains { field.key.hasPrefix($0) } }))
    }
    let untracked = try commandText(["git", "ls-files", "--others", "--exclude-standard"], at: root).components(separatedBy: "\n").filter { !$0.isEmpty }
    var delta = try output(["git", "diff", "--binary", "HEAD", "--"], at: root)
    delta.append(canonicalDigests(Dictionary(uniqueKeysWithValues: untracked.map { ($0, files[$0]) }), spaced: true))
    return ["version": version, "commit": try commandText(["git", "rev-parse", "HEAD"], at: root),
            "dirty": try !commandText(["git", "status", "--porcelain", "--untracked-files=all"], at: root).isEmpty,
            "dirtyDigest": digest(delta), "sourceDigest": digest(canonicalDigests(files)), "componentSourceDigests": parts]
}

func assertSource(_ expected: Object, root: URL) throws {
    let current = try sourceSnapshot(root)
    for key in ["version", "sourceDigest"] {
        guard let value = expected[key] as? String, value == current[key] as? String else { throw ToolFailure("Source tree changed since snapshot") }
    }
}

func lockFile(_ root: URL) -> URL { root.appendingPathComponent("contracts/macos-build-inputs.json") }

func verifiedPatchNames(root: URL, pin: Object, library: Bool) throws -> [String] {
    let core: Object = try pin.required("xray")
    var groups: [[String: String]] = [try core.required("patches")]
    if library { groups.append(try pin.required("xrayLibraryPatches")) }
    // The reviewed lock records the application order of patches within each group.
    let lock = try String(contentsOf: lockFile(root), encoding: .utf8)
    var names = [String]()
    for group in groups {
        let ordered = try group.keys.map { name -> (String, String.Index) in
            guard let index = lock.range(of: "\"\(name)\"")?.lowerBound else { throw ToolFailure("Missing patch \(name)") }
            return (name, index)
        }.sorted { $0.1 < $1.1 }
        for (name, _) in ordered {
            guard name == URL(fileURLWithPath: name).lastPathComponent,
                  try fileDigest(root.appendingPathComponent("patches/xray/" + name)) == group[name] else {
                throw ToolFailure("Reviewed Xray patch checksum mismatch: \(name)")
            }
            names.append(name)
        }
    }
    return names
}

func verifyCore(root: URL, directory: URL, versionOutput: String? = nil) throws {
    let inputs = try readObject(lockFile(root))
    let pin: Object = try inputs.required("xray")
    let binary = directory.appendingPathComponent("xray/xray")
    let version = try versionOutput ?? commandText([binary.path, "version"])
    let marker: String = try pin.required("buildMarker")
    guard version.hasPrefix("Xray " + (try pin.required("version", as: String.self)) + " "),
          version.split(whereSeparator: \.isWhitespace).contains(Substring(marker)) else { throw ToolFailure("Not the reviewed Xray M2 repair") }
    guard version.contains("(go" + (try inputs.required("goVersion", as: String.self)) + " darwin/") else { throw ToolFailure("Unreviewed Go toolchain") }
    let source = try String(contentsOf: binary.deletingLastPathComponent().appendingPathComponent("SOURCE.txt"), encoding: .utf8)
    let names = try verifiedPatchNames(root: root, pin: inputs, library: false)
    let expected = ["Xray source": try pin.required("revision", as: String.self), "Archive SHA256": try pin.required("sourceSHA256"), "Patches": names.joined(separator: ", "), "Build": marker]
    for (key, value) in expected {
        guard source.components(separatedBy: .newlines).filter({ $0.hasPrefix(key + ": ") }) == [key + ": " + value] else {
            throw ToolFailure("Core SOURCE provenance differs for " + key)
        }
    }
}

private func libraryReceipt(root: URL, library: URL) throws -> Object {
    let inputs = try readObject(lockFile(root))
    _ = try verifiedPatchNames(root: root, pin: inputs, library: true)
    let dir = root.appendingPathComponent("scripts/xray/library")
    var bridge = [String: String]()
    for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "go" {
        bridge[url.lastPathComponent] = try fileDigest(url)
    }
    guard !bridge.isEmpty else { throw ToolFailure("Missing Xray bridge sources") }
    return ["inputs": try inputs.required("xray", as: Object.self),
            "libraryPatches": try inputs.required("xrayLibraryPatches", as: Object.self),
            "goVersion": try inputs.required("goVersion", as: String.self),
            "bridgeSources": bridge, "binarySHA256": try fileDigest(library)]
}

func verifyLibrary(root: URL, library: URL) throws {
    let expected = try libraryReceipt(root: root, library: library)
    let receipt = try readObject(library.deletingLastPathComponent().appendingPathComponent("library-build.json"))
    guard NSDictionary(dictionary: receipt).isEqual(to: expected) else { throw ToolFailure("Embedded Xray differs from reviewed inputs or build digest") }
}

func runtimeData(_ directory: URL, inputs: Object) throws -> Object {
    let expected: [String: String] = try inputs.required("coreBundleDataSHA256")
    var hashes = [String: String]()
    for file in ["geoip.dat", "geosite.dat"] {
        hashes[file] = try fileDigest(directory.appendingPathComponent(file))
        guard hashes[file] == expected[file] else { throw ToolFailure("Wrong pinned Geo DAT: " + file) }
    }
    var origin: Object = ["repository": "2dust/v2rayN-core-bin", "commit": try inputs.required("coreBundleCommit", as: String.self)]
    let source = directory.appendingPathComponent("core-bundle-source.json")
    if FileManager.default.fileExists(atPath: source.path) {
        let supplied = try readObject(source)
        let files = supplied["files"] as? [String: String]
        guard origin.allSatisfy({ supplied[$0.key] as? String == $0.value as? String }),
              hashes.allSatisfy({ files?[$0.key] == $0.value }) else { throw ToolFailure("Unexpected Geo origin") }
        origin = supplied
    }
    return ["SHA256": hashes, "origin": origin]
}

private func infoPlist(_ app: URL, receipt: Object) throws -> Object {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    let source: Object = try receipt.required("source")
    let version: String = try source.required("version")
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? Object,
          info["CFBundleShortVersionString"] as? String == version, info["CFBundleVersion"] as? String == version else {
        throw ToolFailure("Bundle versions differ from VERSION")
    }
    return info
}

func verifyApp(_ app: URL, receipt: Object, inputs: Object) throws {
    let fm = FileManager.default
    for (folder, names) in ["MacOS": ["V2rayM", "V2rayMHelper"], "Frameworks": ["libV2rayMXray.dylib"]] {
        for item in try fm.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/" + folder).path) where !names.contains(item) {
            throw ToolFailure("Unexpected executable or framework: \(folder)/\(item)")
        }
    }
    try visitFiles(app) { file, path in
        let name = file.lastPathComponent.lowercased()
        if ["py", "pyc", "pyw", "pyo"].contains(file.pathExtension.lowercased()) ||
            name.hasPrefix("libpython") || name == "python3" || name == "python" || path.lowercased().contains("/python.framework/") {
            throw ToolFailure("Unexpected interpreter in native package: " + path)
        }
        if ["xray", "v2raymhelperclient"].contains(name) { throw ToolFailure("Unexpected standalone process: " + path) }
        if name == "dotnet" || ["servicelib.", "v2rayn.webapi", "libcoreclr", "libhostfxr", "libhostpolicy"].contains(where: name.hasPrefix) ||
            [".dll", ".runtimeconfig.json", ".deps.json"].contains(where: name.hasSuffix) {
            throw ToolFailure("Unexpected managed runtime: " + path)
        }
    }
    let info = try infoPlist(app, receipt: receipt)
    guard info["CFBundleExecutable"] as? String == "V2rayM" else { throw ToolFailure("Invalid CFBundleExecutable") }
    for name in ["Contents/MacOS/V2rayM", helperExecutable, embeddedLibrary] {
        let file = app.appendingPathComponent(name)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              name == embeddedLibrary || fm.isExecutableFile(atPath: file.path) else { throw ToolFailure("Invalid packaged component: " + name) }
    }
    let data = try runtimeData(app.appendingPathComponent(runtimeDataDirectory), inputs: inputs)
    guard let recorded = receipt["runtimeData"] as? NSDictionary, recorded.isEqual(to: data) else { throw ToolFailure("Unexpected Geo digests or origin") }
    let artifacts: [String: String] = try receipt.required("artifacts")
    let resources: [String: String] = try receipt.required("resourceDigests")
    guard artifacts[embeddedLibrary] != nil, artifacts[helperExecutable] != nil else { throw ToolFailure("Missing packaged component digest") }
    for (name, hash) in Array(artifacts) + Array(resources) {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), try fileDigest(app.appendingPathComponent(name)) == hash else {
            throw ToolFailure("Packaged artifact changed: " + name)
        }
    }
}

func buildManifest(root: URL, args: [String]) throws {
    let inputs = try readObject(lockFile(root))
    switch args.first {
    case "snapshot":
        try writeObject(["schema": 1, "source": sourceSnapshot(root), "toolchains": [
            "swift": commandText(["swift", "--version"]), "clang": commandText(["xcrun", "clang", "--version"]),
            "macOS": commandText(["sw_vers", "-productVersion"])]], to: optionURL("--output", in: args))
    case "verify-core": try verifyCore(root: root, directory: optionURL("--core-bin", in: args))
    case "verify-library": try verifyLibrary(root: root, library: optionURL("--library", in: args))
    case "write-app", "verify-app", "seal-app":
        let app = try optionURL("--app", in: args)
        let resources = app.appendingPathComponent("Contents/Resources")
        let manifest = resources.appendingPathComponent("build-manifest.json")
        let writing = args.first == "write-app"
        var receipt = try readObject(writing ? optionURL("--snapshot", in: args) : manifest)
        try assertSource(receipt.required("source"), root: root)
        if writing {
            _ = try infoPlist(app, receipt: receipt)
            receipt["core"] = try readObject(resources.appendingPathComponent("Xray/library-build.json"))
            receipt["inputs"] = inputs
            receipt["runtimeData"] = try runtimeData(app.appendingPathComponent(runtimeDataDirectory), inputs: inputs)
            receipt["mainExecutableDigest"] = "Recorded after bundle signing in external product-manifest.json"
            var hashes = [String: String]()
            for name in [embeddedLibrary, helperExecutable] { hashes[name] = try fileDigest(app.appendingPathComponent(name)) }
            receipt["artifacts"] = hashes
            var resourceDigests = [String: String]()
            for bundle in ["V2rayMNative_V2rayM.bundle", "V2rayMNative_V2rayMKit.bundle"] {
                try visitFiles(resources.appendingPathComponent(bundle)) { file, path in
                    resourceDigests["Contents/Resources/\(bundle)/\(path)"] = try fileDigest(file)
                    if file.lastPathComponent == "geodata-manifest.json" { receipt["geolocation"] = try readObject(file) }
                }
            }
            guard receipt["geolocation"] != nil, resourceDigests.keys.contains(where: { $0.contains("V2rayMNative_V2rayMKit.bundle/") && $0.hasSuffix("/RuntimeDefaults/settings.json") }) else {
                throw ToolFailure("Missing bundled geolocation or runtime defaults")
            }
            receipt["resourceDigests"] = resourceDigests
            receipt["verification"] = ["signature": "verify externally after bundle signing", "realTUN": false, "notarized": false] as Object
            try writeObject(receipt, to: manifest)
        } else {
            try verifyApp(app, receipt: receipt, inputs: inputs)
            if args.first == "seal-app" {
                var hashes = [String: String]()
                try visitFiles(app) { file, name in hashes[name] = try fileDigest(file) }
                receipt["signedArtifacts"] = hashes
                try writeObject(receipt, to: optionURL("--output", in: args))
            }
        }
    default: throw ToolFailure("Unknown manifest operation")
    }
}

func writeLibraryReceipt(root: URL, binary: URL) throws {
    try writeObject(libraryReceipt(root: root, library: binary),
                    to: binary.deletingLastPathComponent().appendingPathComponent("library-build.json"))
}

// Schema 1 hashes the sorted flat map as ASCII JSON. Keep old receipts comparable,
// including paths with non-ASCII characters and Git's quoted untracked names.
private func canonicalDigests(_ fields: [String: String?], spaced: Bool = false) -> Data {
    func literal(_ text: String) -> String {
        var result = "\""
        for value in text.utf16 {
            switch value {
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 32...126: result.append(Character(UnicodeScalar(value)!))
            default: result += String(format: "\\u%04x", value)
            }
        }
        return result + "\""
    }
    let rows = fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { key in
        literal(key) + (spaced ? ": " : ":") + ((fields[key] ?? nil).map(literal) ?? "null")
    }
    return Data(("{" + rows.joined(separator: spaced ? ", " : ",") + "}").utf8)
}
