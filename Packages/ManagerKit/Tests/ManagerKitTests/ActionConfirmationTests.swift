import Foundation
import Testing
@testable import ManagerKit

@Suite struct ActionConfirmationTests {
    @Test func resetExplainsTheRepeatedPrompt() {
        let confirmation = ActionConfirmation.reset(TestData.grant())
        #expect(confirmation.title == "Kamera-Berechtigung von us.zoom.xos zurücksetzen?")
        #expect(confirmation.message == "Die App fragt beim nächsten Zugriff erneut nach.")
        #expect(confirmation.note == nil)
        #expect(confirmation.confirmTitle == "Zurücksetzen" && confirmation.isDestructive)
    }

    // #192: Auch beim Zurücksetzen einer konkreten Ziel-Zeile gilt der Hinweis für die ganze App.
    @Test(arguments: [nil, "com.apple.finder", "com.apple.systemevents"] as [String?])
    func automationResetWarnsThatAllTargetsAreReset(target: String?) {
        var grant = TestData.grant("kTCCServiceAppleEvents")
        grant.target = target
        let confirmation = ActionConfirmation.reset(grant)
        #expect(confirmation.title == "Automation-Berechtigung von us.zoom.xos zurücksetzen?")
        #expect(confirmation.message == "Die App fragt beim nächsten Zugriff erneut nach.")
        #expect(confirmation.note?.hasPrefix("Setzt alle Automation-Freigaben dieser App zurück.") == true)
        if let target { #expect(confirmation.note?.contains(target) == true) }
        #expect(confirmation.confirmTitle == "Zurücksetzen" && confirmation.isDestructive)
    }

    @Test func automationResetListsEveryKnownTargetForTheSameClient() throws {
        var selected = TestData.grant("kTCCServiceAppleEvents")
        selected.target = "com.apple.finder"
        var second = selected
        second.target = "com.apple.systemevents"
        var unknown = selected
        unknown.target = nil
        var other = TestData.grant("kTCCServiceAppleEvents", client: TestData.app("other.app"))
        other.target = "other.target"
        let confirmation = ActionConfirmation.reset(selected, knownGrants: [second, selected, selected, unknown, other])
        let note = try #require(confirmation.note)
        #expect(note.contains("Setzt alle Automation-Freigaben dieser App zurück."))
        #expect(note.contains("com.apple.finder, com.apple.systemevents"))
        #expect(!note.contains("other.target"))
        #expect(note.contains("Weitere Ziele können Grantry unbekannt sein."))
        #expect(ActionConfirmation.reset(TestData.grant(), knownGrants: [selected]).note == nil)
    }

    @Test func automationResetDoesNotTruncateTargetsAcrossScopes() throws {
        let grants = (1...20).map { index in
            var grant = TestData.grant("kTCCServiceAppleEvents", scope: index.isMultiple(of: 2) ? .system : .user)
            grant.target = "target-\(index)"
            return grant
        }
        let note = try #require(ActionConfirmation.reset(grants[0], knownGrants: grants).note)
        for grant in grants { #expect(note.contains(grant.target ?? "missing-target")) }
    }

    @Test func serviceResetNamesRemovedAndAffectedApps() throws {
        let orphan = TestData.grant("kTCCServiceAccessibility", client: TestData.app("ai.gone", presence: .missing), scope: .system)
        let installed = TestData.grant("kTCCServiceAccessibility", client: TestData.app("com.vendor.tool"), scope: .system)
        let grantry = TestData.grant("kTCCServiceAccessibility", client: TestData.app("de.cstrube.Grantry"), scope: .system)
        let reset = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [orphan, installed, grantry])))
        let confirmation = ActionConfirmation.resetService(reset, ownBundleID: "de.cstrube.Grantry")
        #expect(confirmation.title == "Bedienungshilfen für alle Apps zurücksetzen?")
        #expect(confirmation.message == "macOS entfernt Berechtigungen gelöschter Apps nur, wenn Bedienungshilfen für alle Apps "
            + "zurückgesetzt wird. Entfernt werden die Einträge von: ai.gone.")
        let note = try #require(confirmation.note)
        #expect(note.hasPrefix("Auch diese 2 Apps verlieren die Berechtigung: com.vendor.tool, de.cstrube.Grantry."))
        #expect(note.contains("Auch Grantry selbst verliert diese Berechtigung."))
        #expect(note.contains("Laufende Apps verlieren den Zugriff sofort."))
        #expect(confirmation.confirmTitle == "Für alle Apps zurücksetzen" && confirmation.isDestructive)
        #expect(!(ActionConfirmation.resetService(reset, ownBundleID: "other").note ?? "").contains("Grantry selbst"))
    }

    @Test func serviceResetListsAtMostTwelveNames() {
        let names = (1...14).map { "App \($0)" }
        #expect(ActionConfirmation.list(names).hasSuffix("App 12 und 2 weitere"))
        #expect(ActionConfirmation.list(["A", "B"]) == "A, B")
    }

    @Test func setEnabledTexts() {
        let item = TestData.item("com.vendor.agent", owner: TestData.app("com.vendor"))
        let disable = ActionConfirmation.setEnabled(item, false)
        #expect(disable.title == "„com.vendor.agent“ (com.vendor) deaktivieren?")
        #expect(disable.confirmTitle == "Deaktivieren" && !disable.isDestructive)
        let enable = ActionConfirmation.setEnabled(TestData.item("x"), true)
        #expect(enable.title == "„x“ aktivieren?" && enable.confirmTitle == "Aktivieren")
    }

    @Test func removeMentionsTheBackup() {
        let confirmation = ActionConfirmation.remove(TestData.item("x"))
        #expect(confirmation.title == "„x“ entfernen?")
        #expect(confirmation.note == "Die Plist wird vorher gesichert und lässt sich im Verlauf wiederherstellen.")
        #expect(confirmation.confirmTitle == "Entfernen" && confirmation.isDestructive)
    }

    @Test func restoreNamesTheEntry() {
        let receipt = RemovalReceipt(label: "x", backupPath: "/b", isPrivileged: false, wasEnabled: false, wasLoaded: false)
        let entry = ReceiptEntry(id: UUID(), receipt: receipt, label: "X-Agent", removedAt: TestData.date, eventID: nil)
        let confirmation = ActionConfirmation.restore(entry)
        #expect(confirmation.title == "„X-Agent“ wiederherstellen?")
        #expect(confirmation.note == "Der Eintrag war vor dem Entfernen deaktiviert und bleibt es.")
        #expect(!confirmation.isDestructive)
    }

    // MARK: Prozess beenden

    private static let terminationRequest = ProcessTerminationRequest(
        listener: TestData.listener(),
        processes: [
            RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1),
            RunningProcess(pid: 4243, uid: 0, executablePath: "/opt/homebrew/bin/node", startTime: 1),
        ]
    )

    @Test func terminateNamesProgramPortReachabilityAndProcesses() {
        let confirmation = ActionConfirmation.terminate(Self.terminationRequest, currentUID: 501)
        #expect(confirmation.title == "„node“ beenden?")
        #expect(confirmation.message == """
            Programm: /opt/homebrew/bin/node
            Port 3000/tcp, alle Schnittstellen
            Prozesse: PID 4242 (Eigener Benutzer), PID 4243 (System (root))
            """)
        #expect(confirmation.note == "Der Dienst kann über seinen Autostart-Eintrag bzw. die App erneut starten. "
            + "Grantry blockiert ihn nicht dauerhaft.")
        #expect(confirmation.confirmTitle == "Beenden" && confirmation.isDestructive)
    }

    @Test func forceTerminateWarnsAboutDataLoss() {
        let confirmation = ActionConfirmation.forceTerminate(Self.terminationRequest, currentUID: 501)
        #expect(confirmation.title == "„node“ sofort beenden (SIGKILL)?")
        #expect(confirmation.message == "Diese Prozesse haben auf die Aufforderung zum Beenden nicht reagiert: "
            + "PID 4242 (Eigener Benutzer), PID 4243 (System (root)).")
        #expect(confirmation.note?.hasPrefix("Die Prozesse enden ohne Aufräumen und können ungesicherte Daten verlieren.") == true)
        #expect(confirmation.confirmTitle == "Sofort beenden" && confirmation.isDestructive)
    }

    @Test func manyProcessesAreShortened() {
        let processes = (1...20).map {
            RunningProcess(pid: Int32(1000 + $0), uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)
        }
        let confirmation = ActionConfirmation.terminate(ProcessTerminationRequest(listener: TestData.listener(), processes: processes),
                                                        currentUID: 501)
        #expect(confirmation.message?.hasSuffix("und 8 weitere") == true)
    }
}
