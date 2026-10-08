import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerPresentationTests {
    private let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
    private let python = TestData.listener("/usr/bin/python3", signing: SigningInfo(kind: .apple))

    @Test func bundleIsOutermostOwnBundle() {
        let helper = TestData.listener(
            "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
            ancestors: ["/Applications/Discord.app/Contents/MacOS/Discord"]
        )
        let row = NetworkListenerRow(helper)
        #expect(row.bundlePath == "/Applications/Discord.app")
        #expect(row.title == "Discord")
        #expect(row.launchingAppPath == nil)
        #expect(NetworkListenerRow(TestData.listener("/usr/sbin/sshd")).bundlePath == nil)
    }

    /// Ein `python3` aus iTerm heißt `python3`, nicht „iTerm“; die Eltern-App bleibt als Herkunft erhalten.
    @Test func titleIgnoresLaunchingApp() {
        let child = TestData.listener("/usr/bin/python3", ancestors: ["/bin/zsh", "/Applications/iTerm.app/Contents/MacOS/iTerm2"])
        let row = NetworkListenerRow(child)
        #expect(row.title == "python3")
        #expect(row.bundlePath == nil)
        #expect(row.launchingAppPath == "/Applications/iTerm.app")
        #expect(row.launchingAppName == "iTerm")
        #expect(row.subtitle == "\(child.portText) · \(child.reachabilityText) · gestartet aus iTerm")
    }

    /// „Ohne zugehörige App“ meint ein eigenes Bundle; eine Eltern-App zählt nicht.
    @Test func withoutAppFilterIgnoresLaunchingApp() {
        let child = TestData.listener("/opt/homebrew/bin/node", ancestors: ["/Applications/Warp.app/Contents/MacOS/stable"])
        let app = TestData.listener("/Applications/A.app/Contents/MacOS/A", signing: developer)
        var filter = NetworkListenerFilter()
        filter.onlyWithoutApp = true
        #expect(NetworkListenerPresenter.rows([child, app], severity: { _ in nil }, query: "", filter: filter)
            .map(\.id) == [child.id])
        #expect(NetworkListenerPresenter.rows([child], severity: { _ in nil }, query: "Warp", filter: NetworkListenerFilter())
            .count == 1)
    }

    @Test func systemServicesAreHiddenByDefault() {
        let apple = TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple))
        let node = TestData.listener()
        let rows = NetworkListenerPresenter.rows([apple, node], severity: { _ in nil }, query: "", filter: NetworkListenerFilter())
        #expect(rows.map(\.id) == [node.id])
        var withSystem = NetworkListenerFilter()
        withSystem.showsSystemServices = true
        #expect(NetworkListenerPresenter.rows([apple, node], severity: { _ in nil }, query: "", filter: withSystem).count == 2)
    }

    /// Ohne prüfbare Signatur gilt ein Dienst im Systemverzeichnis trotzdem als Systemdienst (`isAppleService`).
    @Test func unverifiedSystemServiceIsHiddenByDefault() {
        let rapportd = TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .unknown))
        #expect(NetworkListenerPresenter.rows([rapportd], severity: { _ in nil }, query: "", filter: NetworkListenerFilter()).isEmpty)
    }

    /// Ein Apple-signierter Interpreter ist kein Systemdienst: sichtbar und auch bei „Nicht von Apple“.
    @Test func appleSignedInterpreterStaysVisible() {
        #expect(NetworkListenerPresenter.rows([python], severity: { _ in nil }, query: "", filter: NetworkListenerFilter())
            .map(\.id) == [python.id])
        var filter = NetworkListenerFilter()
        filter.onlyNonApple = true
        #expect(NetworkListenerPresenter.rows([python], severity: { _ in nil }, query: "", filter: filter).count == 1)
    }

    @Test func filtersCombine() {
        let local = TestData.listener("/Applications/A.app/Contents/MacOS/A", addresses: ["127.0.0.1"], signing: developer)
        let exposedNode = TestData.listener()
        var filter = NetworkListenerFilter()
        filter.onlyExposed = true
        #expect(NetworkListenerPresenter.rows([local, exposedNode], severity: { _ in nil }, query: "", filter: filter)
            .map(\.id) == [exposedNode.id])
        filter = NetworkListenerFilter()
        filter.onlyInterpreters = true
        #expect(NetworkListenerPresenter.rows([local, exposedNode], severity: { _ in nil }, query: "", filter: filter).count == 1)
        filter = NetworkListenerFilter()
        filter.onlyWithoutApp = true
        #expect(NetworkListenerPresenter.rows([local, exposedNode], severity: { _ in nil }, query: "", filter: filter)
            .map(\.id) == [exposedNode.id])
        #expect(filter.isActive)
        #expect(!NetworkListenerFilter().isActive)
    }

    @Test func searchMatchesNamePathAndPort() {
        let node = TestData.listener()
        #expect(NetworkListenerPresenter.rows([node], severity: { _ in nil }, query: "3000", filter: NetworkListenerFilter()).count == 1)
        #expect(NetworkListenerPresenter.rows([node], severity: { _ in nil }, query: "homebrew", filter: NetworkListenerFilter()).count == 1)
        #expect(NetworkListenerPresenter.rows([node], severity: { _ in nil }, query: "python", filter: NetworkListenerFilter()).isEmpty)
    }

    @Test func rowsSortExposedFirstThenName() {
        let a = TestData.listener("/x/alpha", addresses: ["127.0.0.1"])
        let z = TestData.listener("/x/zulu", addresses: ["0.0.0.0"])
        #expect(NetworkListenerPresenter.rows([a, z], severity: { _ in nil }, query: "", filter: NetworkListenerFilter())
            .map(\.title) == ["zulu", "alpha"])
    }

    @Test func rowCarriesTitleSubtitleAndSeverity() {
        let helper = TestData.listener("/Applications/Discord.app/Contents/MacOS/Discord")
        let row = NetworkListenerPresenter.rows([helper], severity: { _ in .high }, query: "", filter: NetworkListenerFilter()).first
        #expect(row?.title == "Discord")
        #expect(row?.severity == .high)
        #expect(row?.subtitle == "\(helper.portText) · \(helper.reachabilityText)")
    }

    @Test func singleRowForDetailIgnoresFilter() {
        let apple = TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple))
        let row = NetworkListenerRow(apple)
        #expect(row.title == "rapportd")
        #expect(row.bundlePath == nil)
        #expect(row.launchingAppPath == nil)
        #expect(row.severity == nil)
        #expect(NetworkListenerRow(TestData.listener(), severity: .medium).severity == .medium)
    }

    @Test func launchedByAutostartItem() {
        var item = TestData.item("dev.example.mcp")
        item.program = "/opt/homebrew/bin/node"
        let overview = NetworkOverview.make(snapshot: TestData.networkSnapshot([TestData.listener()], items: [item]))
        #expect(overview.launchedBy(TestData.listener())?.id == item.id)
    }

    @Test func firewallHint() {
        var snapshot = TestData.networkSnapshot([TestData.listener()])
        snapshot.securityChecks = [TestData.securityCheck(TestData.firewallOff, state: .critical)]
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == .firewallOff(exposedCount: 1))
        snapshot.securityChecks = [TestData.securityCheck(TestData.firewallOn, state: .good)]
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == .firewallOn)
        snapshot.securityChecks = []
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == nil)
    }

    /// Ohne von außen erreichbare Lauscher ist jeder Firewall-Hinweis überflüssig – auch bei eingeschalteter Firewall.
    @Test func noFirewallHintWithoutExposedListeners() {
        var snapshot = TestData.networkSnapshot([TestData.listener(addresses: ["127.0.0.1"])])
        snapshot.securityChecks = [TestData.securityCheck(TestData.firewallOn, state: .good)]
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == nil)
        snapshot.securityChecks = [TestData.securityCheck(TestData.firewallOff, state: .critical)]
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == nil)
    }

    /// Fortgeschriebene Fakten einer fehlgeschlagenen Prüfung ergeben keinen Hinweis (wie `SecurityOverview`).
    @Test func failedFirewallCheckGivesNoHint() {
        var snapshot = TestData.networkSnapshot([TestData.listener()])
        var failed = SecurityCheck.failed(.firewall, detail: "Zeitüberschreitung")
        failed.facts = TestData.firewallOff
        failed.lastKnownState = .critical
        snapshot.securityChecks = [failed]
        #expect(NetworkOverview.make(snapshot: snapshot).firewallHint == nil)
    }

    @Test func searchIgnoresSurroundingNewlines() {
        #expect(NetworkListenerPresenter.rows([TestData.listener()], severity: { _ in nil }, query: "3000\n",
                                              filter: NetworkListenerFilter()).count == 1)
    }

    @Test func exposedCountIgnoresAppleAndLoopback() {
        let snapshot = TestData.networkSnapshot([
            TestData.listener(), TestData.listener("/a", addresses: ["127.0.0.1"]),
            TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple)),
        ])
        #expect(NetworkOverview.make(snapshot: snapshot).exposedCount == 1)
    }

    /// Clients mit WebRTC/STUN (`isBenignClientUDP`) bleiben in der Liste, zählen aber nicht als von außen erreichbar.
    @Test func exposedCountIgnoresBenignClientUDP() {
        let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
        let discord = TestData.listener("/Applications/Discord.app/Contents/MacOS/Discord", transport: .udp, port: nil,
                                        signing: developer)
        let overview = NetworkOverview.make(snapshot: TestData.networkSnapshot([discord]))
        #expect(overview.exposedCount == 0)
        #expect(overview.listeners == [discord])
        #expect(NetworkListenerPresenter.rows([discord], severity: { _ in nil }, query: "", filter: NetworkListenerFilter())
            .count == 1)
    }

    /// Klick auf die Kachel „Von außen erreichbar“ (`onlyExposed`) zeigt genau `exposedCount` Zeilen: ohne harmlose
    /// UDP-Clients, ohne Loopback und – solange Systemdienste ausgeblendet sind – ohne Dienste von macOS.
    @Test func exposedFilterMatchesExposedCount() {
        let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
        let listeners = [
            TestData.listener(), python, TestData.listener("/a", addresses: ["127.0.0.1"]),
            TestData.listener("/usr/libexec/rapportd", signing: SigningInfo(kind: .apple)),
            TestData.listener("/Applications/Discord.app/Contents/MacOS/Discord", transport: .udp, port: nil, signing: developer),
        ]
        var filter = NetworkListenerFilter()
        filter.onlyExposed = true
        let rows = NetworkListenerPresenter.rows(listeners, severity: { _ in nil }, query: "", filter: filter)
        #expect(rows.count == NetworkOverview.make(snapshot: TestData.networkSnapshot(listeners)).exposedCount)
        #expect(Set(rows.map(\.id)) == [TestData.listener().id, python.id])
        filter.showsSystemServices = true
        #expect(NetworkListenerPresenter.rows(listeners, severity: { _ in nil }, query: "", filter: filter).count == 3)
    }

    /// Ein launchd-Autostart einer App startet auch ein Programm, das aus ihr heraus läuft (Vermutung).
    @Test func launchedByUsesLaunchingApp() {
        var item = TestData.item("com.example.warp")
        item.program = "/Applications/Warp.app/Contents/MacOS/stable"
        let child = TestData.listener("/opt/homebrew/bin/node", ancestors: ["/Applications/Warp.app/Contents/MacOS/stable"])
        let overview = NetworkOverview.make(snapshot: TestData.networkSnapshot([child], items: [item]))
        #expect(overview.launchedBy(child)?.id == item.id)
    }

    @Test func exposedCountIncludesAppleSignedInterpreter() {
        #expect(NetworkOverview.make(snapshot: TestData.networkSnapshot([python])).exposedCount == 1)
    }

    @Test func coverageReasonsComeFromSource() {
        let snapshot = TestData.networkSnapshot([])
        var limited = snapshot
        limited.sourceLimitations = [SourceLimitation(source: .networkListeners, message: "eingeschränkt")]
        let coverage = CoverageOverview(snapshot: limited)[.network]
        #expect(coverage?.state == .partial)
        #expect(coverage?.reasons(now: TestData.date) == ["eingeschränkt"])
    }

    @Test func presentationCarriesNetworkAndFlagsIt() {
        let snapshot = TestData.networkSnapshot([TestData.listener()])
        let finding = RiskFinding(rule: .exposedListener, severity: .medium, recordID: TestData.listener().id, message: "x")
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [finding], events: [], recentAdditions: [],
                                                     now: TestData.date)
        #expect(presentation.network.listeners == snapshot.networkListeners)
        #expect(presentation.highestSeverity == .medium)
        #expect(presentation.flaggedArea == .network)
    }
}
