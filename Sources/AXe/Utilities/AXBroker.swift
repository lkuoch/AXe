import Darwin
import FBControlCore
import FBSimulatorControl
import Foundation

/// A persistent answerer for accessibility reads.
///
/// Measured on an iPhone 17 Pro / iOS 26.5, a `describe-ui` spends ~228ms in `getSimulatorSet` and
/// ~20ms loading private frameworks before it can read anything — per process, every time. A caller
/// driving a test makes hundreds of invocations, so that fixed cost is tens of seconds of pure
/// start-up. This holds the frameworks and the simulator set open and answers reads over a unix
/// socket, exactly the way `hid-broker` already holds an HID session.
///
/// Deliberately separate from `HIDBroker` rather than folded into it. Its frames are length-prefixed
/// because an AX tree is hundreds of kilobytes and the HID protocol caps a message at 64KB, and
/// keeping them apart means a fault in the read path can never disturb input delivery.
enum AXBroker {
    /// Bumped whenever the frames change, so a stale daemon is replaced rather than misread.
    private static let protocolVersion = 1
    /// Long enough to outlive the gaps between a test's steps, short enough not to outlive a run.
    private static let idleTimeoutMilliseconds: Int32 = 120_000
    private static let ioTimeoutMilliseconds = 30_000
    /// How long a read waits for a daemon that is not up yet, before doing the work itself.
    // A read has a fallback that costs ~300ms, so waiting the HID path's 30s is never right.
    // see: http://localhost:3030/rfcs/proposal/0038-fast-ios-runs
    private static let startupBudgetNanoseconds: UInt64 = 2_000_000_000
    /// How long a failed start is remembered, so the budget is paid once rather than per read.
    private static let unavailableForSeconds: TimeInterval = 120
    /// An AX tree is large; this is a sanity bound, not an expected size.
    private static let maximumFrameBytes = 64 * 1024 * 1024

    struct Request: Codable {
        let version: Int
        /// Serialized `FBAXKeys` raw values, so the daemon serves whatever set the caller wants.
        let keys: [String]
        /// Present for a point lookup; absent means the frontmost application.
        let x: Double?
        let y: Double?
    }

    // MARK: - Serving

