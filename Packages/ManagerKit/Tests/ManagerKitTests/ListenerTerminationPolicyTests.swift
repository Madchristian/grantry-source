import Foundation
import Testing
@testable import ManagerKit

@Suite struct ListenerTerminationPolicyTests {
    private let policy = ListenerTerminationPolicy(currentUID: 501, ownBundlePath: "/Applications/Grantry.app")

    @Test func appleServiceIsReadOnly() {
        let mdns = TestData.listener("/usr/sbin/mDNSResponder", uid: 65, signing: SigningInfo(kind: .apple))
        #expect(policy.availability(for: mdns, helperState: .ready) == .readOnly(.appleComponent))
    }

    /// `python3 -m http.server` als eigener Benutzer: Apple-signiert, aber kein Apple-Dienst.
    @Test func ownAppleSignedInterpreterIsAvailable() {
        let python = TestData.listener("/usr/bin/python3", uid: 501, signing: SigningInfo(kind: .apple))
        #expect(policy.availability(for: python, helperState: nil) == .available)
    }

    @Test func grantryItselfIsReadOnly() {
        let own = TestData.listener("/Applications/Grantry.app/Contents/MacOS/Grantry", uid: 501)
        #expect(policy.availability(for: own, helperState: .ready) == .readOnly(.ownProcess))
    }

    @Test(arguments: [nil, .notInstalled, .outdated(installed: 3, expected: 4), .unreachable("x")] as [HelperState?])
    func foreignListenerNeedsAReadyHelper(_ state: HelperState?) {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        #expect(policy.availability(for: root, helperState: state) == .readOnly(.helperRequired))
        #expect(policy.availability(for: root, helperState: .ready) == .available)
    }

    @Test func foreignAppleProgramIsReadOnly() {
        let rootPython = TestData.listener("/usr/bin/python3", uid: 0, signing: SigningInfo(kind: .apple))
        #expect(policy.availability(for: rootPython, helperState: .ready) == .readOnly(.foreignAppleProgram))
    }
}
