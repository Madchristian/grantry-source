import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// #97: Dieselbe Bundle-ID mehrfach installiert – Einträge der anderen Installation gehören nicht zur entfernten App,
/// gemeinsam wirkende Aktionen sind nicht vorausgewählt.
@Suite struct AppLinksDuplicateTests {
    private let real = TestData.installedApp("Tool", bundleID: "com.example.tool", path: "/Applications/Tool.app")
    private let decoy = TestData.installedApp("Tool", bundleID: "com.example.tool", path: "/Users/test/Applications/Tool.app",
                                              signing: SigningInfo(kind: .unsigned), location: .userApplications)

    /// Eigentümer nur über die Bundle-ID bekannt (z. B. `AssociatedBundleIdentifiers` ohne Auflösung).
    private let bundleOnly = AppIdentity(bundleID: "com.example.tool", path: nil, displayName: "Tool", signing: .unknown,
                                         presence: .present)

    private func agent(_ label: String, owner: AppIdentity?, program: String?) -> AutostartItem {
        var item = TestData.item(label, owner: owner)
        item.program = program
        return item
    }

    private func review(_ links: AppLinks) -> RemovalReview {
        RemovalReview(leftovers: LeftoverScanResult(candidates: []), links: links, home: "/Users/test")
    }

    // MARK: Täuschungskopie

    @Test func decoyCopyDoesNotGetEntriesWhoseProgramLiesInTheRealApp() {
        let grant = TestData.grant(client: real.identity)
        let daemon = agent("com.example.tool.daemon", owner: real.identity, program: "/Library/PrivilegedHelperTools/tool")
        let embedded = agent("com.example.tool.helper", owner: bundleOnly,
                             program: "/Applications/Tool.app/Contents/Library/LaunchServices/helper")
        let snapshot = TestData.appSnapshot([real, decoy], grants: [grant], items: [daemon, embedded])

        let links = AppLinks.of(decoy, in: snapshot)
        #expect(links.grants == [grant], "per Bundle-ID aufgelöster Eigentümerpfad belegt nichts – gemeinsam, nicht Konflikt")
        #expect(links.autostartItems == [daemon], "Programmpfad in der echten App – Konflikt statt Treffer")
        #expect(links.sharedIDs == [grant.id, daemon.id])
        #expect(review(links).initialSelection.selected.isEmpty, "nichts davon vorausgewählt")
    }

    /// Review: Löst Launch Services die Bundle-ID auf die Kopie auf, bleiben die Einträge beim Entfernen der **echten**
    /// App sichtbar (gemeinsam, nicht vorausgewählt) statt als Konflikt zu verschwinden.
    @Test func ownerResolvedToTheCopyStaysVisibleForTheRealApp() {
        let grant = TestData.grant(client: decoy.identity)
        let daemon = agent("com.example.tool.daemon", owner: decoy.identity, program: "/Library/PrivilegedHelperTools/tool")
        let snapshot = TestData.appSnapshot([real, decoy], grants: [grant], items: [daemon])

        let links = AppLinks.of(real, in: snapshot)
        #expect(links.grants == [grant])
        #expect(links.autostartItems == [daemon])
        #expect(links.sharedIDs == [grant.id, daemon.id])
        #expect(review(links).initialSelection.selected.isEmpty)
        #expect(review(links).sharedNotice == RemovalReview.sharedNotice)
    }

    @Test func entriesOfTheRealAppStayButAreNotPreselectedWhileACopyExists() {
        let grant = TestData.grant(client: real.identity)
        let daemon = agent("com.example.tool.daemon", owner: real.identity, program: "/Library/PrivilegedHelperTools/tool")
        let embedded = agent("com.example.tool.helper", owner: bundleOnly,
                             program: "/Applications/Tool.app/Contents/Library/LaunchServices/helper")
        let snapshot = TestData.appSnapshot([real, decoy], grants: [grant], items: [daemon, embedded])

        let links = AppLinks.of(real, in: snapshot)
        #expect(links.grants == [grant])
        #expect(links.autostartItems == [daemon, embedded])
        #expect(links.sharedIDs == [grant.id, daemon.id], "beide träfen auch die Kopie (TCC und Label je Bundle-ID)")
        #expect(links.otherInstallations == [decoy])

        let review = review(links)
        #expect(review.initialSelection.selected == [embedded.id], "nur das Programm im eigenen Bundle ist eindeutig")
        #expect(review.note(for: grant.id) == "Gehört evtl. auch zu: Tool (~/Applications/Tool.app)")
        #expect(review.note(for: embedded.id) == nil)
    }

    // MARK: Echte Zweitinstallation

    @Test func secondInstallationSharesBundleIDEntriesWithoutPreselection() {
        let second = TestData.installedApp("Tool 2", bundleID: "com.example.tool", path: "/Applications/Old/Tool.app")
        let grant = TestData.grant(client: second.identity)
        let snapshot = TestData.appSnapshot([real, second], grants: [grant])

        let links = AppLinks.of(second, in: snapshot)
        #expect(links.grants == [grant])
        #expect(links.sharedIDs == [grant.id])
        #expect(links.otherInstallations == [real])
        #expect(review(links).initialSelection.selected.isEmpty)
        #expect(review(links).note(for: grant.id) == "Gehört evtl. auch zu: Tool (/Applications/Tool.app)")
        #expect(AppLinks.of(real, in: snapshot).sharedIDs == [grant.id], "Client nach Bundle-ID trifft beide")
    }

