import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerRulesTests {
    private let rule = ExposedListenerRule(home: "/Users/test")
    private let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)

    private func severity(_ listener: NetworkListener) -> RiskFinding.Severity? {
        rule.evaluate(TestData.networkSnapshot([listener])).first?.severity
    }

    @Test func loopbackIsNotFlagged() {
        #expect(severity(TestData.listener(addresses: ["127.0.0.1"])) == nil)
    }

    @Test func appleSignedIsNotFlagged() {
        #expect(severity(TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple))) == nil)
    }

    @Test func appleServiceWithoutVerifiableSignatureIsNotFlagged() {
        #expect(severity(TestData.listener("/usr/libexec/rapportd", signing: .unknown)) == nil)
    }

    @Test func appleSignedInterpreterIsHigh() {
        let python = TestData.listener("/usr/bin/python3", port: 8000, signing: SigningInfo(kind: .apple))
        #expect(severity(python) == .high)
    }

    /// `nc -l 4444` auf allen Schnittstellen: Apple-signiert, aber ein Werkzeug, das auf Anweisung lauscht.
    @Test func appleSignedNetworkToolIsHigh() {
        let netcat = TestData.listener("/usr/bin/nc", port: 4444, signing: SigningInfo(kind: .apple))
        let finding = rule.evaluate(TestData.networkSnapshot([netcat])).first
        #expect(finding?.severity == .high)
        #expect(finding?.message == "nc ist von außen erreichbar (Port 4444/tcp) – Netzwerkwerkzeug")
        #expect(severity(TestData.listener("/usr/bin/ssh", port: 1080, signing: .unknown)) == .high)
    }

    @Test func signedThirdPartyIsMedium() {
        #expect(severity(TestData.listener("/Applications/Orca.app/Contents/MacOS/Orca", port: 6768, signing: developer))
            == .medium)
        #expect(severity(TestData.listener("/Applications/X.app/Contents/MacOS/X", signing: .unknown)) == .medium)
    }

    @Test func unsignedInterpreterOrWritableLocationIsHigh() {
        #expect(severity(TestData.listener("/Applications/X.app/Contents/MacOS/X", signing: SigningInfo(kind: .unsigned))) == .high)
        #expect(severity(TestData.listener("/opt/homebrew/bin/node", signing: developer)) == .high)
        #expect(severity(TestData.listener("/private/tmp/server", signing: developer)) == .high)
        #expect(severity(TestData.listener("/Users/test/Downloads/tool", signing: developer)) == .high)
        #expect(severity(TestData.listener("/var/tmp/server", signing: developer)) == .high)
        #expect(severity(TestData.listener("/private/var/tmp/server", signing: developer)) == .high)
        #expect(severity(TestData.listener("/Users/Shared/server", signing: developer)) == .high)
    }

    @Test func homeWithTrailingSlashStillMatchesDownloads() {
        let listener = TestData.listener("/Users/test/Downloads/tool", signing: developer)
        #expect(ExposedListenerRule(home: "/Users/test/").evaluate(TestData.networkSnapshot([listener])).first?.severity
            == .high)
    }

    @Test func mdnsOfDevelopmentBuildIsFlagged() {
        let mdns = TestData.listener("/Applications/X.app/Contents/MacOS/X", transport: .udp, port: 5353,
                                     signing: SigningInfo(kind: .development, teamID: "TEAMA12345"))
        #expect(severity(mdns) == .medium)
    }

    @Test func mdnsOfSignedAppIsIgnored() {
        let mdns = TestData.listener("/Applications/X.app/Contents/MacOS/X", transport: .udp, port: 5353, signing: developer)
        #expect(severity(mdns) == nil)
        let unsignedMDNS = TestData.listener("/tmp/x", transport: .udp, port: 5353, signing: SigningInfo(kind: .adHoc))
        #expect(severity(unsignedMDNS) == .high)
    }

    /// WebRTC/STUN-Clients (Discord, Chrome) lauschen auf wechselnden UDP-Ports: regulär signiert kein Befund.
    @Test func variableUDPOfSignedAppIsIgnored() {
        let discord = TestData.listener(
            "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
            transport: .udp, port: nil, signing: developer
        )
        #expect(severity(discord) == nil)
    }

    @Test func variableUDPOfAdHocProgramIsHigh() {
        let backdoor = TestData.listener("/Applications/X.app/Contents/MacOS/X", transport: .udp, port: nil,
                                         addresses: ["0.0.0.0"], signing: SigningInfo(kind: .adHoc))
        #expect(severity(backdoor) == .high)
        let development = TestData.listener("/Applications/X.app/Contents/MacOS/X", transport: .udp, port: nil,
                                            signing: SigningInfo(kind: .development, teamID: "TEAMA12345"))
        #expect(severity(development) == .medium)
    }

    /// Ein fester Port im Ephemeralbereich (WireGuard 51820) ist ein Dienst, kein Client – über den ganzen Pfad
    /// Rohsocket → Mapper → Bewertung, denn der Mapper entscheidet, ob der Port als „wechselnd“ zusammenfällt.
    @Test func fixedUDPPortOfSignedAppIsMedium() throws {
        let wireGuard = "/Applications/WireGuard.app/Contents/MacOS/WireGuard"
        let mapper = NetworkListenerMapper(inspector: RecordingSigningInspector(result: developer))
        func listener(port: UInt16, systemAssigned: Bool) throws -> NetworkListener {
            try #require(mapper.listeners(from: [ListeningSocket(
                pid: 10, uid: 501, executablePath: wireGuard, transport: .udp, localAddress: "0.0.0.0", localPort: port,
                hasSystemAssignedPort: systemAssigned
            )], at: TestData.date).first)
        }
        let fixed = try listener(port: 51820, systemAssigned: false)
        #expect(fixed.port == 51820)
        #expect(severity(fixed) == .medium)
        #expect(fixed.countsAsExposed)
        #expect(NotificationPolicy().shouldNotify(
            ChangeEvent(kind: .added, before: nil, after: .networkListener(fixed), detectedAt: TestData.date)))

        let random = try listener(port: 52874, systemAssigned: true)
        #expect(random.port == nil)
        #expect(severity(random) == nil)
    }

    @Test func findingNamesProgramAndPort() {
        let finding = rule.evaluate(TestData.networkSnapshot([TestData.listener()])).first
        #expect(finding?.rule == .exposedListener)
        #expect(finding?.recordID == TestData.listener().id)
        #expect(finding?.message == "node ist von außen erreichbar (Port 3000/tcp) – Interpreter, nicht regulär signiert")
    }

    @Test func findingNamesVariablePortWithoutNestedParentheses() {
        let listener = TestData.listener("/Applications/X.app/Contents/MacOS/X", port: nil, signing: developer)
        #expect(rule.evaluate(TestData.networkSnapshot([listener])).first?.message
            == "X ist von außen erreichbar (wechselnder Port, tcp)")
    }

    @Test func standardEvaluatorIncludesRule() {
        let findings = RiskEvaluator.standard.evaluate(TestData.networkSnapshot([TestData.listener()]))
        #expect(findings.contains { $0.rule == .exposedListener })
    }
}
