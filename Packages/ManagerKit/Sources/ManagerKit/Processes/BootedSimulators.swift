import Foundation
import GrantryShared

/// Ein gebooteter Simulator (#221).
public struct BootedSimulator: Identifiable, Hashable, Sendable {
    public let udid: String
    public let name: String
    /// „iOS 27.0“.
    public let runtime: String
    /// Start von `launchd_sim`; `nil`, wenn nicht gefunden.
    public let bootedAt: Date?
    /// Speicher aller Prozesse des Geräts (`launchd_sim` und Unterbaum); `nil`, wenn nicht gefunden.
    public let memoryBytes: UInt64?
    public let processCount: Int

    public var id: String { udid }
    public var title: String { "\(name) (\(runtime))" }

    /// `xcrun simctl shutdown <udid>` – offizielles CLI wie beim Speicher-Aufräumen (#215).
    var shutdownCommand: CommandSpec {
        CommandSpec.tool(BootedSimulatorReader.xcrun, ["simctl", "shutdown", udid])
    }
}

/// Liest gebootete Simulatoren über `xcrun simctl list devices booted -j` – nur, wenn es CoreSimulator-Geräte gibt
/// (sonst öffnet `/usr/bin/xcrun` ohne Xcode den Installationsdialog der Command Line Tools).
public struct BootedSimulatorReader: Sendable {
    static let xcrun = "/usr/bin/xcrun"
    static let timeout: Duration = .seconds(30)

    private let runner: any CommandRunning
    private let devicesPath: String
    private let isDirectory: @Sendable (String) -> Bool

    public init(home: String = NSHomeDirectory()) {
        self.init(runner: ProcessCommandRunner(), home: home)
    }

    init(runner: any CommandRunning, home: String,
         isDirectory: @escaping @Sendable (String) -> Bool = { FileIdentity.of($0)?.type == .directory }) {
        self.runner = runner
        devicesPath = home + "/Library/Developer/CoreSimulator/Devices"
        self.isDirectory = isDirectory
    }

    /// - Parameter entries: Prozesstabelle für Startzeit und Speicher.
    public func booted(entries: [ProcessEntry]) async throws -> [BootedSimulator] {
        guard isDirectory(devicesPath) else { return [] }
        let command = CommandSpec.tool(Self.xcrun, ["simctl", "list", "devices", "booted", "-j"])
        let result = try await runner.run(command.executable, command.arguments, timeout: Self.timeout)
        guard result.succeeded else { throw BootedSimulatorError(message: result.stderr) }
        return try Self.parse(Data(result.stdout.utf8), entries: entries)
    }

    static func parse(_ data: Data, entries: [ProcessEntry]) throws -> [BootedSimulator] {
        struct Listing: Decodable {
            struct Device: Decodable { let udid: String, name: String, state: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let children = Dictionary(grouping: entries, by: \.parentPID)
        return listing.devices.flatMap { runtime, devices in
            devices.filter { $0.state == "Booted" && UUID(uuidString: $0.udid) != nil }.map { device in
                let launcher = entries.first { entry in
                    ProcessEntry.lastComponent(entry.executablePath) == "launchd_sim"
                        && entry.arguments.contains { $0.contains("/\(device.udid)/") }
                }
                let members = launcher.map { OrphanAgentTreeDetector.subtree(of: $0, children: children) } ?? []
                return BootedSimulator(
                    udid: device.udid, name: DisplayText.singleLine(device.name), runtime: runtimeName(runtime),
                    bootedAt: launcher.map { Date(timeIntervalSince1970: TimeInterval($0.startTime) / 1_000_000) },
                    memoryBytes: launcher.map { _ in members.compactMap(\.memoryBytes).reduce(0, +) },
                    processCount: members.count
                )
            }
        }
        .sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → „iOS 27.0“.
    static func runtimeName(_ identifier: String) -> String {
        let short = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = short.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return DisplayText.singleLine(short) }
        return DisplayText.singleLine("\(platform) " + parts.dropFirst().joined(separator: "."))
    }
}

public struct BootedSimulatorError: LocalizedError, Equatable {
    let message: String

    public var errorDescription: String? {
        let line = message.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "simctl ist gescheitert" : "simctl: \(DisplayText.singleLine(line))"
    }
}
