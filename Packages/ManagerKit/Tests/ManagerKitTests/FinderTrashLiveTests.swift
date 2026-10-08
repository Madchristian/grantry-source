import Foundation
import Testing
@testable import ManagerKit

private let finderSmokeLeftoverPath = ProcessInfo.processInfo.environment["MANAGERKIT_FINDER_SMOKE"]

/// Smoke-Test gegen den echten Finder (#115): ein root-eigener Wegwerf-Rest unter `/Library/Application Support` geht
/// über den Weg der App (`RemovalGuard`, `FinderTrash`) in den Papierkorb. Der Finder fragt dabei nach dem Passwort.
///
/// Klärt, was `FinderTrash` für root-eigene Einträge annimmt: Der Finder verschiebt per Umbenennen (Inode bleibt), und
/// der Bericht meldet „im Papierkorb“ (`.trashed`) statt `vanishedReason`. Läuft nur über `scripts/smoke/finder-root-leftover.sh`,
/// das den Rest per `sudo` anlegt und den Pfad in `MANAGERKIT_FINDER_SMOKE` übergibt.
@Suite(.enabled(if: finderSmokeLeftoverPath != nil))
struct FinderTrashLiveTests {
    @Test func rootOwnedLeftoverIsMovedToTheTrashByRenaming() async throws {
        let path = try #require(finderSmokeLeftoverPath)
        let removalGuard = RemovalGuard()
        guard case .allowed(let identity) = removalGuard.inspect(path, appleOwnerID: nil) else {
            Issue.record("RemovalGuard lehnt \(path) ab: \(removalGuard.check(path))")
            return
        }
        let owner = try FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? Int
        #expect(owner == 0, "Der Rest muss root gehören, sonst fragt der Finder nicht nach dem Passwort")

        let trash = FinderTrash()
        #expect(await trash.requestPermission() == .granted, "Automation-Freigabe für den Finder fehlt")
        let candidate = LeftoverCandidate(path: path, kind: .applicationSupport, confidence: .safe, identity: identity)
        let report = await trash.moveToTrash([candidate]) { removalGuard.check($0, allowingAppleIDOf: nil) }
        print("Bericht: \(report)")

        #expect(report.failure == nil)
        #expect(report.outcomes[path] == .trashed)
        // Ohne Nachweis fiele `FinderTrash` auf den Pfad zurück – die Frage aus #115 wäre dann nicht beantwortet.
        switch FSGetPathLocator().locate(identity) {
        case .found(let trashedPath, _):
            print("Im Papierkorb unter \(trashedPath) (Inode \(identity.inode) unverändert)")
            #expect(FinderTrash.isInTrashFolder(trashedPath))
        case .gone:
            Issue.record("Original nirgends mehr – der Finder hat kopiert oder sofort gelöscht")
        case .unknown:
            Issue.record("Ort nicht ermittelbar – das Terminal braucht Festplattenvollzugriff, um ~/.Trash zu durchsuchen")
        }
    }
}
