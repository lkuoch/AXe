import Darwin
import Foundation
import Testing
@testable import AXe

/// The read broker exists to make reads cheaper. These pin the two ways it could make them dearer:
/// waiting a long time for a daemon that will never arrive, and paying that wait once per read.
@Suite("AX Broker Tests")
struct AXBrokerTests {
    @Test("A read waits far less than the HID path for a daemon that is not up")
    func readerStartupBudgetIsShort() throws {
        var spawns = 0
        var slept: UInt64 = 0
        // A clock the caller controls, so the deadline is exercised without real waiting.
        var nanoseconds: UInt64 = 0
        let budget: UInt64 = 2_000_000_000

        #expect(throws: (any Error).self) {
            _ = try HIDBroker.connectToReadyBroker(
                simulatorUDID: UUID().uuidString,
                endpoint: try makeEndpoint(),
                connector: { _ in throw HIDBrokerNotReadyError(diagnosticDescription: "refused") },
                spawner: { _ in spawns += 1 },
                sleeper: { slept &+= UInt64($0) },
                monotonicNow: {
                    nanoseconds &+= 100_000_000
                    return nanoseconds
                },
                startupBudgetNanoseconds: budget
            )
        }

        // It gave up inside its own budget rather than the HID path's 30 seconds.
        #expect(nanoseconds <= budget &+ 200_000_000)
        #expect(spawns >= 1)
    }

    @Test("A daemon that could not start is remembered, so the next read does not wait again")
    func unavailableIsRemembered() throws {
        let endpoint = try makeEndpoint()
        defer { AXBroker.clearUnavailable(endpoint: endpoint) }

        #expect(!AXBroker.isRecentlyUnavailable(endpoint: endpoint))
        AXBroker.markUnavailable(endpoint: endpoint)
        #expect(AXBroker.isRecentlyUnavailable(endpoint: endpoint))
    }

    @Test("The memory of a failure expires, so a daemon that can start is tried again")
    func unavailableExpires() throws {
        let endpoint = try makeEndpoint()
        defer { AXBroker.clearUnavailable(endpoint: endpoint) }

        AXBroker.markUnavailable(endpoint: endpoint)
        let later = Date().addingTimeInterval(600)
        #expect(!AXBroker.isRecentlyUnavailable(endpoint: endpoint, now: later))
    }

    @Test("Coming up clears a failure this endpoint recorded earlier")
    func startingClearsTheMark() throws {
        let endpoint = try makeEndpoint()
        AXBroker.markUnavailable(endpoint: endpoint)
        AXBroker.clearUnavailable(endpoint: endpoint)
        #expect(!AXBroker.isRecentlyUnavailable(endpoint: endpoint))
    }

    @Test("Its socket sits beside the HID one and stays inside the platform's path limit")
    func endpointIsDistinctAndShortEnough() throws {
        let udid = UUID().uuidString
        let hid = try HIDBroker.endpointPath(simulatorUDID: udid)
        let ax = try AXBroker.endpointPath(simulatorUDID: udid)

        #expect(ax != hid)
        // `sun_path` is 104 bytes including the terminator; a longer name binds to nothing.
        #expect(ax.utf8.count < 104)
    }

    private func makeEndpoint() throws -> String {
        try HIDBroker.endpointPath(
            simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path
        )
    }
}
