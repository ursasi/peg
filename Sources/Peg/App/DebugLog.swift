import Foundation

/// Only active with PEG_DEBUG=1. Writes to /tmp/peg-debug.log so a test run can
/// be read back without opening Console.
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["PEG_DEBUG"] == "1"
    private static let url = URL(fileURLWithPath: "/tmp/peg-debug.log")
    private static let queue = DispatchQueue(label: "peg.debug.log")

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = message()
        NSLog("PegDebug: %@", line)
        queue.async {
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
