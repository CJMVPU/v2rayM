import Darwin
import Foundation

// The independent loopback driver sends one JSON request per line and observes
// the published C ABI of the exact library copied into the product.
func serveCoreTest(_ library: String) throws {
    guard let image = dlopen(library, RTLD_LOCAL | RTLD_NOW) else { throw ToolFailure("Cannot open " + library) }
    func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let pointer = dlsym(image, "V2rayMCore" + name) else { throw ToolFailure("Missing core symbol: " + name) }
        return unsafeBitCast(pointer, to: type)
    }
    typealias ResultPointer = UnsafeMutablePointer<CChar>?
    typealias Arg = UnsafePointer<CChar>?
    let release = try symbol("Free", (@convention(c) (ResultPointer) -> Void).self)
    let start = try symbol("StartPair", (@convention(c) (Arg, Arg, Arg) -> ResultPointer).self)
    let logged = try symbol("StartLogged", (@convention(c) (Arg, Arg, Arg, Int32, Int32) -> ResultPointer).self)
    let stop = try symbol("Stop", (@convention(c) () -> ResultPointer).self)
    let drain = try symbol("DrainLogs", (@convention(c) () -> ResultPointer).self)
    let traffic = try symbol("Traffic", (@convention(c) (UnsafeMutablePointer<Int64>, Int32) -> Int32).self)
    let open = try symbol("OpenProbe", (@convention(c) (Arg, Arg, Arg) -> ResultPointer).self)
    let measure = try symbol("MeasureProbe", (@convention(c) (Arg, Arg) -> ResultPointer).self)
    let close = try symbol("CloseProbe", (@convention(c) (Arg) -> ResultPointer).self)
    var counters = [Int64](repeating: -1, count: 4)
    defer { if let error = stop() { release(error) } }
    while let line = readLine() {
        guard let req = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? Object else { throw ToolFailure("Invalid request") }
        let args = req["args"] as? [String] ?? []
        var answer = Object(), result: ResultPointer
        switch req["action"] as? String {
        case "start" where args.count == 3: result = start(args[0], args[1], args[2])
        case "logged" where args.count == 3: result = logged(args[0], args[1], args[2], -1, 0)
        case "stop": result = stop()
        case "logs": result = drain()
        case "open" where args.count == 3: result = open(args[0], args[1], args[2])
        case "measure" where args.count == 2: result = measure(args[0], args[1])
        case "close" where args.count == 1: result = close(args[0])
        case "traffic" where args.count == 1:
            guard let size = Int32(args[0]), (0...4).contains(size) else { throw ToolFailure("Invalid counter count") }
            answer["ok"] = traffic(&counters, size)
            answer["counts"] = counters
            result = nil
        default: throw ToolFailure("Invalid core test operation")
        }
        if let result { answer["result"] = String(cString: result); release(result) }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: answer) + Data([10]))
    }
}
