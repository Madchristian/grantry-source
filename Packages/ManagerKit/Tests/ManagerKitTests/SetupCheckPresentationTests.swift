import Testing
import ManagerKit

/// Einrichtung als Prüfzeilen in den Einstellungen (LB-5.2, #553; Spec 2026-11-10 § 11.5 c und e): Grund in einem Satz,
/// kurzer Zustand für den Chip, Kopf des Panels und die beim Öffnen aufgeklappte Zeile.
@Suite struct SetupCheckPresentationTests {
    private static let complete = SetupStatus(
        fullDiskAccess: true, helper: .ready, notifications: .authorized, launchAtLogin: .enabled
    )

    @Test func reasonIsTheFirstSentenceAndTheRestStaysForTheExpandedRow() {
        #expect(SetupStep.helper.reason
            == "Liest die Hintergrundobjekte des Systems und führt Aktionen mit Administratorrechten aus.")
        #expect(SetupStep.helper.furtherExplanation
            == "Er nimmt nur Verbindungen von Administratoren an; die Genehmigung erfordert ein Administratorkonto.")
        #expect(SetupStep.notifications.reason == SetupStep.notifications.explanation)
        #expect(SetupStep.notifications.furtherExplanation == nil)
        for step in SetupStep.allCases {
            let joined = [step.reason, step.furtherExplanation].compactMap { $0 }.joined(separator: " ")
            #expect(joined == step.explanation, "Text von \(step) geht verloren")
        }
    }

    @Test func longStatesGetAShortChipAndKeepTheFullTextForTheExpandedRow() throws {
        let awaiting = try #require(SetupChecklist(SetupStatus(helper: .awaitingApproval)).item(for: .helper))
        #expect(awaiting.chipText == "Wartet auf Genehmigung")
        #expect(awaiting.detailText == awaiting.text)
        let approval = try #require(SetupChecklist(SetupStatus(launchAtLogin: .requiresApproval))
            .item(for: .launchAtLogin))
        #expect(approval.chipText == "Muss erlaubt werden")
        #expect(approval.detailText == "Muss unter „Anmeldeobjekte & Erweiterungen“ erlaubt werden")
        let unreachable = try #require(SetupChecklist(SetupStatus(helper: .unreachable("Zeitüberschreitung")))
            .item(for: .helper))
        #expect(unreachable.chipText == "Nicht erreichbar")
        #expect(unreachable.detailText == "Nicht erreichbar: Zeitüberschreitung")
        let ready = try #require(SetupChecklist(Self.complete).item(for: .helper))
        #expect(ready.chipText == "Bereit")
        #expect(ready.detailText == nil)
    }

    @Test func headWhileReadingCompleteAndOpen() {
        let reading = SetupChecklist(SetupStatus())
        #expect(reading.panelDetail == "Zustand wird gelesen …")
        #expect(reading.panelValue == "")
        #expect(!reading.hasOpenSteps)

        let complete = SetupChecklist(Self.complete)
        #expect(complete.panelDetail == "4 von 4 erledigt")
        #expect(complete.panelValue == "")
        #expect(!complete.hasOpenSteps)

        let missing = SetupChecklist(SetupStatus(fullDiskAccess: false, helper: .notInstalled,
                                                 notifications: .notDetermined, launchAtLogin: .disabled))
        #expect(missing.panelDetail == "0 von 4 erledigt · 2 kritisch")
        #expect(missing.panelValue == "4 offen")
        #expect(missing.hasOpenSteps)

        let blocked = SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .requiresAdministrator,
                                                 notifications: .authorized, launchAtLogin: .enabled))
        #expect(blocked.panelDetail == "3 von 4 erledigt · 1 kritisch")
        #expect(blocked.panelValue == "1 offen")
    }

    @Test func leadingStepPrefersMissingRequiredSteps() {
        #expect(SetupChecklist(SetupStatus()).leadingStep == nil)
        #expect(SetupChecklist(Self.complete).leadingStep == nil)
        let optionalOnly = SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .ready,
                                                      notifications: .denied, launchAtLogin: .disabled))
        #expect(optionalOnly.leadingStep == .notifications)
        let helperBlocked = SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .requiresAdministrator,
                                                       notifications: .notDetermined))
        #expect(helperBlocked.leadingStep == .helper)
        let missing = SetupChecklist(SetupStatus(fullDiskAccess: false, helper: .notInstalled))
        #expect(missing.leadingStep == .fullDiskAccess)
    }
}
