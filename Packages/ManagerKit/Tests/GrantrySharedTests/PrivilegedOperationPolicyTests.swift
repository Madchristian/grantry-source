import Testing
import Foundation
import TestSupport
@testable import GrantryShared

@Suite struct PrivilegedOperationPolicyTests {
    let policy = PrivilegedOperationPolicy()

    @Test func acceptsThirdPartyLabels() throws {
        try policy.validateLabel("com.docker.helper")
        try policy.validateLabel("homebrew.mxcl.postgresql@14")   // echtes Label auf diesem Mac
        try policy.validateLabel("application.com.apple.RemoteDesktop.53958277.53958923".replacingOccurrences(of: "com.apple.", with: "com.vendor."))
    }

    /// Nur die Syntax: Ob ein `com.apple.`-Label echt ist, entscheidet der Aufrufer anhand der Herkunft.
    @Test func syntaxCheckAcceptsAppleLabelsButRejectsMalformedOnes() throws {
        try policy.validateLabelSyntax("com.apple.update.agent")
        for bad in ["", "../x", "a b", "-x"] {
            #expect(throws: PolicyViolation.invalidLabel(bad)) { try policy.validateLabelSyntax(bad) }
        }
    }

    @Test func rejectsAppleAndMalformedLabels() {
        #expect(throws: PolicyViolation.appleLabel("com.apple.screensharing")) { try policy.validateLabel("com.apple.screensharing") }
        for bad in ["", "../x", "a b", "a/b", "-x", String(repeating: "a", count: 256)] {
            #expect(throws: PolicyViolation.invalidLabel(bad)) { try policy.validateLabel(bad) }
        }
    }

