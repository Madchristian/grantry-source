import Foundation
import GrantryShared
import Testing
import TestSupport
@testable import ManagerKit

/// Start/Stopp im Tab „Dienste“: eigene Agenten ja, Schutzliste (`ProtectedProcesses.system`, TM9) nie.
@Suite struct ActionPolicyServicesTests {
    private let policy = ActionPolicy()
    private static let loginwindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    private func agent(program: String?, label: String = "com.example.agent", kind: AutostartKind = .launchAgent,
                       domain: AutostartDomain = .user) -> AutostartItem {
        AutostartItem(kind: kind, domain: domain, label: label, program: program, programPresence: .present,
                      isEnabled: true, isLoaded: true,
                      plistPath: "/Users/mara/Library/LaunchAgents/\(label).plist", owner: nil, source: .launchd)
    }

    @Test func ownAgentWithOrdinaryProgramIsControllable() {
        #expect(policy.serviceControlAvailability(for: agent(program: "/usr/local/bin/tool")) == .available)
        #expect(policy.serviceControlAvailability(for: agent(program: nil)) == .available)
    }

    @Test func otherAgentsAndDaemonsAreNotOwn() {
        let system = agent(program: "/usr/local/bin/tool", domain: .system)
        let daemon = agent(program: "/usr/local/bin/tool", kind: .launchDaemon, domain: .system)
        for item in [system, daemon] {
            #expect(policy.serviceControlAvailability(for: item) == .readOnly(.notOwnAgent))
        }
    }

