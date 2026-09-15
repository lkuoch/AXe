import Foundation

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
