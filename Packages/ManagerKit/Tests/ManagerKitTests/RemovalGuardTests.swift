import Foundation
import Testing
@testable import ManagerKit

@Suite struct RemovalGuardTests {
    @Test func allowsDirectEntriesOfLeftoverLocations() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for path in [
                try fixture.folder(fixture.userLibrary("Caches/com.example.tool")),
                try fixture.file(fixture.userLibrary("Preferences/com.example.tool.plist")),
                try fixture.file(fixture.userLibrary("Preferences/ByHost/com.example.tool.ABC.plist")),
                try fixture.folder(fixture.userLibrary("Group Containers/ABCDE12345.com.example")),
                try fixture.folder(fixture.system("Library/Application Support/com.example.tool")),
            ] {
                #expect(check.check(path) == .allowed, "\(path)")
            }
        }
    }

    @Test func allowsAppBundlesUpToThreeFolders() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            #expect(check.check(try fixture.app("Top", bundleID: "com.example.top")) == .allowed)
            #expect(check.check(try fixture.app("Deep", bundleID: "com.example.deep", subfolder: "a/b/c")) == .allowed)
            #expect(check.check(try fixture.app("TooDeep", bundleID: "com.example.x", subfolder: "a/b/c/d")) != .allowed)
            #expect(check.check(try fixture.app("Hidden", bundleID: "com.example.y", subfolder: ".cuepkg")) != .allowed)
            let host = try fixture.app("Host", bundleID: "com.example.host")
            let nested = try AppFixture.make(in: URL(fileURLWithPath: host).appending(path: "Contents/Applications"),
                                             named: "Nested", bundleID: "com.example.nested")
            #expect(check.check(nested.path) != .allowed)
            // Eine Datei namens `.app` ist kein Bundle.
            let fake = try fixture.file(fixture.system("Applications/Fake.app"))
            #expect(check.check(fake) == .blocked("Außerhalb der erlaubten Orte"))
        }
    }

    @Test func blocksLocationsNestedEntriesAndOutsidePaths() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let nested = try fixture.folder(fixture.userLibrary("Caches/com.example.tool/sub"))
            for path in [
                fixture.userLibrary("Caches"), fixture.userLibrary("Preferences/ByHost"), fixture.system("Applications"),
                fixture.home + "/Library", fixture.home, nested,
                try fixture.file(fixture.home + "/Documents/report.pdf"),
            ] {
                #expect(check.check(path) == .blocked("Außerhalb der erlaubten Orte"), "\(path)")
            }
        }
    }

    @Test func blocklistWinsEvenForExistingPaths() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for path in [
                try fixture.file(fixture.system("System/Library/kernel")),
                try fixture.file(fixture.system("usr/bin/tool")),
                try fixture.file(fixture.system("private/etc/hosts")),
                try fixture.folder(fixture.system("Library/Apple/System")),
                try fixture.file(fixture.userLibrary("Keychains/login.keychain-db")),
                try fixture.folder(fixture.userLibrary("Mobile Documents/com~apple~CloudDocs")),
                try fixture.folder(fixture.userLibrary("Mail/V10")),
                try fixture.folder(fixture.userLibrary("Messages/Attachments")),
                try fixture.folder(fixture.userLibrary("Photos/Libraries")),
                try fixture.folder(fixture.userLibrary("CloudStorage/Dropbox")),
                fixture.userLibrary("Keychains"),
            ] {
                #expect(check.check(path) == .blocked("Geschützter Ort"), "\(path)")
            }
        }
    }

    /// Sperrorte innerhalb erlaubter Reste-Orte (z. B. iPhone-Sicherungen, TCC-Datenbank) bleiben gesperrt.
    @Test func blocklistInsideLeftoverLocations() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for path in [
                try fixture.folder(fixture.userLibrary("Application Support/MobileSync")),
                try fixture.folder(fixture.userLibrary("Application Support/com.apple.TCC")),
                try fixture.folder(fixture.system("Library/Application Support/com.apple.TCC")),
            ] {
                #expect(check.check(path) == .blocked("Geschützter Ort"), "\(path)")
            }
        }
    }

    /// APFS unterscheidet Groß-/Kleinschreibung nicht – die Sperrliste auch nicht.
    @Test func blocklistIgnoresCase() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            try fixture.file(fixture.userLibrary("Keychains/login.keychain-db"))
            try fixture.file(fixture.system("usr/bin/tool"))
            #expect(check.check(fixture.home + "/LIBRARY/keychains/login.keychain-db") == .blocked("Geschützter Ort"))
            #expect(check.check(fixture.root + "/USR/bin/tool") == .blocked("Geschützter Ort"))
            #expect(check.check(fixture.home + "/library/MOBILE DOCUMENTS") == .blocked("Geschützter Ort"))
        }
    }

    @Test func symlinksAreNeverFollowed() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let target = try fixture.folder(fixture.home + "/Documents/precious")
            let link = fixture.userLibrary("Caches/com.example.link")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(check.check(link) == .blocked("Symbolischer Link"))
            // Ein Symlink im Pfad (Ordner `Logs` zeigt woanders hin) zählt ebenso.
            try fixture.replaceWithSymlink(fixture.userLibrary("Logs"), to: fixture.home + "/Documents")
            #expect(check.check(fixture.userLibrary("Logs/precious")) == .blocked("Symbolischer Link im Pfad"))
        }
    }

    /// Symlinks, die in eine Sperrzone zeigen – als Eintrag und als Ort.
    @Test func symlinksIntoBlockedPlaces() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            try fixture.file(fixture.userLibrary("Keychains/login.keychain-db"))
            let link = fixture.userLibrary("Caches/com.example.keys")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.userLibrary("Keychains"))
            #expect(check.check(link) == .blocked("Symbolischer Link"))
            try fixture.replaceWithSymlink(fixture.userLibrary("WebKit"), to: fixture.userLibrary("Keychains"))
            #expect(check.check(fixture.userLibrary("WebKit/login.keychain-db")) == .blocked("Symbolischer Link im Pfad"))
            try fixture.replaceWithSymlink(fixture.system("Applications"), to: fixture.system("System"))
            try fixture.folder(fixture.system("System/Evil.app"))
            #expect(check.check(fixture.system("Applications/Evil.app")) == .blocked("Symbolischer Link im Pfad"))
        }
    }

    @Test func symlinkedAppBundleIsBlocked() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let real = try fixture.folder(fixture.system("System/Library/Real.app"))
            let link = fixture.system("Applications/Real.app")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(check.check(link) == .blocked("Symbolischer Link"))
        }
    }

    @Test func invalidAndMissingPaths() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let entry = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            #expect(check.check("") == .blocked("Ungültiger Pfad"))
            #expect(check.check("/") == .blocked("Ungültiger Pfad"))
            #expect(check.check("relative/path") == .blocked("Ungültiger Pfad"))
            #expect(check.check(fixture.userLibrary("Caches/../Keychains/login.keychain-db")) == .blocked("Ungültiger Pfad"))
            #expect(check.check(fixture.userLibrary("Caches/./com.example.tool")) == .blocked("Ungültiger Pfad"))
            #expect(check.check(fixture.userLibrary("Caches//com.example.tool")) == .blocked("Ungültiger Pfad"))
            #expect(check.check(entry + "/") == .blocked("Ungültiger Pfad"))
            #expect(check.check(fixture.userLibrary("Caches/com.example.missing")) == .blocked("Nicht vorhanden"))
        }
    }

    /// Andere Schreibweise eines erlaubten Pfads bleibt erlaubt (APFS), solange kein Symlink im Spiel ist.
    @Test func caseVariantOfAllowedEntry() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            #expect(check.check(fixture.userLibrary("CACHES/com.example.tool")) == .allowed)
        }
    }

    /// Versteckte Einträge (Name beginnt mit `.`, auch vor einem kombinierenden Zeichen) sind nie Reste.
    @Test func hiddenEntriesAreBlocked() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for path in [
                try fixture.file(fixture.userLibrary("Preferences/.GlobalPreferences.plist")),
                try fixture.folder(fixture.userLibrary("Caches/.com.example.tool")),
                try fixture.folder(fixture.userLibrary("Caches/.\u{301}hidden")),
            ] {
                #expect(check.check(path) == .blocked("Versteckter Eintrag"), "\(path)")
            }
        }
    }

    /// Schützenswerte Einträge in den Reste-Orten (Kontakte, Anrufliste, Wissensdatenbank, iCloud-Daten, Anmeldefenster).
    @Test func blocklistCoversSensitiveUserData() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for name in ["AddressBook", "CallHistoryDB", "Knowledge", "FileProvider", "CloudDocs", "com.apple.sharedfilelist"] {
                let path = try fixture.folder(fixture.userLibrary("Application Support/" + name))
                #expect(check.check(path) == .blocked("Geschützter Ort"), "\(path)")
            }
            let loginWindow = try fixture.file(fixture.userLibrary("Preferences/loginwindow.plist"))
            #expect(check.check(loginWindow) == .blocked("Geschützter Ort"))
        }
    }

    /// Apple-Kennungen (`com.apple.*`, `group.com.apple.*`, auch hinter einer Team-ID) nie ohne Freigabe.
    @Test func appleEntriesNeedARelease() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            for path in [
                try fixture.file(fixture.userLibrary("Preferences/com.apple.loginwindow.plist")),
                try fixture.file(fixture.userLibrary("Preferences/ByHost/com.apple.loginwindow.ABC.plist")),
                try fixture.folder(fixture.userLibrary("Containers/com.apple.Notes")),
                try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.notes")),
                try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.com.apple.iWork")),
                try fixture.folder(fixture.userLibrary("Caches/COM.APPLE.Safari")),
                // Review N9: wie `BundleIDShape.isApple` – Team-ID **und** `group.`, Apple-Namensräume ohne `com.apple`.
                try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.group.com.apple.notes")),
                try fixture.folder(fixture.userLibrary("Group Containers/group.is.workflow.my.app")),
                try fixture.folder(fixture.userLibrary("Containers/developer.apple.wwdc-Release")),
                try fixture.folder(fixture.userLibrary("Caches/org.swift.swiftpm")),
            ] {
                #expect(check.check(path) == .blocked("Apple-Eintrag"), "\(path)")
            }
        }
    }

    /// Freigabe nur für die Kennung der nachweislich von Apple stammenden App, die gerade entfernt wird.
    @Test func appleReleaseOnlyForVerifiedAppleApp() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let keynote = TestData.installedApp("Keynote", bundleID: "com.apple.iWork.Keynote", origin: .appStore,
                                                signing: SigningInfo(kind: .appStore, teamID: "74J34U3R6X", isNotarized: true))
            let own = try fixture.folder(fixture.userLibrary("Containers/com.apple.iWork.Keynote"))
            let prefs = try fixture.file(fixture.userLibrary("Preferences/com.apple.iWork.Keynote.plist"))
            let notes = try fixture.folder(fixture.userLibrary("Containers/com.apple.Notes"))
            let group = try fixture.folder(fixture.userLibrary("Group Containers/group.com.apple.notes"))
            let shared = try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.com.apple.iWork"))
            let teamGroup = try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.group.com.apple.iWork.Keynote"))
            let otherTeamGroup = try fixture.folder(fixture.userLibrary("Group Containers/74J34U3R6X.group.com.apple.notes"))
            #expect(check.check(own, allowingAppleIDOf: keynote) == .allowed)
            #expect(check.check(prefs, allowingAppleIDOf: keynote) == .allowed)
            #expect(check.check(teamGroup, allowingAppleIDOf: keynote) == .allowed)
            for path in [notes, group, shared, otherTeamGroup] {
                #expect(check.check(path, allowingAppleIDOf: keynote) == .blocked("Apple-Eintrag"), "\(path)")
            }
            // Unsigniert, nur mit App-Store-Beleg oder nur mit Bundle-ID: keine Freigabe.
            for signing in [SigningInfo(kind: .unsigned), SigningInfo(kind: .developerID, teamID: "TEAMA12345"), .unknown] {
                var fake = keynote
                fake.signing = signing
                #expect(check.check(own, allowingAppleIDOf: fake) == .blocked("Apple-Eintrag"), "\(signing)")
            }
            // Apple-signierte Kopie einer System-App (`/System/Applications/Notes.app`): keine Freigabe.
            try AppFixture.make(in: URL(fileURLWithPath: fixture.system("System/Applications")), named: "Notes",
                                bundleID: "com.apple.Notes")
            let copy = TestData.installedApp("Notes", bundleID: "com.apple.Notes", origin: .apple,
                                             signing: SigningInfo(kind: .apple, isNotarized: true))
            #expect(check.check(notes, allowingAppleIDOf: copy) == .blocked("Apple-Eintrag"))
        }
    }

    /// Sperrorte werden am Objekt (`st_dev`/`st_ino`) erkannt – auch bei APFS-Faltung jenseits von `lowercased()`
    /// (`ſ`, U+017F, faltet zu `s`).
    @Test func blocklistMatchesTheObjectNotTheSpelling() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            try fixture.folder(fixture.userLibrary("Application Support/MobileSync/Backup"))
            let variant = fixture.userLibrary("Application Support/Mobile\u{17F}ync")
            try #require(FileType.exists(atPath: variant), "Dateisystem faltet ſ nicht")
            #expect(check.check(variant) == .blocked("Geschützter Ort"))
            #expect(check.check(variant + "/Backup") == .blocked("Geschützter Ort"))
        }
    }

    /// Kombinierende Zeichen nach `/` bilden in Swift ein Zeichen mit dem Trenner – zerlegt wird nach Bytes.
    @Test func pathsAreSplitByBytes() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let deep = try fixture.app("Deep", bundleID: "com.example.deep", subfolder: "a/\u{301}b/c/d")
            #expect(check.check(deep) == .blocked("Außerhalb der erlaubten Orte"))
            let hidden = try fixture.app("Hidden", bundleID: "com.example.hidden", subfolder: ".\u{301}x")
            #expect(check.check(hidden) == .blocked("Außerhalb der erlaubten Orte"))
            #expect(RawPath.components(of: "/a/\u{301}b/.\u{301}c") == ["a", "\u{301}b", ".\u{301}c"])
            #expect(RawPath.components(of: "/a//\u{301}b") == nil)
            #expect(RawPath.components(of: "/a/\u{301}..") == ["a", "\u{301}.."])
            #expect(RawPath.isHidden(".\u{301}x") && !RawPath.isHidden("x."))
        }
    }

    /// Unmittelbar vor dem Papierkorb: noch dasselbe Objekt wie bei der Suche?
    @Test func candidateMustStillBeTheSameObject() async throws {
        try await LibraryFixture.with { fixture in
            let check = RemovalGuard(layout: fixture.layout)
            let path = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
            let identity = try #require(FileIdentity.of(path))
            #expect(identity.type == .directory)
            let candidate = LeftoverCandidate(path: path, kind: .caches, confidence: .safe, identity: identity)
            #expect(check.check(candidate, allowingAppleIDOf: nil) == .allowed)
            try FileManager.default.removeItem(atPath: path)
            try fixture.file(path)
            #expect(check.check(candidate, allowingAppleIDOf: nil) == .blocked("Eintrag wurde ersetzt"))
            let unknown = LeftoverCandidate(path: path, kind: .caches, confidence: .safe)
            #expect(check.check(unknown, allowingAppleIDOf: nil) == .blocked("Eintrag wurde ersetzt"))
            try FileManager.default.removeItem(atPath: path)
            #expect(check.check(candidate, allowingAppleIDOf: nil) == .blocked("Nicht vorhanden"))
        }
    }

    /// Ein anderes Volume unter einem Reste-Ort (Einhängepunkt) ist nie ein Rest.
    @Test func mountPointsAreDetectedByDevice() {
        let parent = FileIdentity(device: 1, inode: 10, type: .directory)
        #expect(RemovalGuard.isMountPoint(FileIdentity(device: 2, inode: 2, type: .directory), below: parent))
        #expect(!RemovalGuard.isMountPoint(FileIdentity(device: 1, inode: 11, type: .directory), below: parent))
    }

    /// Gegen das echte System, ausschließlich lesend.
    @Test(arguments: [
        "/System/Applications/Calculator.app", "/system/applications/calculator.app", "/usr/bin/true", "/private/etc/hosts",
        "/etc/hosts", "/var/log", "/tmp", "/Library/Apple", "/Applications/Safari.app", "/bin/ls", "/sbin/launchd",
        "/Applications", "/Library/Application Support", "/Users", "/",
    ])
    func standardLayoutBlocksSystemPaths(path: String) {
        #expect(RemovalGuard().check(path) != .allowed)
    }

    @Test(arguments: ["Keychains", "Mobile Documents", "Mail", "Messages", "Photos", "CloudStorage"])
    func standardLayoutBlocksUserPlaces(name: String) {
        #expect(RemovalGuard().check(NSHomeDirectory() + "/Library/" + name) == .blocked("Geschützter Ort"))
    }

    /// Echte Einträge des Benutzers, ausschließlich lesend (fehlt einer, ist er ebenso gesperrt).
    @Test(arguments: [
        "Preferences/.GlobalPreferences.plist", "Preferences/com.apple.loginwindow.plist", "Preferences/loginwindow.plist",
        "Application Support/AddressBook", "Application Support/CallHistoryDB", "Application Support/Knowledge",
        "Application Support/com.apple.sharedfilelist", "Group Containers/group.com.apple.notes",
        "Containers/com.apple.Notes",
    ])
    func standardLayoutBlocksSensitiveUserEntries(relative: String) {
        #expect(RemovalGuard().check(NSHomeDirectory() + "/Library/" + relative) != .allowed)
    }

    @Test func standardLayoutBlocksLocationsThemselves() {
        let check = RemovalGuard()
        for path in [NSHomeDirectory(), NSHomeDirectory() + "/Library", NSHomeDirectory() + "/Library/Caches",
                     NSHomeDirectory() + "/Library/Preferences"] {
            #expect(check.check(path) != .allowed, "\(path)")
        }
    }
}
