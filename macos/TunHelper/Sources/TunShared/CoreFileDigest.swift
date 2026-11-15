import Foundation
import CryptoKit
import Darwin

extension OfficialCorePolicy {
    /// Stream the exact opened regular file; do not follow a substituted symlink.
    /// Callers still validate store ownership and verify the private execution copy.
    static func hashFile(_ url: URL, maxSize: Int = 256 * 1024 * 1024) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperFailure("update_file_not_private") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maxSize else {
            throw HelperFailure("update_file_not_private")
        }
        var digest = SHA256()
        var total = 0
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maxSize - total else { throw HelperFailure("update_file_not_private") }
            total += chunk.count
            digest.update(data: chunk)
        }
        guard total == info.st_size else { throw HelperFailure("update_file_not_private") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
