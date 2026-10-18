import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Ends the process when its memory passes a limit, or when it runs past a
/// time limit. The plugin's executables start one, so a compiler or tool bug
/// that keeps allocating stops at the limit instead of taking the machine
/// down: the hook and the MCP server run on every edit, unattended.
public final class MemoryLimit: @unchecked Sendable {
    public let megabytes: Int
    private let timer: DispatchSourceTimer
    private let onExceed: @Sendable (String) -> Void

    /// Checks ten times a second. `onExceed` gets the reason; by default it
    /// writes it to stderr and exits with status 1.
    public init(megabytes: Int, seconds: Double? = nil,
                onExceed: @escaping @Sendable (String) -> Void = MemoryLimit.exit) {
        self.megabytes = megabytes
        self.onExceed = onExceed
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "spirv-tools.memory-limit"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [megabytes, onExceed] in
            if let used = MemoryLimit.residentMegabytes(), used > megabytes {
                onExceed("stopped: using \(used) MB, over the \(megabytes) MB limit")
            } else if let deadline, Date() > deadline {
                onExceed("stopped: ran longer than \(Int(seconds ?? 0)) s")
            }
        }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    public static let exit: @Sendable (String) -> Void = { reason in
        FileHandle.standardError.write(Data("spirv-tools: \(reason)\n".utf8))
        Foundation.exit(1)
    }

    /// The process's memory: its physical footprint on Apple platforms (what
    /// Activity Monitor shows), resident pages elsewhere.
    public static func residentMegabytes() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
        #else
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = statm.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE))) / 1_048_576
        #endif
    }
}
