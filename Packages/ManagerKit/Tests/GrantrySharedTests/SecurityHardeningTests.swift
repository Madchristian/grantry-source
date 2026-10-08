import Foundation
import ObjectiveC
import Testing
@testable import GrantryShared

@Suite struct SecurityHardeningTests {
    private static let hardeningSelectors = [
        "enableFirewallWithReply:", "enableStealthModeWithReply:", "enableGatekeeperWithReply:",
        "enableAutomaticUpdatesWithReply:", "updateXProtectWithReply:",
    ]

    @Test func fixedCommandLines() {
        let lines = SecurityHardening.allCases.map { operation in operation.invocations.map(\.commandLine) }
        let domain = "/Library/Preferences/com.apple.SoftwareUpdate"
        #expect(lines == [
            ["/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"],
            ["/usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on"],
            ["/usr/sbin/spctl --global-enable"],
            ["AutomaticCheckEnabled", "AutomaticDownload", "CriticalUpdateInstall", "ConfigDataInstall", "AutomaticallyInstallMacOSUpdates"]
                .map { "/usr/bin/defaults write \(domain) \($0) -bool true" },
            ["/usr/bin/xprotect update"],
        ])
    }

    @Test func stateQueriesReadBeforeSetting() {
        let queries = SecurityHardening.allCases.map { $0.stateQuery?.invocation.commandLine }
        #expect(queries == [
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode",
            "/usr/sbin/spctl --status",
            nil, nil,
        ])
    }

    /// Nur ausgeschaltet wird gesetzt; „alle blockieren“ (`State = 2` oder eigener Block-all-Zustand) bleibt unberührt.
    @Test(arguments: [
        ("Firewall is disabled. (State = 0)\n", false),
        ("Firewall is enabled. (State = 1)\n", true),
        ("Firewall is enabled. (State = 2)\nFirewall stealth mode is on\n", true),
        ("Firewall is enabled. (State = 1)\nFirewall has block all state set to enabled.\n", true),
        ("Firewall is enabled.\n", nil),
        ("", nil),
    ] as [(String, Bool?)])
    func firewallStateQuery(_ output: String, reached: Bool?) {
        #expect(SecurityHardening.enableFirewall.stateQuery?.isTargetReached(in: output) == reached)
    }

    @Test(arguments: [
        ("Firewall stealth mode is on\n", true),
        ("Firewall stealth mode is off\n", false),
        ("Stealth?\n", nil),
    ] as [(String, Bool?)])
    func stealthModeStateQuery(_ output: String, reached: Bool?) {
        #expect(SecurityHardening.enableStealthMode.stateQuery?.isTargetReached(in: output) == reached)
    }

    /// Nur ausgeschaltet wird gesetzt; unbekannte Ausgabe bricht ab.
    @Test(arguments: [
        ("assessments enabled\n", true),
        ("assessments disabled\n", false),
        ("assessments maybe\n", nil),
    ] as [(String, Bool?)])
    func gatekeeperStateQuery(_ output: String, reached: Bool?) {
        #expect(SecurityHardening.enableGatekeeper.stateQuery?.isTargetReached(in: output) == reached)
    }

    /// Längste Laufzeit im Helper: (Befehlsfrist + Gnadenfrist des Runners) je Befehl, Zustandsabfrage eingeschlossen.
    @Test func maximumDurationCoversEveryCommandIncludingTheQuery() {
        #expect(SecurityHardening.enableFirewall.maximumDuration == .seconds(64))
        #expect(SecurityHardening.enableGatekeeper.maximumDuration == .seconds(64))
        #expect(SecurityHardening.enableAutomaticUpdates.maximumDuration == .seconds(160))
        #expect(SecurityHardening.updateXProtect.maximumDuration == .seconds(122))
    }

    @Test func executablesAreAbsolutePaths() {
        for operation in SecurityHardening.allCases {
            for invocation in operation.invocations + [operation.stateQuery?.invocation].compactMap(\.self) {
                #expect(invocation.executable.hasPrefix("/"), "\(operation): \(invocation.executable)")
            }
        }
    }

    /// Spec v2: Es gibt keinen Codepfad, der eine Schutzfunktion abschaltet.
    @Test func noInvocationWeakensProtection() {
        for operation in SecurityHardening.allCases {
            let invocations = operation.invocations + [operation.stateQuery?.invocation].compactMap(\.self)
            for argument in invocations.flatMap(\.arguments) {
                for forbidden in ["off", "false", "disable", "delete", "remove"] {
                    #expect(!argument.lowercased().contains(forbidden), "\(operation): \(argument)")
                }
            }
        }
    }

    /// Das XPC-Protokoll bietet genau die bekannten Methoden an – keine zum Abschalten, und die absichernden sind
    /// parameterlos (einziges Argument ist der Reply-Block).
    @Test func xpcProtocolOffersNoWeakeningOperation() {
        let names = Self.selectorNames(of: GrantryHelperXPC.self, isRequired: true)
        // Abschließende Liste: Jede neue XPC-Methode muss hier bewusst ergänzt werden.
        #expect(Set(names) == Set(Self.hardeningSelectors + [
            "protocolVersionWithReply:", "dumpBTMWithReply:", "setEnabledWithPlistPath:enabled:reply:",
            "bootoutWithPlistPath:reply:", "bootstrapWithPlistPath:reply:", "unloadAndRemovePlistWithPath:expectedFingerprint:reply:",
            "restorePlistWithBackupPath:reply:", "listListeningSocketsWithReply:",
            "terminateProcessWithPid:executablePath:startTime:force:reply:",
        ]))
        #expect(Self.selectorNames(of: GrantryHelperXPC.self, isRequired: false).isEmpty)
        #expect(!names.contains { $0.lowercased().contains("disable") || $0.contains("Off") })
        for name in Self.hardeningSelectors {
            #expect(name.filter { $0 == ":" }.count == 1, "\(name)")
        }
    }

    @Test func xprotectUpdateHasLongerTimeout() {
        #expect(SecurityHardening.updateXProtect.timeout == .seconds(120))
        for operation in SecurityHardening.allCases where operation != .updateXProtect {
            #expect(operation.timeout == .seconds(30))
        }
    }

    private static func selectorNames(of proto: Protocol, isRequired: Bool) -> [String] {
        var count: UInt32 = 0
        guard let methods = protocol_copyMethodDescriptionList(proto, isRequired, true, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count)).compactMap { methods[$0].name.map(NSStringFromSelector) }
    }
}
