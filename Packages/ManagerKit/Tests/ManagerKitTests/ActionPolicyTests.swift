import Testing
@testable import ManagerKit

@Suite struct ActionPolicyTests {
    let policy = ActionPolicy()

    @Test func thirdPartyInstalledGrantIsResettable() {
        #expect(policy.availability(for: TestData.grant()) == .available)
    }

    @Test func grantRestrictions() {
        let apple = TestData.app("com.apple.Terminal", signing: SigningInfo(kind: .apple))
        let gone = TestData.app("com.gone", presence: .missing)
        let pathClient = AppIdentity(bundleID: nil, path: "/opt/tool", displayName: "tool", signing: .unknown, presence: .present)
        #expect(policy.availability(for: TestData.grant(client: apple)) == .readOnly(.appleComponent))
        #expect(policy.availability(for: TestData.grant(client: gone)) == .readOnly(.notInstalled))
        let probablyGone = TestData.app("com.probably.gone", presence: .probablyMissing)
        #expect(policy.availability(for: TestData.grant(client: probablyGone)) == .readOnly(.notInstalled))
        let unknown = TestData.app("com.microsoft.wdav.epsext", presence: .unknown)
        #expect(policy.availability(for: TestData.grant(client: unknown)) == .readOnly(.presenceUnknown))
        #expect(policy.availability(for: TestData.grant(client: pathClient)) == .readOnly(.noBundleIdentifier))
    }

    @Test func pathClientResolvedToBundleIsNotResettable() {
        let resolved = AppIdentity(bundleID: "com.foo", path: "/Applications/Foo.app", displayName: "Foo", signing: .unknown, presence: .present)
        let grant = PermissionGrant(service: "kTCCServiceCamera", client: resolved, authValue: .allowed, scope: .user,
                                    lastModified: TestData.date, clientID: "/Applications/Foo.app")
        #expect(policy.availability(for: grant) == .readOnly(.noBundleIdentifier))
    }

    @Test func appleClientIDIsReadOnlyEvenWithoutAppleSignature() {
        let grant = PermissionGrant(service: "kTCCServiceCamera", client: TestData.app("com.apple.fake"), authValue: .allowed,
                                    scope: .user, lastModified: TestData.date)
        #expect(policy.availability(for: grant) == .readOnly(.appleComponent))
    }

    @Test func thirdPartyLaunchdItemIsEditable() {
        #expect(policy.availability(for: TestData.item("com.docker.helper")) == .available)
    }

    @Test func itemRestrictions() {
        #expect(policy.availability(for: TestData.item("com.apple.foo")) == .readOnly(.appleComponent))
        let appleOwner = TestData.app("com.apple.x", signing: SigningInfo(kind: .apple))
        #expect(policy.availability(for: TestData.item("x", owner: appleOwner)) == .readOnly(.appleComponent))
        #expect(policy.availability(for: TestData.item("y", kind: .loginItem, source: .btm)) == .readOnly(.managedBySystemSettings))
        #expect(policy.availability(for: TestData.item("b", kind: .backgroundTask, source: .btm)) == .readOnly(.managedBySystemSettings))
        let appleSignedOwner = TestData.app("com.vendor.tool", signing: SigningInfo(kind: .apple))
        #expect(policy.availability(for: TestData.item("w", owner: appleSignedOwner)) == .readOnly(.appleComponent))
        var noPlist = TestData.item("z")
        noPlist.plistPath = nil
        #expect(policy.availability(for: noPlist) == .readOnly(.noPlist))
    }

    /// Getarnte Einträge mit `com.apple.`-Label müssen entfernbar bleiben; echte Apple-Einträge bleiben geschützt.
    @Test func disguisedAppleLabelIsEditableButGenuineAppleItemsAreNot() {
        #expect(policy.availability(for: TestData.disguisedAppleAgent) == .available)
        let appleSigned = TestData.userAgent("com.apple.y", plistPath: "/Users/test/Library/LaunchAgents/com.apple.y.plist",
                                             program: "/Users/test/Library/y", signing: SigningInfo(kind: .apple))
        let underApplePath = TestData.userAgent("com.apple.z", plistPath: "/Library/LaunchAgents/com.apple.z.plist",
                                                program: "/Library/Apple/usr/libexec/z", signing: nil)
        for item in [appleSigned, underApplePath] {
            #expect(policy.availability(for: item) == .readOnly(.appleComponent), "\(item.label)")
        }
    }

    /// Systemweite Einträge ändert der Helper; er lehnt `com.apple.`-Labels grundsätzlich ab.
    @Test func disguisedAppleLabelInTheSystemDomainIsReadOnly() {
        var daemon = TestData.disguisedAppleAgent
        daemon.kind = .launchDaemon
        daemon.domain = .system
        daemon.plistPath = "/Library/LaunchDaemons/com.apple.update.agent.plist"
        var systemAgent = TestData.disguisedAppleAgent
        systemAgent.domain = .system
        systemAgent.plistPath = "/Library/LaunchAgents/com.apple.update.agent.plist"
        for item in [daemon, systemAgent] {
            #expect(policy.availability(for: item) == .readOnly(.appleLabelInSystemDomain))
        }
        #expect(ActionAvailability.Reason.appleLabelInSystemDomain.description
            == "Systemweiter Eintrag mit Apple-Label – nur manuell entfernbar")
    }

    @Test func agentsOutsideTheAquaSessionAreReadOnly() {
        var background = TestData.item("com.vendor.background")
        background.sessionTypes = ["Background", "LoginWindow"]
        #expect(policy.availability(for: background) == .readOnly(.nonAquaSession))
        var aqua = background
        aqua.sessionTypes = ["Aqua", "Background"]
        #expect(policy.availability(for: aqua) == .available)
        var daemon = TestData.item("com.vendor.daemon", kind: .launchDaemon, domain: .system)
        daemon.sessionTypes = ["System"]
        #expect(policy.availability(for: daemon) == .available)
        #expect(ActionAvailability.Reason.nonAquaSession.description
            == "Läuft nicht in der Benutzersitzung – Änderung hier nicht möglich")
    }

    @Test func reasonsHaveGermanDescriptions() {
        #expect(ActionAvailability.Reason.appleComponent.description == "Apple-Komponenten sind schreibgeschützt")
        #expect(ActionAvailability.Reason.presenceUnknown.description
            == "Existenz der App nicht feststellbar – Zurücksetzen nicht möglich")
    }
}
