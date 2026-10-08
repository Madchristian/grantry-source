import Foundation
import Testing
@testable import ManagerKit

@Suite struct NotificationPolicyTests {
    private let policy = NotificationPolicy()

    private func modified(_ before: SecurityCheck, _ after: SecurityCheck) -> ChangeEvent {
        ChangeEvent(kind: .modified, before: .securityCheck(before), after: .securityCheck(after), detectedAt: TestData.date)
    }

    @Test func deteriorationIsNotified() {
        let good = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(policy.shouldNotify(modified(good, TestData.securityCheck(TestData.stealthOff, state: .warning))))
        #expect(policy.shouldNotify(modified(TestData.securityCheck(TestData.stealthOff, state: .warning),
                                             TestData.securityCheck(TestData.firewallOff, state: .critical))))
    }

    @Test func improvementAndSameStateAreNotNotified() {
        let warning = TestData.securityCheck(TestData.stealthOff, state: .warning)
        #expect(!policy.shouldNotify(modified(warning, TestData.securityCheck(TestData.firewallOn, state: .good))))
        let xprotect = TestData.securityCheck(.xprotect(version: "1", installedAt: TestData.date), state: .good)
        #expect(!policy.shouldNotify(modified(xprotect, TestData.securityCheck(.xprotect(version: "2", installedAt: TestData.date), state: .good))))
    }

    @Test func failureAndRecoveryAreNotNotifiedUnlessWorse() {
        var failed = SecurityCheck.failed(.firewall, detail: "x")
        failed.facts = TestData.firewallOn
        failed.lastKnownState = .good
        #expect(!policy.shouldNotify(modified(TestData.securityCheck(TestData.firewallOn, state: .good), failed)))
        #expect(!policy.shouldNotify(modified(failed, TestData.securityCheck(TestData.firewallOn, state: .good))))
        #expect(policy.shouldNotify(modified(failed, TestData.securityCheck(TestData.firewallOff, state: .critical))))
    }

    @Test func checkWithoutKnownStateIsNotNotified() {
        let neverRead = SecurityCheck.failed(.firewall, detail: "x")
        #expect(!policy.shouldNotify(modified(neverRead, TestData.securityCheck(TestData.firewallOff, state: .critical))))
    }

    @Test func mdmChangeIsNotifiedInBothDirections() {
        let none = TestData.securityCheck(.mdmEnrollment(enrolled: false, viaDEP: false), state: .good)
        let enrolled = TestData.securityCheck(.mdmEnrollment(enrolled: true, viaDEP: false), state: .good)
        #expect(policy.shouldNotify(modified(none, enrolled)))
        #expect(policy.shouldNotify(modified(enrolled, none)))
        let viaDEP = TestData.securityCheck(.mdmEnrollment(enrolled: true, viaDEP: true), state: .good)
        #expect(!policy.shouldNotify(modified(enrolled, viaDEP)))
    }

    @Test func addedOrRemovedChecksAndOtherRecordsFollowV1() {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(!policy.shouldNotify(ChangeEvent(kind: .added, before: nil, after: .securityCheck(check), detectedAt: TestData.date)))
        #expect(!policy.shouldNotify(ChangeEvent(kind: .removed, before: .securityCheck(check), after: nil, detectedAt: TestData.date)))
        let grant = TestData.grant("kTCCServiceCamera")
        #expect(policy.shouldNotify(ChangeEvent(kind: .added, before: nil, after: .grant(grant), detectedAt: TestData.date)))
        let item = TestData.item("com.example.agent")
        #expect(policy.shouldNotify(ChangeEvent(kind: .removed, before: .autostartItem(item), after: nil, detectedAt: TestData.date)))
    }

    @Test func appChangesAlwaysNotify() {
        let app = TestData.installedApp()
        for event in [
            ChangeEvent(kind: .added, before: nil, after: .installedApp(app), detectedAt: TestData.date),
            ChangeEvent(kind: .modified, before: .installedApp(app), after: .installedApp(TestData.installedApp(version: "6.1")),
                        detectedAt: TestData.date),
            ChangeEvent(kind: .removed, before: .installedApp(app), after: nil, detectedAt: TestData.date),
        ] {
            #expect(policy.shouldNotify(event))
        }
    }

    private func listenerEvent(_ kind: ChangeEvent.Kind, before: NetworkListener? = nil, after: NetworkListener?) -> ChangeEvent {
        ChangeEvent(kind: kind, before: before.map(ChangeSubject.networkListener),
                    after: after.map(ChangeSubject.networkListener), detectedAt: TestData.date)
    }

    @Test func listenerNotificationsFollowSetting() {
        let local = TestData.listener(addresses: ["127.0.0.1"])
        let exposed = TestData.listener(addresses: ["0.0.0.0"])
        let exposedOnly = NotificationPolicy(listenerSetting: { .exposedOnly })
        #expect(exposedOnly.shouldNotify(listenerEvent(.added, after: exposed)))
        #expect(!exposedOnly.shouldNotify(listenerEvent(.added, after: local)))
        #expect(exposedOnly.shouldNotify(listenerEvent(.modified, before: local, after: exposed)))
        #expect(!exposedOnly.shouldNotify(listenerEvent(.modified, before: exposed, after: local)))
        #expect(!exposedOnly.shouldNotify(listenerEvent(.removed, before: exposed, after: nil)))

        let all = NotificationPolicy(listenerSetting: { .all })
        #expect(all.shouldNotify(listenerEvent(.added, after: local)))

        let off = NotificationPolicy(listenerSetting: { .off })
        #expect(!off.shouldNotify(listenerEvent(.added, after: exposed)))
        #expect(!off.shouldNotify(listenerEvent(.modified, before: local, after: exposed)))
    }

    @Test func listenerNotificationsDefaultToExposedOnly() {
        #expect(!NotificationPolicy().shouldNotify(listenerEvent(.added, after: TestData.listener(addresses: ["127.0.0.1"]))))
        #expect(NotificationPolicy().shouldNotify(listenerEvent(.added, after: TestData.listener(addresses: ["0.0.0.0"]))))
    }

    @Test func appleListenersAreNeverNotified() {
        let apple = TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple))
        #expect(!NotificationPolicy(listenerSetting: { .all }).shouldNotify(listenerEvent(.added, after: apple)))
        let unverified = TestData.listener("/usr/libexec/rapportd", signing: .unknown)
        #expect(!NotificationPolicy(listenerSetting: { .all }).shouldNotify(listenerEvent(.added, after: unverified)))
        let thirdParty = TestData.listener("/Applications/X.app/Contents/MacOS/X", signing: .unknown)
        #expect(NotificationPolicy().shouldNotify(listenerEvent(.added, after: thirdParty)))
    }

    /// WebRTC/STUN-Clients melden sich nie (`isBenignClientUDP`), ein ad-hoc-signiertes Programm schon.
    @Test func benignClientUDPIsNeverNotified() {
        let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
        let discord = TestData.listener("/Applications/Discord.app/Contents/MacOS/Discord", transport: .udp, port: nil,
                                        signing: developer)
        #expect(!NotificationPolicy(listenerSetting: { .all }).shouldNotify(listenerEvent(.added, after: discord)))
        let local = TestData.listener("/Applications/Discord.app/Contents/MacOS/Discord", transport: .udp, port: nil,
                                      addresses: ["127.0.0.1"], signing: developer)
        #expect(!NotificationPolicy().shouldNotify(listenerEvent(.modified, before: local, after: discord)))
        let adHoc = TestData.listener("/Applications/X.app/Contents/MacOS/X", transport: .udp, port: nil,
                                      addresses: ["0.0.0.0"], signing: SigningInfo(kind: .adHoc))
        #expect(NotificationPolicy().shouldNotify(listenerEvent(.added, after: adHoc)))
    }

    @Test func appleSignedInterpreterIsNotified() {
        let python = TestData.listener("/usr/bin/python3", port: 8000, signing: SigningInfo(kind: .apple))
        #expect(NotificationPolicy(listenerSetting: { .exposedOnly }).shouldNotify(listenerEvent(.added, after: python)))
    }

    @Test func appleSignedNetworkToolIsNotified() {
        let netcat = TestData.listener("/usr/bin/nc", port: 4444, signing: SigningInfo(kind: .apple))
        #expect(NotificationPolicy(listenerSetting: { .exposedOnly }).shouldNotify(listenerEvent(.added, after: netcat)))
    }

    @Test func listenerPreferencesDefaultToExposedOnly() {
        let store = InMemorySettingsStore()
        let preferences = ListenerNotificationPreferences(store: store)
        #expect(preferences.setting == .exposedOnly)
        preferences.setting = .off
        #expect(ListenerNotificationPreferences(store: store).setting == .off)
    }

    @Test func agentEventsAlwaysNotify() {
        let server = TestData.mcpServer(), approval = TestData.autoApproval()
        for event in [
            ChangeEvent(kind: .added, before: nil, after: .mcpServer(server), detectedAt: TestData.date),
            ChangeEvent(kind: .modified, before: .mcpServer(server), after: .mcpServer(TestData.mcpServer(isEnabled: false)),
                        detectedAt: TestData.date),
            ChangeEvent(kind: .removed, before: .mcpServer(server), after: nil, detectedAt: TestData.date),
            ChangeEvent(kind: .added, before: nil, after: .agentAutoApproval(approval), detectedAt: TestData.date),
            ChangeEvent(kind: .removed, before: .agentAutoApproval(approval), after: nil, detectedAt: TestData.date),
        ] {
            #expect(policy.shouldNotify(event))
        }
    }
}
