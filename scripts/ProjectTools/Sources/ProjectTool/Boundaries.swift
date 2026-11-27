import Foundation

private func matches(_ pattern: String, in source: String) -> Bool {
    source.range(of: pattern, options: .regularExpression) != nil
}

func visitFiles(_ root: URL, skipping: Set<String> = [], visit: (URL, String) throws -> Void) throws {
    let fm = FileManager.default
    var readError: Error?
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], errorHandler: { _, error in
        readError = error
        return false
    }) else { throw ToolFailure("Cannot read \(root.path)") }
    for case let url as URL in walker {
        let path = url.pathComponents.suffix(walker.level).joined(separator: "/")
        if skipping.contains(url.lastPathComponent) || (!skipping.isEmpty && path == "artifacts") {
            walker.skipDescendants()
        } else if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
            try visit(url, path)
        }
    }
    if let readError { throw readError }
}

func domainBoundaries(_ root: URL) throws -> [String] {
    var errors = [String]()
    let imports = try NSRegularExpression(pattern: #"(?m)^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|internal|package)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)"#)
    for (target, allowed) in [("V2rayMDomain", ["Foundation"]), ("V2rayMApplication", ["Foundation", "V2rayMDomain"])] {
        let directory = root.appendingPathComponent("macos/Native/Sources/" + target)
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        try visitFiles(directory) { url, _ in
            guard url.pathExtension == "swift" else { return }
            let source = try String(contentsOf: url, encoding: .utf8)
            let text = source as NSString
            for match in imports.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: match.range(at: 1))
                if !allowed.contains(name) { errors.append("\(url.path): forbidden \(target) import \(name)") }
            }
            if matches(#"\b(?:URLSession|URLRequest|FileManager|FileHandle|Process|UserDefaults|NSWorkspace)\s*[.(]"#, in: source) {
                errors.append("\(url.path): infrastructure API in \(target)")
            }
        }
    }
    let package = try String(contentsOf: root.appendingPathComponent("macos/Native/Package.swift"), encoding: .utf8)
    if !matches(#"\.target\s*\(\s*name\s*:\s*"V2rayMDomain"\s*\)"#, in: package) {
        errors.append("Native domain target must have no target dependencies")
    }
    if !matches(#"\.target\s*\(\s*name\s*:\s*"V2rayMApplication"\s*,\s*dependencies\s*:\s*\[\s*"V2rayMDomain"\s*,?\s*\]\s*,?\s*\)"#, in: package) {
        errors.append("Native application target may depend only on the domain target")
    }
    return errors
}

func productBoundaries(_ root: URL) throws -> [String] {
    let engine = #"(?i)sing[-_]?box|SagerNet|\b\w*4Sbox\w*\b|https?://[^\s"']*MetaCubeX"#
    let packaging = #"(?i)sing[-_]?box|SagerNet|MetaCubeX|\bmihomo\b|\.srs\b"#
    let managedTool = #"(?i)actions/setup-dotnet@|\bdotnet\s+(?:build|run|test|publish|restore|exec|tool)\b"#
    let interpreter = #"(?i)(?:^|[\s/])(?:python(?:[23](?:\.[0-9]+)?)?|pip[23]?)(?![a-z0-9_.-])|actions/setup-python@"#
    let ignored = Set(["bin", "obj", "Tests", "publish", ".packages"])
    var errors = [String]()
    try visitFiles(root, skipping: [".git", ".build", ".swiftpm"]) { file, path in
        let name = file.lastPathComponent.lowercased()
        let ext = file.pathExtension.lowercased()
        if ["py", "pyw", "pyc"].contains(ext) || ["pyproject.toml", "pipfile", "pipfile.lock", "poetry.lock", "uv.lock", "requirements.txt"].contains(name) {
            errors.append("\(path): retired interpreter source or dependency")
        }
        if ["cs", "csproj", "fsproj", "sln", "slnx"].contains(ext) || path.lowercased() == "global.json" ||
            ["nuget.config", "directory.build.props", "directory.packages.props"].contains(name) {
            errors.append("\(path): retired managed project file")
        }
        let guardFixtures = ["scripts/ProjectTools/Sources/ProjectTool/Boundaries.swift",
                             "scripts/ProjectTools/Tests/ProjectToolTests/BoundaryTests.swift"]
        let activeSource = ["macos/", ".github/", "scripts/"].contains(where: path.hasPrefix)
        var source: String?
        if activeSource, !guardFixtures.contains(path),
           ["swift", "go", "sh", "command", "yml", "yaml", "c", "h", ""].contains(ext) {
            source = String(data: try Data(contentsOf: file), encoding: .utf8)
            if let source, matches(interpreter, in: source) {
                errors.append("\(path): retired interpreter invocation")
            }
        }
        guard !path.split(separator: "/").contains(where: { ignored.contains(String($0)) }), name != "pac" else { return }
        let native = path.hasPrefix("macos/Native/Sources/")
        let helper = path.hasPrefix("macos/TunHelper/Sources/")
        let bridge = path.hasPrefix("scripts/xray/library/") || path.hasPrefix("contracts/")
        let isTool = path.hasPrefix("scripts/ProjectTools/Sources/")
        let script = path.hasPrefix("scripts/") && !["test-", "test_", "smoke-"].contains(where: name.hasPrefix)
        let workflow = path.hasPrefix(".github/workflows/")
        let sources = ["go", "swift", "json", "py", "sh", "ps1", "yml", "yaml", ""]
        // The guard contains the forbidden examples as patterns.
        if path == "scripts/ProjectTools/Sources/ProjectTool/Boundaries.swift" { return }
        guard ((native || helper || bridge) && sources.contains(ext)) ||
                ((script || workflow) && ["sh", "command", "py", "ps1", "yml", "yaml", ""].contains(ext)) ||
                (isTool && ext == "swift") else { return }
        let build = bridge || script || workflow
        let pattern = build ? packaging : engine
        if matches(pattern, in: path) { errors.append("\(path): retired engine file") }
        guard let text = try source ?? String(data: Data(contentsOf: file), encoding: .utf8) else { return }
        let enginePattern = native ? pattern + "|(?i:mihomo|clash)" : pattern
        // Scan clean files once. Only split a file into lines when a diagnostic needs a location.
        guard matches(enginePattern, in: text) || (build && matches(managedTool, in: text)) else { return }
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            if build && matches(managedTool, in: line) { errors.append("\(path):\(offset + 1): retired managed toolchain") }
            if matches(enginePattern, in: line) {
                errors.append("\(path):\(offset + 1): retired engine reference")
            }
        }
    }
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("v2rayN").path) {
        errors.append("Retired v2rayN source directory is present")
    }
    return errors
}
