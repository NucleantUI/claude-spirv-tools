import Foundation
import Testing
@testable import ShaderDebug

/// What a MemoryLimit reported, set from its timer's queue.
final class Tripped: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        if reason == nil { reason = value }
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    /// Waits up to `seconds` for a reason.
    func wait(_ seconds: Double) -> String? {
        let end = Date().addingTimeInterval(seconds)
        while value == nil, Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        return value
    }
}

@Suite("MemoryLimit", .serialized)
struct MemoryLimitTests {
    @Test("the footprint is measured")
    func measured() throws {
        let used = try #require(MemoryLimit.residentMegabytes())
        #expect(used > 0 && used < 1024)
    }

    @Test("passing the limit is reported")
    func overLimit() throws {
        let base = try #require(MemoryLimit.residentMegabytes())
        let tripped = Tripped()
        let limit = MemoryLimit(megabytes: base + 50) { tripped.set($0) }
        // 150 MB, touched so it is resident; bounded, freed at the end of the test.
        let block = [UInt8](repeating: 1, count: 150 * 1_048_576)
        let reason = tripped.wait(2)
        #expect(reason?.contains("over the \(base + 50) MB limit") == true, "\(reason ?? "nothing reported")")
        withExtendedLifetime((limit, block)) {}
    }

    @Test("staying under the limit reports nothing")
    func underLimit() throws {
        let base = try #require(MemoryLimit.residentMegabytes())
        let tripped = Tripped()
        let limit = MemoryLimit(megabytes: base + 500) { tripped.set($0) }
        #expect(tripped.wait(0.5) == nil)
        withExtendedLifetime(limit) {}
    }

    @Test("running past the time limit is reported")
    func overTime() {
        let tripped = Tripped()
        let limit = MemoryLimit(megabytes: 100_000, seconds: 0.2) { tripped.set($0) }
        #expect(tripped.wait(2)?.contains("ran longer than") == true)
        withExtendedLifetime(limit) {}
    }
}