    @MainActor
    static func serve(simulatorUDID: String, logger: AxeLogger) async throws {
        let endpoint = try endpointPath(simulatorUDID: simulatorUDID)
        let listener = try HIDBroker.makeListener(at: endpoint)
        let identity = try HIDBroker.socketIdentity(at: endpoint)
        defer {
            Darwin.close(listener)
            try? HIDBroker.removeOwnedSocket(endpoint, matching: identity)
        }

        // The whole point: paid once here instead of once per invocation.
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID })
        else {
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }

        // Up and holding the set: whatever failure last marked this endpoint is now stale.
        clearUnavailable(endpoint: endpoint)

        while true {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, idleTimeoutMilliseconds)
            if ready == 0 {
                return
            }

            guard ready > 0 else {
                if errno == EINTR { continue }
                throw HIDBroker.posixError("poll")
            }

            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                throw HIDBroker.posixError("accept")
            }

            HIDBroker.configureNoSignalPipe(client)
            try? HIDBroker.configureSocketTimeouts(
                client,
                readMilliseconds: ioTimeoutMilliseconds,
                writeMilliseconds: ioTimeoutMilliseconds
            )
            // The client waits for this before sending: it is how `connectToReadyBroker` tells a
            // live daemon from a socket left behind by a dead one.
            do {
                try HIDBroker.writeHandshake(ready: true, to: client)
            } catch {
                Darwin.close(client)
                continue
            }

            await answer(client: client, target: target, logger: logger)
            Darwin.close(client)
        }
    }

    @MainActor
    private static func answer(client: Int32, target: FBSimulator, logger: AxeLogger) async {
        do {
            let request = try JSONDecoder().decode(Request.self, from: try readFrame(from: client))
            guard request.version == protocolVersion else {
                try writeFrame(Data(), to: client)
                return
            }

            // A daemon that serves a different key set than the caller asked for answers wrongly
            // and silently, so an empty or unparseable set is refused rather than substituted.
            let keys = Set(request.keys.compactMap(FBAXKeys.init(rawValue:)))
            guard !keys.isEmpty else {
                try writeFrame(Data(), to: client)
                return
            }
            let point = request.x.flatMap { x in request.y.map { AccessibilityPoint(x: x, y: $0) } }
            let data = try await AccessibilityFetcher.serveFromBroker(
                target: target,
                point: point,
                keys: keys
            )
            try writeFrame(data, to: client)
        } catch {
            logger.info().log("ax-broker: request failed: \(error.localizedDescription)")
            // An empty frame is "I could not answer"; the client then does the work itself.
            try? writeFrame(Data(), to: client)
        }
    }

    // MARK: - Asking

    /// The tree as the daemon sees it, or `nil` when there is no usable daemon.
    ///
    /// Never throws for an absent or unhealthy daemon: the caller must be able to fall back to
    /// doing the read itself, because a broker that cannot answer must not fail a test.
    static func read(simulatorUDID: String, point: AccessibilityPoint?, keys: Set<FBAXKeys>) -> Data? {
        guard let endpoint = try? endpointPath(simulatorUDID: simulatorUDID) else {
            return nil
        }

        // A daemon that failed to start will fail again; without this every read in the run pays
        // the budget again, which is how a broker makes a run slower than not having one.
        // see: http://localhost:3030/rfcs/proposal/0038-fast-ios-runs
        if isRecentlyUnavailable(endpoint: endpoint) {
            return nil
        }

        guard let client = try? HIDBroker.connectToReadyBroker(
            simulatorUDID: simulatorUDID,
            endpoint: endpoint,
            connector: HIDBroker.connect(to:),
            spawner: spawn(simulatorUDID:),
            sleeper: { _ = usleep($0) },
            startupBudgetNanoseconds: startupBudgetNanoseconds
        ) else {
            markUnavailable(endpoint: endpoint)
            return nil
        }

        defer { Darwin.close(client) }
        HIDBroker.configureNoSignalPipe(client)
        try? HIDBroker.configureSocketTimeouts(
            client,
            readMilliseconds: ioTimeoutMilliseconds,
            writeMilliseconds: ioTimeoutMilliseconds
        )

        let request = Request(
            version: protocolVersion,
            keys: keys.map(\.rawValue),
            x: point?.x,
            y: point?.y
        )
        guard let encoded = try? JSONEncoder().encode(request),
              (try? writeFrame(encoded, to: client)) != nil,
              let reply = try? readFrame(from: client),
              !reply.isEmpty
        else {
            return nil
        }

        return reply
    }

    /// Its own socket beside the HID one — same private directory and ownership rules.
    // The name must not grow: a unix socket path is capped at ~104 bytes and the HID one is
    // already near it, so this swaps the version suffix rather than adding a prefix.
    static func endpointPath(simulatorUDID: String) throws -> String {
        let hid = try HIDBroker.endpointPath(simulatorUDID: simulatorUDID)
        guard hid.hasSuffix("-v2.sock") else {
            return hid + ".ax"
        }

        return String(hid.dropLast("-v2.sock".count)) + "-ax.sock"
    }

    private static func spawn(simulatorUDID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["ax-broker", "--udid", simulatorUDID]
        // All three, like `spawnBroker`: an inherited stdin makes the daemon share the caller's
        // terminal, and a caller that exits then takes the daemon's input with it.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: - Remembering a daemon that will not start

    private static func unavailableMarkerPath(endpoint: String) -> String { endpoint + ".dead" }

    static func isRecentlyUnavailable(
        endpoint: String,
        now: Date = Date(),
        attributes: (String) throws -> [FileAttributeKey: Any] =
            { try FileManager.default.attributesOfItem(atPath: $0) }
    ) -> Bool {
        guard let marked = try? attributes(unavailableMarkerPath(endpoint: endpoint)),
              let stamped = marked[.modificationDate] as? Date
        else {
            return false
        }

        return now.timeIntervalSince(stamped) < unavailableForSeconds
    }

    static func markUnavailable(endpoint: String) {
        // Recreated rather than touched: the file's mtime is the stamp the read side reads back.
        FileManager.default.createFile(
            atPath: unavailableMarkerPath(endpoint: endpoint),
            contents: Data(),
            attributes: nil
        )
    }

    static func clearUnavailable(endpoint: String) {
        try? FileManager.default.removeItem(atPath: unavailableMarkerPath(endpoint: endpoint))
    }

    // MARK: - Frames

    // Length-prefixed, because an AX tree has no natural delimiter and is far past any line cap.
    private static func writeFrame(_ payload: Data, to descriptor: Int32) throws {
        var header = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &header) { try writeAll(Data($0), to: descriptor) }
        if !payload.isEmpty {
            try writeAll(payload, to: descriptor)
        }
    }

    private static func readFrame(from descriptor: Int32) throws -> Data {
        let header = try readAll(4, from: descriptor)
        let size = Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard size <= maximumFrameBytes else {
            throw CLIError(errorDescription: "ax-broker frame of \(size) bytes is implausible")
        }

        return size == 0 ? Data() : try readAll(size, from: descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n > 0 {
                    sent += n
                    continue
                }

                if n < 0 && errno == EINTR { continue }
                throw HIDBroker.posixError("write")
            }
        }
    }

    private static func readAll(_ count: Int, from descriptor: Int32) throws -> Data {
        var out = Data(count: count)
        var read = 0
        try out.withUnsafeMutableBytes { buffer in
            while read < count {
                let n = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: read), count - read)
                if n > 0 {
                    read += n
                    continue
                }

                if n < 0 && errno == EINTR { continue }
                throw HIDBroker.posixError("read")
            }
        }

        return out
    }
}
