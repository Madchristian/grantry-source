import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AppleComponentTests {
    @Test(arguments: [
        "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle",
        "/usr/libexec/sshd-keygen-wrapper",
        "/usr/bin/ssh",
        "/Library/Apple/System/Library/CoreServices/XProtect.app",
        "/Applications/Xcode.app",
        "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild",
        "/Applications/Xcode_16.4.app",
        "/Applications/Xcode 26.app/Contents/MacOS/Xcode",
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simctl",
        // APFS unterscheidet Groß-/Kleinschreibung standardmäßig nicht; `.` und doppelte `/` ändern nichts am Ziel.
        "/SYSTEM/Library/CoreServices/x",
        "/usr/./libexec/x",
        "/usr//libexec/x",
        "/applications/xcode.app/Contents/MacOS/Xcode",
        // Cryptex im Preboot-Volume (Safari & Co., `/Applications/Safari.app` zeigt dorthin) ist versiegelt.
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/x",
    ])
    func applePaths(path: String) {
        #expect(AppleComponent.isApplePath(path), "\(path)")
    }

    @Test(arguments: [
        "/usr/local/bin/tool",
        "/usr/local",
        "/Applications/Zoom.app",
        "/Applications/XcodesApp.bundle/x",
        "/Applications/Xcodes.app",
        "/Applications/XcodeCleaner.app/Contents/MacOS/XcodeCleaner",
        "/Applications/Xcode-.app.evil/x",
        "/Applications/Utilities/Xcode.app",
        "/Library/Ossec/bin/wazuh-execd",
        "/Library/DeveloperTools/x",
        "/Users/user/Library/Developer/Xcode/DerivedData/Foo.app",
        "/Systemd/x",
        "/System/Volumes/Data/Applications/Zoom.app",
        "/System/Volumes/Data/Users/user/x",
        "/System/Volumes/Data/usr/local/bin/tool",
        // Präfix-Tricks: `..`, doppelte `/` und andere Schreibweisen führen aus den Apple-Verzeichnissen heraus.
        "/System/../Users/user/evil",
        "/usr/../Users/user/evil",
        "/Library/Apple/../../Users/user/evil",
        "/Library/Developer/../../Users/user/evil",
        "/Applications/Xcode-x.app/../../Users/user/evil",
        "/Applications/Xcode.app/../Evil.app/x",
        "/System//Volumes/Data/Users/user/evil",
        "/System/volumes/Data/Users/user/evil",
        "/SYSTEM/VOLUMES/DATA/Users/user/evil",
        // Nur die Cryptexe im Preboot-Volume sind versiegelt – nicht das übrige Preboot, nicht Data über `..`.
        "/System/Volumes/Preboot/x",
        "/System/Volumes/Preboot/CryptexesEvil/x",
        "/System/Volumes/Preboot/Cryptexes/../../Data/Users/user/evil",
        "/USR/LOCAL/bin/tool",
        // Keine absoluten Pfade
        "System/Library/x",
        "sh",
        "com.apple.foo",
    ])
    func nonApplePaths(path: String) {
        #expect(!AppleComponent.isApplePath(path), "\(path)")
    }

    /// Symlinks werden aufgelöst: Maßgeblich ist, wohin der Pfad tatsächlich führt.
    @Test func symlinksAreResolved() throws {
        try ScratchDirectory.with { directory in
            let intoUsr = directory.appending(path: "bin")
            try FileManager.default.createSymbolicLink(at: intoUsr, withDestinationURL: URL(filePath: "/usr/bin"))
            #expect(AppleComponent.isApplePath(intoUsr.path + "/ssh"))
            let evil = directory.appending(path: "evil")
            try Data().write(to: evil)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: evil)
            #expect(!AppleComponent.isApplePath(link.path))
        }
    }

    @Test func appIsAppleBySignatureBundleIDOrPath() {
        let thirdParty = SigningInfo(kind: .developerID, teamID: "T", isNotarized: true)
        #expect(AppleComponent.contains(TestData.app("com.example", signing: SigningInfo(kind: .apple))))
        #expect(AppleComponent.contains(TestData.app("com.apple.screensharing.agent", signing: .unknown)))
        let underSystem = AppIdentity(bundleID: nil, path: "/System/Library/x", displayName: "x", signing: .unknown,
                                      presence: .unknown)
        #expect(AppleComponent.contains(underSystem))
        #expect(!AppleComponent.contains(TestData.app("com.example", signing: thirdParty)))
    }

    /// Bei bekannter Signatur zählt nur sie; der Pfad ist nur Rückfall, wenn keine Signatur bekannt ist.
    @Test func knownSignatureOutweighsPath() {
        let underSystem = AppIdentity(bundleID: nil, path: "/System/Library/x", displayName: "x",
                                      signing: SigningInfo(kind: .developerID, teamID: "T"), presence: .present)
        #expect(!AppleComponent.contains(underSystem))
        for kind in [SigningInfo.Kind.unsigned, .adHoc, .developerID] {
            let program = TestData.userAgent("x", plistPath: "/Library/LaunchAgents/x.plist", program: "/usr/libexec/x",
                                             signing: SigningInfo(kind: kind))
            #expect(!AppleComponent.hasAppleProgram(program), "\(kind)")
        }
        for signing in [SigningInfo?.none, .unknown] {
            let program = TestData.userAgent("x", plistPath: "/Library/LaunchAgents/x.plist", program: "/usr/libexec/x",
                                             signing: signing)
            #expect(AppleComponent.hasAppleProgram(program))
        }
    }

    @Test func grantIsAppleByRawClientID() {
        let client = AppIdentity(bundleID: nil, path: nil, displayName: "x", signing: .unknown, presence: .unknown)
        func grant(clientID: String) -> PermissionGrant {
            PermissionGrant(service: "kTCCServiceCamera", client: client, authValue: .allowed, scope: .user,
                            lastModified: TestData.date, clientID: clientID)
        }
        #expect(AppleComponent.contains(grant(clientID: "com.apple.CoreSimulator.SimulatorTrampoline")))
        #expect(AppleComponent.contains(grant(clientID: "/usr/libexec/x")))
        #expect(!AppleComponent.contains(grant(clientID: "com.microsoft.wdav.epsext")))
    }

    @Test func itemIsAppleByLabelOrOwner() {
        #expect(AppleComponent.contains(TestData.item("com.apple.foo")))
        #expect(AppleComponent.contains(TestData.item("x", owner: TestData.app("com.apple.x", signing: SigningInfo(kind: .apple)))))
        #expect(!AppleComponent.contains(TestData.item("com.docker.helper", owner: TestData.app())))
    }

    /// Den Eigentümer eines launchd-Eintrags bestimmt die Plist selbst (`AssociatedBundleIdentifiers`, App-Bundle im
    /// Programmpfad) – eine Apple-Bundle-ID ist nur eine Behauptung.
    @Test func claimedAppleOwnerDoesNotMakeALaunchdItemApple() {
        // `AssociatedBundleIdentifiers = com.apple.Safari` löst zum echten, Apple-signierten Safari auf.
        let safari = AppIdentity(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", displayName: "Safari",
                                 signing: SigningInfo(kind: .apple), presence: .present)
        var claimsSafari = TestData.userAgent("com.evil.agent", plistPath: "/Users/test/Library/LaunchAgents/com.evil.agent.plist",
                                              program: "/Users/test/Library/.x/agent", signing: SigningInfo(kind: .unsigned))
        claimsSafari.owner = safari
        // Programm in `~/…/Foo.app` mit `CFBundleIdentifier = com.apple.x`.
        let fakeBundle = AppIdentity(bundleID: "com.apple.x", path: "/Users/test/Applications/Foo.app", displayName: "Foo",
                                     signing: SigningInfo(kind: .unsigned), presence: .present)
        var inFakeBundle = TestData.userAgent("com.evil.foo", plistPath: "/Users/test/Library/LaunchAgents/com.evil.foo.plist",
                                              program: "/Users/test/Applications/Foo.app/Contents/MacOS/foo", signing: SigningInfo(kind: .unsigned))
        inFakeBundle.owner = fakeBundle
        // Nur die Bundle-ID, Signatur des Programms nicht prüfbar: kein Nachweis von Apple-Herkunft.
        var unproven = inFakeBundle
        unproven.owner = AppIdentity(bundleID: "com.apple.x", path: "/Users/test/Applications/Foo.app", displayName: "Foo",
                                     signing: .unknown, presence: .present)
        unproven.programSigning = nil
        for item in [claimsSafari, inFakeBundle, unproven] {
            #expect(!AppleComponent.contains(item), "\(item.label)")
        }
    }

    /// Echte Apple-Eigentümer bleiben geschützt: Apple-signiert bzw. (ohne bekannte Signatur) unter einem Apple-Pfad.
    @Test func genuineAppleOwnerKeepsLaunchdItemApple() {
        var signed = TestData.userAgent("com.vendor.x", plistPath: "/Library/LaunchAgents/com.vendor.x.plist",
                                        program: "/Applications/Xcode.app/Contents/MacOS/x", signing: SigningInfo(kind: .apple))
        signed.owner = AppIdentity(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", displayName: "Xcode",
                                   signing: SigningInfo(kind: .apple), presence: .present)
        var unknownSigning = signed
        unknownSigning.owner?.signing = .unknown
        unknownSigning.programSigning = nil
        #expect(AppleComponent.contains(signed))
        #expect(AppleComponent.contains(unknownSigning))
    }

    /// Ein Systeminterpreter mit Argumenten (`/bin/sh -c ~/Library/.x/evil`) ist Apple-signiert, führt aber fremden
    /// Code aus: keine Apple-Herkunft, auch nicht als bloßer Programmname ohne Signaturprüfung.
    @Test func interpreterLaunchIsNotAppleOrigin() {
        var viaShell = TestData.userAgent("com.apple.update.agent", plistPath: "/Users/test/Library/LaunchAgents/com.apple.update.agent.plist",
                                          program: "/bin/sh", signing: SigningInfo(kind: .apple))
        viaShell.launchesInterpreter = true
        var bareName = viaShell
        bareName.program = "zsh"
        bareName.programSigning = nil
        var systemAgent = viaShell
        systemAgent.domain = .system
        systemAgent.plistPath = "/Library/LaunchAgents/com.apple.update.agent.plist"
        for item in [viaShell, bareName, systemAgent] {
            #expect(!AppleComponent.contains(item), "\(item.plistPath ?? "")")
            #expect(!AppleComponent.hasAppleProgram(item))
        }
    }

    /// Ein `com.apple.`-Label allein reicht nicht, wenn Plist und Programm außerhalb der Apple-Pfade liegen und das
    /// Programm nachweislich nicht von Apple signiert ist.
    @Test func disguisedAppleLabelIsNotApple() {
        #expect(!AppleComponent.contains(TestData.disguisedAppleAgent))
        #expect(!AppleComponent.hasAppleProgram(TestData.disguisedAppleAgent))
        for kind in [SigningInfo.Kind.adHoc, .developerID, .appStore, .development] {
            var disguised = TestData.disguisedAppleAgent
            disguised.programSigning = SigningInfo(kind: kind)
            #expect(!AppleComponent.contains(disguised), "\(kind)")
        }
    }

    /// Getarnt ist nur, wer sich als Apple ausgibt und es nachweislich nicht ist: ein normaler Eintrag, ein echter
    /// Apple-Eintrag und ein Eintrag ohne Plist (Login-Item, BTM) sind es nicht.
    @Test func disguiseNeedsAnAppleClaimThatIsProvenFalse() {
        #expect(AppleComponent.isDisguised(TestData.disguisedAppleAgent))
        var viaShell = TestData.disguisedAppleAgent
        viaShell.program = "/bin/sh"
        viaShell.programSigning = SigningInfo(kind: .apple)
        viaShell.launchesInterpreter = true
        #expect(AppleComponent.isDisguised(viaShell))
        var plain = TestData.disguisedAppleAgent
        plain.label = "com.example.agent"
        var genuine = TestData.disguisedAppleAgent
        genuine.programSigning = SigningInfo(kind: .apple)
        var withoutPlist = TestData.disguisedAppleAgent
        withoutPlist.plistPath = nil
        for item in [plain, genuine, withoutPlist] {
            #expect(!AppleComponent.isDisguised(item), "\(item.label)")
        }
    }

    /// Nur Plist-Orte, die `LaunchdSource` tatsächlich scannt (`~/Library/LaunchAgents`, `/Library/Launch*`).
    @Test(arguments: [
        // Apple-signiertes Programm
        TestData.userAgent("com.apple.c", plistPath: "/Users/test/Library/LaunchAgents/com.apple.c.plist",
                           program: "/Users/test/Library/c", signing: SigningInfo(kind: .apple)),
        TestData.userAgent("com.apple.b", plistPath: "/Library/LaunchDaemons/com.apple.b.plist",
                           program: "/Library/Application Support/b", signing: SigningInfo(kind: .apple)),
        // Programm unter einem Apple-Pfad, Signatur nicht geprüft
        TestData.userAgent("com.apple.d", plistPath: "/Library/LaunchAgents/com.apple.d.plist",
                           program: "/usr/libexec/d", signing: nil),
        // Signatur unbekannt oder nicht geprüft: kein Nachweis der Täuschung
        TestData.userAgent("com.apple.e", plistPath: "/Library/LaunchAgents/com.apple.e.plist",
                           program: "/Library/e", signing: .unknown),
        TestData.userAgent("com.apple.f", plistPath: "/Library/LaunchAgents/com.apple.f.plist",
                           program: "/Library/f", signing: nil),
    ])
    func genuineOrUnprovenAppleLabelsStayApple(item: AutostartItem) {
        #expect(AppleComponent.contains(item), "\(item.label)")
    }

    @Test func appleProgramNeedsAppleSignatureOrApplePath() {
        let appleSigned = TestData.userAgent("x", plistPath: "/Library/LaunchAgents/x.plist", program: "/opt/x",
                                             signing: SigningInfo(kind: .apple))
        let underSystem = TestData.userAgent("y", plistPath: "/Library/LaunchAgents/y.plist",
                                             program: "/System/Library/CoreServices/y", signing: nil)
        let appleLabelOnly = TestData.userAgent("com.apple.z", plistPath: "/Users/test/Library/LaunchAgents/com.apple.z.plist",
                                                program: "/opt/z", signing: SigningInfo(kind: .unsigned))
        #expect(AppleComponent.hasAppleProgram(appleSigned))
        #expect(AppleComponent.hasAppleProgram(underSystem))
        #expect(!AppleComponent.hasAppleProgram(appleLabelOnly))
    }
}
