import Foundation
import FBControlCore
import FBSimulatorControl

/// The set this process already built, per device-set path.
///
/// `FBSimulatorControl.withConfiguration` costs ~223ms, and several commands ask for the set more
/// than once — resolving the target, then establishing HID. Measured over one run: 503 calls across
/// 348 invocations, so about 155 of them were the second call in a process that already had it.
/// The set cannot change inside one short-lived invocation, so the second call is pure waste.
private actor SimulatorSetCache {
    static let shared = SimulatorSetCache()
    private var sets: [String: FBSimulatorSet] = [:]

    func set(for path: String?, build: () throws -> FBSimulatorSet) throws -> FBSimulatorSet {
        // A nil path is the default set, and "" is not a legal path, so it cannot collide.
        let key = path ?? ""
        if let cached = sets[key] {
            return cached
        }

        let built = try build()
        sets[key] = built
        return built
    }
}

// MARK: - Utility Functions
func getSimulatorSet(
    deviceSetPath: String?,
    logger: AxeLogger,
    reporter: FBEventReporter
) async throws -> FBSimulatorSet {
    do {
        return try await SimulatorSetCache.shared.set(for: deviceSetPath) {
            let configuration = FBSimulatorControlConfiguration(
                deviceSetPath: deviceSetPath,
                logger: logger,
                reporter: reporter
            )

            return try FBSimulatorControl.withConfiguration(configuration).set
        }
    } catch {
        logger.info().log("FBSimulatorControl failed to initialize.")
        throw error
    }
} 
