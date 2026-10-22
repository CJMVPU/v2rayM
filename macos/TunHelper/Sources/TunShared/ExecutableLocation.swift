import Foundation
import Darwin

public enum ExecutableLocation {
    /// launchd may supply a bundle-relative argv[0]; dyld knows the loaded executable.
    public static func current() throws -> URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw HelperFailure("executable_path_unavailable")
        }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}
