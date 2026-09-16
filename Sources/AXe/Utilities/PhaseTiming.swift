import Foundation
import FBControlCore

/// Where an invocation's time actually went, as one JSON line per phase on stderr.
///
/// Most of an `axe` invocation is not the work it was asked to do — it is loading Xcode's private
/// frameworks, enumerating the simulator set, and establishing an HID session, all of which happen
/// again for every process. Callers driving hundreds of invocations need that split to be
/// measurable rather than inferred, so each phase reports itself:
///
///     {"axe":"timing","command":"describe-ui","phase":"globalSetup","ms":281.4}
///
/// Off unless `AXE_TIMING=1`, and written to stderr so it can never contaminate a command's stdout
/// (`describe-ui` puts JSON there, and callers parse it).
enum PhaseTiming {
    private static let enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["AXE_TIMING"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return value == "1" || value == "true" || value == "yes"
    }()

    /// Whether timing is on, so a caller can ask the AX layer for its own profile as well.
    static var isEnabled: Bool { enabled }

    /// The AX layer's own account of a read: how many elements it walked, how many attribute
    /// fetches that cost, and how much of it went over XPC. Each attribute of each element is a
    /// separate fetch, so this is what says whether a read is expensive because of the tree's size
    /// or the number of keys asked of it.
    static func report(_ profile: FBAccessibilityProfilingData?) {
        guard enabled, let profile else {
            return
        }

        let line = [
            "{\"axe\":\"axprofile\"",
            "\"command\":\"\(escape(command))\"",
            "\"elements\":\(profile.elementCount)",
            "\"attributeFetches\":\(profile.attributeFetchCount)",
            "\"xpcCalls\":\(profile.xpcCallCount)",
            "\"xpcMs\":\(String(format: "%.1f", profile.totalXPCDuration * 1000))",
            "\"translationMs\":\(String(format: "%.1f", profile.translationDuration * 1000))}",
        ].joined(separator: ",")

        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// Marks a read the daemon answered. Its absence means the caller did the read itself.
    static func reportBrokerServed(bytes: Int) {
        guard enabled else {
            return
        }

        let line = [
            "{\"axe\":\"axbrokerserved\"",
            "\"command\":\"\(escape(command))\"",
            "\"bytes\":\(bytes)}",
        ].joined(separator: ",")

        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// Whether the daemon's answer matched a direct read taken moments later, and by how much.
    ///
    /// Equal bytes with different content is the interesting case: the same tree, serialized
    /// differently (AXe emits object keys in a varying order), which is NOT staleness. A different
    /// length is a genuinely different screen.
    static func reportBrokerAgreement(broker: Data, direct: Data) {
        guard enabled else {
            return
        }

        // `sameLength` is the signal. `identical` is almost always false even for one unchanged
        // screen, because the key order varies per read, so it must not be read as disagreement.
        let line = [
            "{\"axe\":\"axbrokeragree\"",
            "\"command\":\"\(escape(command))\"",
            "\"sameLength\":\(broker.count == direct.count)",
            "\"identical\":\(broker == direct)",
            "\"brokerBytes\":\(broker.count)",
            "\"directBytes\":\(direct.count)}",
        ].joined(separator: ",")

        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// The subcommand being timed, set once at start-up so every phase line can name it.
    nonisolated(unsafe) static var command: String = "axe"

    /// Time `body`, report it, and return whatever it returned. A throwing body is still reported,
    /// marked `failed`, because a phase that died slowly is exactly what a caller wants to see.
    static func measure<T>(_ phase: String, _ body: () async throws -> T) async rethrows -> T {
        guard enabled else {
            return try await body()
        }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await body()
            emit(phase: phase, started: started, failed: false)
            return result
        } catch {
            emit(phase: phase, started: started, failed: true)
            throw error
        }
    }

    /// The synchronous twin, for a phase that is not `async`.
    static func measureSync<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else {
            return try body()
        }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try body()
            emit(phase: phase, started: started, failed: false)
            return result
        } catch {
            emit(phase: phase, started: started, failed: true)
            throw error
        }
    }

    /// Wraps the whole process. `body` normally exits rather than returning, so the total is also
    /// reported from an `atexit` hook — ArgumentParser calls `exit()` on success and on failure.
    static func measuringProcess(_ body: () async -> Void) async {
        guard enabled else {
            return await body()
        }

        processStarted = DispatchTime.now().uptimeNanoseconds
        atexit {
            PhaseTiming.emit(phase: "total", started: PhaseTiming.processStarted, failed: false)
        }
        await body()
    }

    nonisolated(unsafe) private static var processStarted: UInt64 = DispatchTime.now().uptimeNanoseconds

    private static func emit(phase: String, started: UInt64, failed: Bool) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let line = [
            "{\"axe\":\"timing\"",
            "\"command\":\"\(escape(command))\"",
            "\"phase\":\"\(escape(phase))\"",
            "\"ms\":\(String(format: "%.1f", elapsed))",
            "\"failed\":\(failed)}",
        ].joined(separator: ",")

        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    // A phase name is ours and a command name is argv, so neither should ever break the JSON.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
