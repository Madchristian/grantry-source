import GrantryShared

/// Liefert die Systemerweiterungen; in Tests ersetzbar.
public protocol SystemExtensionListing: Sendable {
    func systemExtensions() async throws -> SystemExtensionList
}

/// Systemerweiterungen über `systemextensionsctl list` (ohne Root, ohne Helper).
public struct SystemExtensionReader: SystemExtensionListing {
    static let command = ExtensionCommand(
        executable: "/usr/bin/systemextensionsctl", arguments: ["list"], timeout: .seconds(5), outputLimit: 1 << 20
    )

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func systemExtensions() async throws -> SystemExtensionList {
        try await Self.command.run(with: runner, parse: SystemExtensionListParser.parse)
    }
}
