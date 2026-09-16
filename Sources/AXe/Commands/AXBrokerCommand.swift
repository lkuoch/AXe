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

        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await AXBroker.serve(simulatorUDID: simulatorUDID, logger: logger)
    }
}
