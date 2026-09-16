import ArgumentParser
import Foundation
import AppKit
import FBControlCore // Ensure FBControlCore is imported for AxeLogger if it's defined there
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct Axe: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let axeLogger = AxeLogger() // Corrected initializer

    // Names every timing line after the subcommand that produced it, and reports the whole
    // invocation so the per-phase split always has a total to be read against.
    static func main() async {
        PhaseTiming.command = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "axe"
        await PhaseTiming.measuringProcess {
            await Self.main(nil)
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
        version: VERSION,
        subcommands: [
            DescribeUI.self,
            ListSimulators.self,
            Init.self,
            Tap.self,
            Slider.self,
            Type.self,
            Swipe.self,
            Drag.self,
            Button.self,
            Key.self,
            KeySequence.self,
            KeyCombo.self,
            Touch.self,
            Gesture.self,
            StreamVideo.self,
            RecordVideo.self,
            Screenshot.self,
            Batch.self,
            HIDBrokerCommand.self,
            AXBrokerCommand.self
        ]
    )
}
