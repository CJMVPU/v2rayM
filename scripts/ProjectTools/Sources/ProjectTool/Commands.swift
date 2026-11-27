import Foundation

struct ToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct ProjectTool {
    static func main() {
        do {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["V2RAYM_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath)
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "serve-core-test":
                guard args.count == 2 else { throw ToolFailure("Expected a library to test") }
                try serveCoreTest(args[1])
            case "extract-core-bundle":
                try extractCoreBundle(Array(args.dropFirst()))
            case "unpack-xray-source":
                guard args.count == 3 else { throw ToolFailure("Expected source archive and destination") }
                _ = try unpackArchive(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]), sourceTar: true)
            case "xray-patches":
                for name in try verifiedPatchNames(root: root, pin: readObject(lockFile(root)), library: args.dropFirst().contains("--library")) { print(name) }
            case "xray-library-receipt":
                try writeLibraryReceipt(root: root, binary: optionURL("--library", in: args))
            case "prepare-globe-geo":
                guard args.count == 3 else { throw ToolFailure("Expected source archive and output directory") }
                try compileGeo(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
            case "prepare-macos-geo":
                try prepareGeo(root: root, args: Array(args.dropFirst()))
            case "macos-build-manifest":
                try buildManifest(root: root, args: Array(args.dropFirst()))
            case "select-macos-signing-identity":
                guard args.count == 2 else { throw ToolFailure("Expected a signing team") }
                print(try selectSigningIdentity(team: args[1]))
            case "generate-helper-contract":
                guard args.count == 1 || args.dropFirst().elementsEqual(["--check"]) else {
                    throw ToolFailure("Expected generate-helper-contract [--check]")
                }
                try generateHelperContract(root: root, checkOnly: args.count == 2)
            case "check-ddd-boundaries", "check-macos-product-boundaries":
                let issues = args.first == "check-ddd-boundaries" ? try domainBoundaries(root) : try productBoundaries(root)
                guard issues.isEmpty else { throw ToolFailure(issues.joined(separator: "\n")) }
            default:
                throw ToolFailure("Unknown project tool: " + (args.first ?? "(missing command)"))
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