    /// Ohne die Schutzliste gäbe `availability(for:)` einen Agenten mit fremdem Label frei, der ein Programm der Liste
    /// startet – die Liste prüft den Programmpfad, nicht Label oder Signatur.
    @Test func everyProgramOfTheProtectionListBlocksControl() {
        for entry in ProtectedProcesses.system.entries {
            #expect(policy.availability(for: agent(program: entry.path)) == .available, "Voraussetzung: \(entry.name)")
            #expect(policy.serviceControlAvailability(for: agent(program: entry.path)) == .readOnly(.protectedProgram),
                    "\(entry.name)")
        }
    }

    @Test func protectionListCoversOtherSpellingsOfTheSameProgram() {
        #expect(policy.serviceControlAvailability(for: agent(program: "/sbin/../sbin/launchd"))
            == .readOnly(.protectedProgram))
        // Ohne Verzeichnis sucht launchd im Standard-PATH (`LaunchdSearchPath`): `launchd` ist `/sbin/launchd`.
        #expect(policy.serviceControlAvailability(for: agent(program: "launchd")) == .readOnly(.protectedProgram))
    }

    /// Verglichen wird der Pfad, nie ein Name (wie bei „Task beenden“): Eine Kopie unter eigenem Pfad ist ein anderes
    /// Programm.
    @Test func lookalikeNamesAndPathsAreNotProtected() {
        for program in ["/Users/mara/bin/loginwindow", "/usr/local/bin/launchd", "loginwindow", "launchd-helper"] {
            #expect(policy.serviceControlAvailability(for: agent(program: program)) == .available, "\(program)")
        }
    }

    @Test func protectionNamesTheReasonEvenForAppleLabels() {
        let item = agent(program: Self.loginwindow, label: "com.apple.loginwindow")
        #expect(policy.serviceControlAvailability(for: item) == .readOnly(.protectedProgram))
    }

    @Test func protectedReasonHasGermanDescription() {
        #expect(ActionAvailability.Reason.protectedProgram.description
            == "Unverzichtbares macOS-Programm (Schutzliste) – Grantry startet und stoppt diesen Dienst nicht")
    }

    /// Die Zeilen des Tabs geben nie frei, was die Schutzliste nennt – weder als eigener Agent noch in der Domäne
    /// `system` noch ohne Plist.
    @Test func serviceRowsNeverOfferProtectedServices() {
        let own = agent(program: Self.loginwindow)
        let daemon = agent(program: "/sbin/launchd", label: "com.example.daemon", kind: .launchDaemon, domain: .system)
        let rows = ServiceListPresenter.rows(
            [.user(501): [LaunchdServiceStatus(label: own.label, pid: 41, lastExit: .never),
                          LaunchdServiceStatus(label: "com.apple.loginwindow.501", pid: 42, lastExit: .never)],
             .system: [LaunchdServiceStatus(label: daemon.label, pid: 43, lastExit: .never),
                       LaunchdServiceStatus(label: "com.apple.WindowServer", pid: 44, lastExit: .never)]],
            autostartItems: [own, daemon]
        )
        #expect(rows.map(\.isControllable) == [false, false, false, false])
        #expect(rows.map(\.controlNote) == [
            ActionAvailability.Reason.protectedProgram.description, ActionAvailability.Reason.noPlist.description,
            ActionAvailability.Reason.notOwnAgent.description, ActionAvailability.Reason.notOwnAgent.description,
        ])
        var options = ServiceListOptions()
        options.scope = .own
        #expect(ServiceListPresenter.present(rows, options: options).rows.isEmpty)
    }

    // MARK: Programm nicht sicher lokal (Codex-Review PR 356, P2)

    /// Die Schutzprüfung kanonisiert den Programmpfad (`FilePath.canonical` → `resolvingSymlinksInPath`) und träfe dabei
    /// ein hängendes Netzlaufwerk – synchron auf dem MainActor, schon beim Öffnen des Tabs. Ein Programm, das
    /// `LocalPathResolver` nicht als sicher lokal bestätigt, sperrt die Steuerung deshalb, bevor etwas aufgelöst wird.
    private static let volumes = [MountedVolume(path: "/", isLocal: true),
                                  MountedVolume(path: "/Volumes/NAS", isLocal: false)]

    @Test func programOnANetworkVolumeBlocksControl() {
        let item = agent(program: "/Volumes/NAS/bin/tool")
        #expect(policy.serviceControlAvailability(for: item, volumes: Self.volumes) == .readOnly(.unverifiableProgram))
    }

    @Test func programBehindASymlinkToANetworkVolumeBlocksControl() throws {
        try ScratchDirectory.with(prefix: "service-program") { directory in
            let link = directory.appending(path: "tools")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/NAS/tools")
            let item = agent(program: link.appending(path: "tool").path)
            #expect(policy.serviceControlAvailability(for: item, volumes: Self.volumes) == .readOnly(.unverifiableProgram))
        }
    }

    /// Ohne bekannte Einhängepunkte (Abfrage gescheitert) ist nichts sicher lokal.
    @Test func unknownMountTableBlocksControl() {
        let item = agent(program: "/usr/local/bin/tool")
        #expect(policy.serviceControlAvailability(for: item, volumes: []) == .readOnly(.unverifiableProgram))
    }

    @Test func localProgramsStayControllableAndProtectedOnesBlocked() {
        #expect(policy.serviceControlAvailability(for: agent(program: "/usr/local/bin/tool"), volumes: Self.volumes)
            == .available)
        #expect(policy.serviceControlAvailability(for: agent(program: "/sbin/../sbin/launchd"), volumes: Self.volumes)
            == .readOnly(.protectedProgram))
        #expect(policy.serviceControlAvailability(for: agent(program: "launchd"), volumes: Self.volumes)
            == .readOnly(.protectedProgram))
    }

    /// Relative Pfade mit Verzeichnisanteil sucht launchd nicht im PATH; sie hängen am Arbeitsverzeichnis des Dienstes.
    /// Vor `LaunchdSearchPath` gesetzt, landete `stat` über `..` auf dem Netzlaufwerk (Codex-Review PR 356, Befund 1) –
    /// deshalb gesperrt, ohne das Dateisystem zu fragen.
    @Test func relativeProgramWithDirectoryBlocksControlWithoutLookup() {
        for program in ["../../Volumes/NAS/bin/tool", "bin/tool", "./tool"] {
            #expect(policy.serviceControlAvailability(for: agent(program: program), volumes: Self.volumes)
                == .readOnly(.unverifiableProgram), "\(program)")
        }
    }

    @Test func serviceRowsBlockProgramsOnANetworkVolume() {
        let item = agent(program: "/Volumes/NAS/bin/tool")
        let rows = ServiceListPresenter.rows(
            [.user(501): [LaunchdServiceStatus(label: item.label, pid: nil, lastExit: .never)]],
            autostartItems: [item], policy: policy, volumes: Self.volumes
        )
        #expect(rows.map(\.isControllable) == [false])
        #expect(rows.map(\.controlNote) == [ActionAvailability.Reason.unverifiableProgram.description])
    }

    @Test func unverifiableReasonHasGermanDescription() {
        #expect(ActionAvailability.Reason.unverifiableProgram.description
            == "Programm liegt nicht sicher lokal (Netzlaufwerk oder nicht prüfbarer Pfad) – Grantry startet und stoppt "
            + "diesen Dienst nicht")
    }
}
