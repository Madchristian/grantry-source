import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerTests {
    @Test(arguments: [
        (["127.0.0.1"], ListenerReachability.thisMac),
        (["::1", "127.0.0.1"], .thisMac),
        (["::ffff:127.0.0.1"], .thisMac),
        (["127.0.0.53"], .thisMac),
        (["0.0.0.0"], .network(allInterfaces: true)),
        (["::"], .network(allInterfaces: true)),
        (["*"], .network(allInterfaces: true)),
        (["192.168.1.5"], .network(allInterfaces: false)),
        (["fe80::1%en0"], .network(allInterfaces: false)),
        (["127.0.0.1", "192.168.1.5"], .network(allInterfaces: false)),
        (["192.168.1.5", "::"], .network(allInterfaces: true)),
        ([], .network(allInterfaces: false)),
    ])
    func reachabilityFromAddresses(addresses: [String], expected: ListenerReachability) {
        #expect(ListenerReachability(addresses: addresses) == expected)
    }

    @Test func ephemeralPortsAreVariable() {
        #expect(ListenerPort.isEphemeral(49152))
        #expect(ListenerPort.isEphemeral(65535))
        #expect(!ListenerPort.isEphemeral(49151))
        #expect(!ListenerPort.isEphemeral(3000))
    }

    @Test func idCombinesProgramUserTransportAndPort() {
        #expect(TestData.listener().id == "/opt/homebrew/bin/node|501|tcp|3000")
        #expect(TestData.listener(port: nil).id == "/opt/homebrew/bin/node|501|tcp|wechselnd")
    }

    @Test func reachabilityChangeIsReported() {
        let local = TestData.listener(addresses: ["127.0.0.1"])
        let exposed = TestData.listener(addresses: ["0.0.0.0"])
        #expect(local.hasSignificantChanges(comparedTo: exposed))
        #expect(local.reportsChange(to: exposed))
    }

    @Test func addressesAndTimesAreNotSignificant() {
        let first = TestData.listener(addresses: ["0.0.0.0"], ancestors: ["/a"])
        let later = TestData.listener(addresses: ["0.0.0.0", "::"], ancestors: ["/b"],
                                      lastSeen: TestData.date.addingTimeInterval(60))
        #expect(!first.hasSignificantChanges(comparedTo: later))
    }

    @Test func signingChangeIsStoredButNotReported() {
        let adHoc = TestData.listener(signing: SigningInfo(kind: .adHoc))
        let signed = TestData.listener(signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345"))
        #expect(adHoc.hasSignificantChanges(comparedTo: signed))
        #expect(!adHoc.reportsChange(to: signed))
        #expect(!adHoc.hasSignificantChanges(comparedTo: TestData.listener(signing: .unknown)))
    }

    @Test func userKindIsRelativeToCurrentUser() {
        #expect(ListenerUser(uid: 501, currentUID: 501) == .current)
        #expect(ListenerUser(uid: 0, currentUID: 501) == .root)
        #expect(ListenerUser(uid: 502, currentUID: 501) == .other(uid: 502))
    }

    @Test func olderSnapshotWithoutListenersDecodes() throws {
        let old = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], sourceErrors: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "networkListeners")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.networkListeners.isEmpty)
    }

    @Test func listenersRoundTripThroughSnapshot() throws {
        var snapshot = TestData.networkSnapshot([TestData.listener()])
        snapshot.hasCompleteListenerBaseline = true
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.baselineSources.contains(.networkListeners))
        #expect(decoded.hasCompleteListenerBaseline)
    }

    /// Ältere Snapshots kennen die vollständige Lauscher-Baseline nicht: Die nächste vollständige Lieferung gilt dann
    /// einmal als Baseline.
    @Test func olderSnapshotWithoutCompleteListenerBaselineDecodes() throws {
        let old = TestData.networkSnapshot([TestData.listener()])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "hasCompleteListenerBaseline")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.hasCompleteListenerBaseline)
    }

    /// Die Baseline zählt zur Äquivalenz, damit die erste vollständige Lieferung gespeichert wird.
    @Test func completeListenerBaselineCountsForEquivalence() {
        var complete = TestData.networkSnapshot([TestData.listener()])
        complete.hasCompleteListenerBaseline = true
        #expect(!complete.isEquivalent(to: TestData.networkSnapshot([TestData.listener()])))
        #expect(complete.isEquivalent(to: complete))
    }
}

@Suite struct NetworkListenerAppleServiceTests {
    @Test func appleSignedSystemServiceIsApple() {
        #expect(TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple)).isAppleService)
        #expect(TestData.listener("/usr/libexec/rapportd", signing: .unknown).isAppleService)
    }

    @Test func unverifiedXcodeBundleIsNotApple() {
        let path = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcdevice"
        #expect(!TestData.listener(path, signing: .unknown).isAppleService)
    }

    @Test func interpreterIsNeverApple() {
        let apple = SigningInfo(kind: .apple)
        #expect(!TestData.listener("/usr/bin/python3", signing: apple).isAppleService)
        #expect(!TestData.listener("/usr/bin/ruby", signing: .unknown).isAppleService)
        let frameworkPython = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/"
            + "Resources/Python.app/Contents/MacOS/Python"
        #expect(!TestData.listener(frameworkPython, signing: apple).isAppleService)
    }

    /// `nc -l 4444` oder ein `ssh`-Tunnel lauschen auf Anweisung: Die Apple-Signatur des Werkzeugs belegt keinen
    /// Systemdienst – auch nicht ohne Signaturergebnis im Systempfad.
    @Test func networkToolIsNeverApple() {
        #expect(!TestData.listener("/usr/bin/nc", port: 4444, signing: SigningInfo(kind: .apple)).isAppleService)
        #expect(!TestData.listener("/usr/bin/ssh", port: 1080, signing: .unknown).isAppleService)
        #expect(TestData.listener("/usr/sbin/sshd", uid: 0, port: 22, signing: SigningInfo(kind: .apple)).isAppleService)
    }
}

@Suite struct NetworkToolTests {
    @Test func matchesGenericListeningTools() {
        #expect(NetworkTool.matches("/usr/bin/nc"))
        #expect(NetworkTool.matches("/usr/bin/ssh"))
        #expect(NetworkTool.matches("/opt/homebrew/bin/NC"))
    }

    @Test func doesNotMatchDaemonsOrSimilarNames() {
        #expect(!NetworkTool.matches("/usr/sbin/sshd"))
        #expect(!NetworkTool.matches("/usr/bin/ncal"))
        #expect(!NetworkTool.matches("/usr/bin/ssh-agent"))
        #expect(!NetworkTool.matches("/usr/libexec/rapportd"))
    }
}