    @Test func acceptsPlistDirectlyInsideManagedDirectory() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchDaemons")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let plist = managed.appending(path: "com.example.plist")
            try Data().write(to: plist)
            let validated = try policy.validatePlistPath(plist.path, managedDirectories: [managed.path])
            #expect(validated == plist.resolvingSymlinksInPath().path)
        }
    }

    @Test func rejectsPathsOutsideNestedSymlinkedOrNonPlist() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchDaemons")
            let outside = dir.appending(path: "elsewhere")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside.appending(path: "sub"), withIntermediateDirectories: true)
            let target = outside.appending(path: "evil.plist")
            try Data().write(to: target)
            let link = managed.appending(path: "link.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try Data().write(to: managed.appending(path: "notes.txt"))

            let candidates = [
                target.path,                                          // außerhalb
                managed.appending(path: "../elsewhere/evil.plist").path, // Traversal
                link.path,                                            // Symlink
                managed.appending(path: "notes.txt").path,            // keine .plist
            ]
            for path in candidates {
                #expect(throws: PolicyViolation.self) {
                    try policy.validatePlistPath(path, managedDirectories: [managed.path])
                }
            }
        }
    }

    @Test func rejectsPlistPathWithTrailingSlash() throws {
        try ScratchDirectory.with { dir in
            let managed = dir.appending(path: "LaunchDaemons")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let plist = managed.appending(path: "com.example.plist")
            try Data().write(to: plist)
            #expect(throws: PolicyViolation.self) {
                try policy.validatePlistPath(plist.path + "/", managedDirectories: [managed.path])
            }
        }
    }

    @Test func rejectsLabelsWithControlCharactersOrUnicode() {
        for bad in ["a\nb", "a\0b", "läbel", "a\u{1F600}b"] {
            #expect(throws: PolicyViolation.invalidLabel(bad)) { try policy.validateLabel(bad) }
        }
    }

    @Test func readsLabelFromLaunchDaemonPlist() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)

            let result = try policy.launchDaemonLabel(forPlistAt: plist.path, launchDaemonsDirectory: daemons.path)
            #expect(result.label == "com.example.daemon")
            #expect(result.path == plist.resolvingSymlinksInPath().path)
        }
    }

    @Test func rejectsAppleLabelReadFromPlistContents() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.apple.x", in: daemons)

            #expect(throws: PolicyViolation.appleLabel("com.apple.x")) {
                try policy.launchDaemonLabel(forPlistAt: plist.path, launchDaemonsDirectory: daemons.path)
            }
        }
    }

    @Test func rejectsLaunchDaemonPlistWithoutLabel() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(payload: ["Program": "/bin/true"], named: "no-label.plist", in: daemons)

            #expect(throws: PolicyViolation.pathNotAllowed(plist.path)) {
                try policy.launchDaemonLabel(forPlistAt: plist.path, launchDaemonsDirectory: daemons.path)
            }
        }
    }

    @Test func rejectsLaunchAgentsPlistForLaunchDaemonLabel() throws {
        try ScratchDirectory.with { dir in
            let agents = dir.appending(path: "LaunchAgents")
            let daemons = dir.appending(path: "LaunchDaemons")
            try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: agents)

            #expect(throws: PolicyViolation.pathNotAllowed(plist.path)) {
                try policy.launchDaemonLabel(forPlistAt: plist.path, launchDaemonsDirectory: daemons.path)
            }
        }
    }

    @Test func readsLabelFromPlistInAnyManagedDirectory() throws {
        try ScratchDirectory.with { dir in
            let agents = dir.appending(path: "LaunchAgents")
            let daemons = dir.appending(path: "LaunchDaemons")
            let agent = try LaunchdPlistFixture.write(label: "com.example.agent", in: agents)
            let daemon = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let managed = [agents.path, daemons.path]

            #expect(try policy.label(forPlistAt: agent.path, managedDirectories: managed).label == "com.example.agent")
            #expect(try policy.label(forPlistAt: daemon.path, managedDirectories: managed).label == "com.example.daemon")
        }
    }

    @Test func rejectsAppleLabelReadFromPlistInManagedDirectory() throws {
        try ScratchDirectory.with { dir in
            let agents = dir.appending(path: "LaunchAgents")
            let plist = try LaunchdPlistFixture.write(label: "com.apple.x", named: "vendor.plist", in: agents)
            #expect(throws: PolicyViolation.appleLabel("com.apple.x")) {
                try policy.label(forPlistAt: plist.path, managedDirectories: [agents.path])
            }
        }
    }

    /// Auf case-insensitiven Volumes (APFS-Standard) bezeichnet eine abweichende Schreibweise dieselbe Datei.
    /// Die Policy kanonisiert sie auf die tatsächliche Schreibweise im verwalteten Verzeichnis; Aufrufer
    /// arbeiten nur mit diesem Pfad, und die Label-Prüfung greift unverändert.
    @Test func canonicalizesCaseVariantToManagedDirectory() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            try LaunchdPlistFixture.write(label: "com.apple.x", named: "apple.plist", in: daemons)
            let variantDirectory = dir.appending(path: "launchdaemons")
            guard FileManager.default.fileExists(atPath: variantDirectory.path) else { return } // case-sensitives Volume

            let canonical = try policy.validatePlistPath(
                variantDirectory.appending(path: "COM.EXAMPLE.DAEMON.plist").path, managedDirectories: [daemons.path]
            )
            #expect(canonical == plist.resolvingSymlinksInPath().path)
            #expect(throws: PolicyViolation.appleLabel("com.apple.x")) {
                try policy.launchDaemonLabel(
                    forPlistAt: variantDirectory.appending(path: "APPLE.plist").path, launchDaemonsDirectory: daemons.path
                )
            }
        }
    }

    @Test func readsLabelFromBinaryPlist() throws {
        try ScratchDirectory.with { dir in
            let agents = dir.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let plist = agents.appending(path: "com.example.binary.plist")
            try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.binary"], format: .binary, options: 0)
                .write(to: plist)
            #expect(try policy.label(forPlistAt: plist.path, managedDirectories: [agents.path]).label == "com.example.binary")
        }
    }

    // MARK: - Eindeutigkeit eines Labels (#99)

    /// Eine zweite Plist mit demselben Label – im selben oder einem weiteren Verzeichnis der Domain – macht das
    /// Label mehrdeutig; die Meldung nennt Label und die andere Datei.
    @Test func labelSharedByAnotherPlistIsAmbiguous() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let apple = dir.appending(path: "System/Library/LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", named: "mine.plist", in: daemons)
            try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
            let canonical = plist.resolvingSymlinksInPath().path

            try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: canonical, in: [daemons.path, apple.path])

            let twin = try LaunchdPlistFixture.write(label: "com.example.daemon", named: "twin.plist", in: apple)
            #expect(throws: PolicyViolation.ambiguousLabel("com.example.daemon", otherPath: twin.resolvingSymlinksInPath().path)) {
                try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: canonical, in: [daemons.path, apple.path])
            }
            #expect(PolicyViolation.ambiguousLabel("com.example.daemon", otherPath: twin.path).errorDescription?.contains("twin.plist") == true)
        }
    }

    /// Die eigene Plist – auch unter abweichender Schreibweise –, andere Labels, Nicht-Plists, Plists ohne Label,
    /// Einträge, die keine reguläre Datei sind, ins Leere zeigende Symlinks, Unterverzeichnisse und fehlende
    /// Verzeichnisse zählen nicht.
    @Test func uniquenessIgnoresOwnPlistAndUnrelatedEntries() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            try LaunchdPlistFixture.write(label: "com.example.other", in: daemons)
            try LaunchdPlistFixture.write(label: "com.example.daemon", named: "notes.txt", in: daemons)
            try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons.appending(path: "Disabled"))
            try LaunchdPlistFixture.write(payload: ["Program": "/bin/true"], named: "no-label.plist", in: daemons)
            try FileManager.default.createDirectory(at: daemons.appending(path: "folder.plist"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: daemons.appending(path: "dangling.plist"), withDestinationURL: dir.appending(path: "nowhere.plist")
            )

            try policy.ensureLabelIsUnique(
                "com.example.daemon", ofPlistAt: daemons.appending(path: "./com.example.daemon.plist").path,
                in: [daemons.path, dir.appending(path: "missing").path]
            )
            _ = plist
        }
    }

    /// Eine weitere reguläre Plist, deren Label sich nicht lesen lässt – kaputt, übergroß oder ohne Leserecht –, ist
    /// kein „eindeutig“ (fail-closed): Sie könnte dasselbe Label tragen.
    @Test(arguments: ["broken", "oversized", "locked"])
    func unverifiablePlistIsRefused(kind: String) throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let twin = daemons.appending(path: "twin.plist")
            switch kind {
            case "broken": try Data("garbage".utf8).write(to: twin)
            case "oversized": try Data(count: PrivilegedOperationPolicy.maximumPlistSize + 1).write(to: twin)
            default:
                try LaunchdPlistFixture.write(label: "com.example.daemon", named: "twin.plist", in: daemons)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: twin.path)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: twin.path) }
            guard kind != "locked" || !FileManager.default.isReadableFile(atPath: twin.path) else { return } // root liest alles

            #expect(throws: PolicyViolation.unverifiableLabel(twin.resolvingSymlinksInPath().path)) {
                try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: plist.path, in: [daemons.path])
            }
        }
    }

    /// Fehlt das Suchrecht auf einem übergeordneten Verzeichnis, ist das Verzeichnis nicht „fehlend“, sondern nicht
    /// auflistbar – ein Zwilling darin bliebe sonst unentdeckt: ablehnen (fail-closed).
    @Test func directoryBehindUnsearchableParentIsRefused() throws {
        try ScratchDirectory.with { dir in
            let own = try LaunchdPlistFixture.write(label: "com.example.daemon", in: dir.appending(path: "Own"))
            let parent = dir.appending(path: "Library")
            let agents = parent.appending(path: "LaunchAgents")
            try LaunchdPlistFixture.write(label: "com.example.daemon", named: "twin.plist", in: agents)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
            guard geteuid() != 0 else { return } // root durchsucht alles

            #expect(throws: PolicyViolation.unreadableDirectory(agents.path)) {
                try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: own.path, in: [agents.path])
            }
            // Nachweislich fehlend bleibt fehlend – auch hinter einer Datei statt eines Verzeichnisses (ENOTDIR).
            try policy.ensureLabelIsUnique(
                "com.example.daemon", ofPlistAt: own.path,
                in: [dir.appending(path: "missing").path, own.appending(path: "LaunchAgents").path]
            )
        }
    }

    /// Ein vorhandenes, aber unlesbares Verzeichnis ist kein „eindeutig“: Die Operation wird abgelehnt.
    @Test func unreadableDirectoryIsRefused() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let locked = dir.appending(path: "Locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            guard (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil else { return } // root liest alles

            #expect(throws: PolicyViolation.unreadableDirectory(locked.path)) {
                try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: plist.path, in: [daemons.path, locked.path])
            }
        }
    }

    /// Ein Symlink im Verzeichnis, der auf die eigene Plist zeigt, ist keine zweite Plist; einer auf eine fremde
    /// Datei mit demselben Label dagegen schon (launchd läse ihn ebenfalls).
    @Test func uniquenessFollowsSymlinks() throws {
        try ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let canonical = plist.resolvingSymlinksInPath().path
            try FileManager.default.createSymbolicLink(at: daemons.appending(path: "self.plist"), withDestinationURL: plist)
            try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: canonical, in: [daemons.path])

            let foreign = try LaunchdPlistFixture.write(label: "com.example.daemon", in: dir.appending(path: "elsewhere"))
            try FileManager.default.createSymbolicLink(at: daemons.appending(path: "foreign.plist"), withDestinationURL: foreign)
            #expect(throws: PolicyViolation.self) {
                try policy.ensureLabelIsUnique("com.example.daemon", ofPlistAt: canonical, in: [daemons.path])
            }
        }
    }
}
