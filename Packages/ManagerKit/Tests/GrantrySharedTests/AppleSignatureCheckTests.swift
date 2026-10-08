import Foundation
import Security
import Testing
@testable import GrantryShared

@Suite struct AppleSignatureCheckTests {
    @Test func statusMapping() {
        #expect(SecurityAppleSignatureCheck.verdict(for: errSecSuccess) == .apple)
        #expect(SecurityAppleSignatureCheck.verdict(for: errSecCSReqFailed) == .notApple)
        #expect(SecurityAppleSignatureCheck.verdict(for: errSecCSUnsigned) == .notApple)
        #expect(SecurityAppleSignatureCheck.verdict(for: errSecCSStaticCodeNotFound) == .unknown)
    }

    /// Fail-closed: Apple gewinnt, „nicht Apple“ nur bei beiden Prüfungen eindeutig.
    @Test(arguments: [
        (AppleSignatureVerdict.apple, AppleSignatureVerdict.notApple, AppleSignatureVerdict.apple),
        (.notApple, .apple, .apple),
        (.notApple, .notApple, .notApple),
        (.notApple, .unknown, .unknown),
        (.unknown, .notApple, .unknown),
    ])
    func combination(_ running: AppleSignatureVerdict, _ file: AppleSignatureVerdict, _ expected: AppleSignatureVerdict) {
        #expect(SecurityAppleSignatureCheck.combine(running: running, file: file) == expected)
    }

    @Test func systemBinaryAndInterpreterAreApple() {
        #expect(SecurityAppleSignatureCheck.fileVerdict(path: "/bin/sleep") == .apple)
        #expect(SecurityAppleSignatureCheck.fileVerdict(path: "/usr/bin/python3") == .apple)
    }

    @Test func unsignedFileIsNotAppleAndMissingIsUnknown() {
        #expect(SecurityAppleSignatureCheck.fileVerdict(path: "/etc/hosts") == .notApple)
        #expect(SecurityAppleSignatureCheck.fileVerdict(path: "/nonexistent/grantry-test") == .unknown)
    }

    @Test func runningLaunchdIsApple() {
        #expect(SecurityAppleSignatureCheck().verdict(pid: 1, executablePath: "/sbin/launchd") == .apple)
    }
}
