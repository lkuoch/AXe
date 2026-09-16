import ArgumentParser
import Darwin
import FBControlCore

struct AXBrokerCommand: AsyncParsableCommand {
    // Hidden like `hid-broker`: an implementation detail the client spawns, not a public command.
    static let configuration = CommandConfiguration(
        commandName: "ax-broker",
        shouldDisplay: false
    )

    @Option(name: .customLong("udid"))
    var simulatorUDID: String

    func run() async throws {
        let endpoint = try AXBroker.endpointPath(simulatorUDID: simulatorUDID)
        let lifetimeLock = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        defer {
            _ = flock(lifetimeLock, LOCK_UN)
            Darwin.close(lifetimeLock)
        }

        // Holding the lifetime lock means no other daemon is alive, so any socket still sitting at
        // the endpoint belongs to a dead one. Without this the bind fails with EADDRINUSE and no
        // daemon can ever start again — every read then falls back to doing the work itself, which
        // is silent, so the cache simply stops existing and nothing says so.
        try? HIDBroker.removeOwnedSocket(endpoint)

        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await AXBroker.serve(simulatorUDID: simulatorUDID, logger: logger)
    }
}
