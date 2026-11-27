// Independent HTTP peers for transport, update, and backup integration tests.
import Darwin
import Foundation

struct PeerError: Error {}
func loopback(_ port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}
func withAddress<T>(_ addr: inout sockaddr_in, _ action: (UnsafeMutablePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}
func listener(_ handle: @escaping (Int32) throws -> Void) throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopback(0)
    guard fd >= 0, withAddress(&address, { bind(fd, $0, $1) }) == 0, listen(fd, 32) == 0,
          withAddress(&address, { ptr, size in var length = size; return getsockname(fd, ptr, &length) }) == 0 else { throw PeerError() }
    DispatchQueue.global().async {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 { return }
            DispatchQueue.global().async {
                defer { close(connection) }
                try? handle(connection)
            }
        }
    }
    return UInt16(bigEndian: address.sin_port)
}
func sendAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            guard count > 0 else { throw PeerError() }
            offset += count
        }
    }
}
struct Request {
    let method: String, path: String
    var headers = [String: String]()
    let body: Data
    init(_ fd: Int32) throws {
        var received = Data(), byte: UInt8 = 0
        let end = [UInt8]("\r\n\r\n".utf8)
        while !received.suffix(4).elementsEqual(end) {
            guard received.count < 65536, recv(fd, &byte, 1, 0) == 1 else { throw PeerError() }
            received.append(byte)
        }
        let lines = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3 else { throw PeerError() }
        method = String(parts[0]); path = String(parts[1])
        for line in lines.dropFirst() {
            if let index = line.firstIndex(of: ":") {
                headers[line[..<index].lowercased()] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...16_777_216).contains(length) else { throw PeerError() }
        var payload = Data(count: length)
        try payload.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < length {
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), length - offset, 0)
                guard n > 0 else { throw PeerError() }
                offset += n
            }
        }
        body = payload
    }
}
func reply(_ fd: Int32, _ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) throws {
    var fields = headers
    fields["Content-Length"] = String(body.count)
    try sendAll(fd, Data(("HTTP/1.0 \(status) Response\r\n" + fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8))
    try sendAll(fd, body)
}
func geo(_ fd: Int32) throws {
    let request = try Request(fd)
    let parts = request.path.split(separator: "/")
    guard parts.count == 2 else { return try reply(fd, 404) }
    let scenario = String(parts[0])
    switch scenario {
    case "redirect": return try reply(fd, 302, headers: ["Location": "/success/" + parts[1]])
    case "success": return try reply(fd, 200, Data(repeating: 118, count: 1 << 20))
    case "failure": return try reply(fd, 503)
    case "oversized": try sendAll(fd, Data("HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 33554433\r\n\r\n".utf8))
        try sendAll(fd, Data([120])); sleep(3)
    case "unbounded":
        try sendAll(fd, Data("HTTP/1.0 200 OK\r\n\r\n".utf8))
        let block = Data(repeating: 120, count: 128 << 10)
        for _ in 0..<257 { try sendAll(fd, block) }
    case "idle", "trickle":
        try sendAll(fd, Data("HTTP/1.0 200 OK\r\nContent-Length: 100\r\n\r\n".utf8))
        if scenario == "idle" { sleep(8) } else {
            for _ in 0..<100 { try sendAll(fd, Data([120])); usleep(150_000) }
        }
    default: try reply(fd, 404)
    }
}
func webDAV(_ fd: Int32, root: URL) throws {
    let req = try Request(fd)
    let components = req.path.split(separator: "/")
    guard !components.contains("..") else { return try reply(fd, 403) }
    let file = components.reduce(root) { $0.appendingPathComponent(String($1)) }
    let fm = FileManager.default
    switch req.method {
    case "MKCOL":
        if components == ["shared", "team"] { return try reply(fd, 403) }
        if fm.fileExists(atPath: file.path) { return try reply(fd, 405) }
        guard fm.fileExists(atPath: file.deletingLastPathComponent().path) else { return try reply(fd, 409) }
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        try reply(fd, 201)
    case "PUT": try req.body.write(to: file); try reply(fd, 201)
    case "GET":
        if components.first == "denied" { return try reply(fd, 403) }
        var bytes = try Data(contentsOf: file)
        if components.first == "corrupt" { bytes.append(120) }
        try reply(fd, 200, bytes)
    case "DELETE": try fm.removeItem(at: file); try reply(fd, 204)
    default: try reply(fd, 405)
    }
}
func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}
func relay(_ fd: Int32, to port: UInt16) throws {
    var address = loopback(port)
    let upstream = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(upstream) }
    guard upstream >= 0, withAddress(&address, { connect(upstream, $0, $1) }) == 0 else { throw PeerError() }
    try sendAll(fd, Data("HTTP/1.0 200 Connected\r\n\r\n".utf8))
    var fds = [fd, upstream].map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    var buffer = [UInt8](repeating: 0, count: 65536)
    while poll(&fds, 2, 8000) > 0 {
        for i in fds.indices where fds[i].revents != 0 {
            let read = recv(fds[i].fd, &buffer, buffer.count, 0)
            if read <= 0 { return }
            try sendAll(fds[1-i].fd, Data(buffer.prefix(read)))
        }
    }
}
func chain() throws {
    let lock = NSLock()
    var visits = [[String]]()
    func record(_ label: String, _ path: String) { lock.withLock { visits.append([label, path]) } }
    let body = Data("custom-chain-target-ok".utf8)
    let target = try listener { fd in
        let req = try Request(fd)
        guard req.method == "GET", req.path == "/chain" else { return try reply(fd, 404) }
        record("target", req.path)
        try reply(fd, 200, body)
    }
    func proxy(_ name: String, _ next: UInt16) throws -> UInt16 {
        try listener { fd in
            let req = try Request(fd)
            guard req.method == "CONNECT", req.path == "127.0.0.1:\(next)" else { return try reply(fd, 403) }
            record(name, req.path)
            try relay(fd, to: next)
        }
    }
    let end = try proxy("exit", target), entry = try proxy("entry", end)
    let reserve = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopback(0)
    guard reserve >= 0, withAddress(&address, { bind(reserve, $0, $1) }) == 0,
          withAddress(&address, { p,s in var n = s; return getsockname(reserve,p,&n) }) == 0 else { throw PeerError() }
    let inbound = UInt16(bigEndian: address.sin_port)
    close(reserve)
    try emit(["entry": entry, "exit": end, "target": target, "inbound": inbound])
    guard readLine() == "run" else { return }
    let curl = Process(), pipe = Pipe()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-q", "-fsS", "--max-time", "8", "--noproxy", "", "--proxy", "http://127.0.0.1:\(inbound)", "http://127.0.0.1:\(target)/chain"]
    curl.standardOutput = pipe
    try curl.run()
    let response = pipe.fileHandleForReading.readDataToEndOfFile()
    curl.waitUntilExit()
    let history = lock.withLock { visits }
    try emit(["visits": history, "body": String(decoding: response, as: UTF8.self)] as [String: Any])
    guard curl.terminationStatus == 0, response == body,
          history == [["entry", "127.0.0.1:\(end)"], ["exit", "127.0.0.1:\(target)"], ["target", "/chain"]] else { throw PeerError() }
}
signal(SIGPIPE, SIG_IGN)
switch CommandLine.arguments.dropFirst().first {
case "geo": try emit(listener(geo)); _ = readLine()
case "webdav":
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    try emit(listener { try webDAV($0, root: root) }); _ = readLine()
case "chain": try chain()
case "build-geo":
    try emit(listener { fd in
        let req = try Request(fd)
        guard req.path == "/archive", req.headers["user-agent"]?.hasPrefix("v2rayM-build/") == true else { return try reply(fd, 403) }
        try reply(fd, 200, Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    })
    _ = readLine()
default: throw PeerError()
}