    @Test func grantOfAPathClientIsExclusiveToItsInstallation() {
        let byPath = PermissionGrant(service: "kTCCServiceCamera", client: decoy.identity, authValue: .allowed, scope: .user,
                                     lastModified: TestData.date, clientID: decoy.path)
        let snapshot = TestData.appSnapshot([real, decoy], grants: [byPath])

        let links = AppLinks.of(decoy, in: snapshot)
        #expect(links.grants == [byPath])
        #expect(links.sharedIDs.isEmpty, "TCC-Eintrag nach Pfad trifft nur diese Installation")
        #expect(AppLinks.of(real, in: snapshot).grants.isEmpty)
    }

    // MARK: Eintrag ohne Pfad

    @Test func entryWithoutPathIsPreselectedOnlyForASingleInstallation() {
        let grant = TestData.grant(client: bundleOnly)
        let item = agent("com.example.tool.agent", owner: bundleOnly, program: nil)

        let single = AppLinks.of(real, in: TestData.appSnapshot([real], grants: [grant], items: [item]))
        #expect(single == AppLinks(grants: [grant], autostartItems: [item]))
        #expect(review(single).initialSelection.selected == [grant.id, item.id])
        #expect(review(single).sharedNotice == nil)

        let both = AppLinks.of(decoy, in: TestData.appSnapshot([real, decoy], grants: [grant], items: [item]))
        #expect(both.grants == [grant])
        #expect(both.autostartItems == [item])
        #expect(both.sharedIDs == [grant.id, item.id])
        #expect(review(both).initialSelection.selected.isEmpty)
    }

    @Test func indexMatchesAppLinksWithDuplicates() {
        let grants = [TestData.grant(client: real.identity), TestData.grant("kTCCServiceMicrophone", client: bundleOnly)]
        let items = [agent("a", owner: bundleOnly, program: "/Applications/Tool.app/Contents/MacOS/a"),
                     agent("b", owner: real.identity, program: nil)]
        let snapshot = TestData.appSnapshot([real, decoy], grants: grants, items: items)
        let index = AppLinks.index(snapshot.installedApps, in: snapshot)
        for app in [real, decoy] {
            #expect(index[app.id] == AppLinks.of(app, in: snapshot))
        }
    }

    // MARK: Plan

    @Test func planNeverTakesConflictsAndRemembersConsciouslyChosenSharedEntries() {
        let embedded = agent("com.example.tool.helper", owner: bundleOnly, program: "/Applications/Tool.app/Contents/MacOS/helper")
        let realGrant = TestData.grant(client: real.identity)
        let shared = TestData.grant("kTCCServiceMicrophone", client: bundleOnly)
        let snapshot = TestData.appSnapshot([real, decoy], grants: [realGrant, shared], items: [embedded])
        let plan = RemovalPlanning.plan(for: decoy, leftovers: LeftoverScanResult(candidates: []), snapshot: snapshot,
                                        selection: [realGrant.id, shared.id, embedded.id])
        #expect(plan.autostartItems.isEmpty, "Konflikt – auch ausgewählt nie im Plan")
        #expect(plan.grants == [realGrant, shared], "beide nur per Bundle-ID zugeordnet – gemeinsam")
        #expect(plan.acknowledgedSharedIDs == [realGrant.id, shared.id])
        #expect(plan.knownOtherInstallations == [real.path])
    }

    // MARK: Kanonische Pfade

    /// Programmpfad über einen Symlink (`/var` → `/private/var`) und Bundle-ID in anderer Schreibweise.
    @Test func pathsAreComparedCanonicallyAndBundleIDsCaseInsensitively() throws {
        try ScratchDirectory.with(prefix: "applinks") { directory in
            let bundle = try AppBundleFixture.make(in: directory, named: "Tool", bundleID: "com.example.tool", bundleName: "Tool")
            let canonical = try #require(AppleComponent.canonicalPath(bundle.path))
            let variant = canonical.hasPrefix("/private/") ? String(canonical.dropFirst("/private".count)) : bundle.path
            try #require(variant != canonical, "Scratch-Ordner liegt unter einem Symlink")
            let installed = TestData.installedApp("Tool", bundleID: "com.example.tool", path: canonical)
            let owner = AppIdentity(bundleID: "COM.Example.Tool", path: nil, displayName: "Tool", signing: .unknown,
                                    presence: .present)
            let embedded = agent("com.example.tool.helper", owner: owner, program: variant + "/Contents/MacOS/helper")
            let snapshot = TestData.appSnapshot([installed, decoy], items: [embedded])

            #expect(AppLinks.of(installed, in: snapshot).autostartItems == [embedded])
            #expect(AppLinks.of(installed, in: snapshot).sharedIDs.isEmpty, "Programm im eigenen Bundle – eindeutig")
            #expect(AppLinks.of(decoy, in: snapshot).autostartItems.isEmpty, "Programm in der anderen Installation")
            let index = AppLinks.index(snapshot.installedApps, in: snapshot)
            #expect(index[installed.id] == AppLinks.of(installed, in: snapshot))
            #expect(index[decoy.id] == AppLinks.of(decoy, in: snapshot))
        }
    }
}
