import Foundation
import Synchronization
import Testing
import TestSupport
@testable import GrantryShared

@Suite struct ProcessTerminationPolicyTests {
    /// Liefert je Aufruf den nächsten Eintrag (danach den letzten) – ein Prozess, der sich zwischen zwei Abfragen ändert.
    /// `liveness` gilt unabhängig von den Antworten – so lässt sich ein laufender Prozess mit gerade nicht bestätigter
    /// Identität (`nil`) von einem beendeten unterscheiden.
    private final class SequencedInspector: ProcessInspecting {
        private let answers: Mutex<[RunningProcess?]>
        private let currentLiveness: ProcessLiveness

        init(_ answers: [RunningProcess?], liveness: ProcessLiveness = .absent) {
            self.answers = Mutex(answers)
            currentLiveness = liveness
        }

        func process(_ pid: pid_t) -> RunningProcess? {
            answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
        }

        func liveness(of pid: pid_t) -> ProcessLiveness { currentLiveness }
    }

    /// Lauschende PIDs, im Test umschaltbar (ein Dienst schließt seinen Lauscher).
    private final class MutableListening: ListeningProcessChecking {
        private let pids: Mutex<Set<pid_t>>

        init(_ pids: Set<pid_t>) { self.pids = Mutex(pids) }

        func set(_ pids: Set<pid_t>) { self.pids.withLock { $0 = pids } }

        func isListening(_ pid: pid_t) -> Bool { pids.withLock { $0.contains(pid) } }
    }

    private static let node = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)

    private func policy(_ processes: [RunningProcess] = [Self.node], signature: AppleSignatureVerdict? = nil)
        -> ProcessTerminationPolicy {
        ProcessTerminationPolicy(
            inspector: FixedProcessInspector(processes), appleSignature: signature.map(FixedAppleSignature.init),
            ownPID: 555, protectedBundlePaths: ["/Applications/Grantry.app"]
        )
    }

    @Test func runningProcessWithSamePathIsAllowed() throws {
        #expect(try policy().validate(pid: 4242, executablePath: "/opt/homebrew/bin/node") == .running(Self.node))
    }

    @Test func endedProcessIsGone() throws {
        #expect(try policy([]).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node") == .gone)
    }

    @Test(arguments: [1, 0, -5, 555, 777] as [pid_t])
    func protectedPIDs(_ pid: pid_t) {
        #expect(throws: ProcessTerminationViolation.protectedProcess(pid)) {
            try policy().validate(pid: pid, executablePath: "/opt/homebrew/bin/node", callerPID: 777)
        }
    }

    @Test func grantryBundleIsProtected() {
        let helper = RunningProcess(
            pid: 600, uid: 0, executablePath: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper", startTime: 1
        )
        #expect(throws: ProcessTerminationViolation.grantryProcess("GrantryHelper")) {
            try policy([helper]).validate(pid: 600, executablePath: helper.executablePath)
        }
    }

    @Test func changedPathOrUserAborts() {
        #expect(throws: ProcessTerminationViolation.processChanged(4242)) {
            try policy().validate(pid: 4242, executablePath: "/usr/local/bin/other")
        }
        #expect(throws: ProcessTerminationViolation.processChanged(4242)) {
            try policy().validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", requiredUID: 502)
        }
    }

    /// PID-Wiederverwendung: gleiches Programm, aber später gestartet – ein anderer Prozess.
    @Test func changedStartTimeAborts() throws {
        #expect(throws: ProcessTerminationViolation.processChanged(4242)) {
            try policy().validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_001)
        }
        #expect(try policy().validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000) == .running(Self.node))
    }

    @Test func appleSignatureIsRejectedAndUnknownAborts() throws {
        #expect(throws: ProcessTerminationViolation.appleSigned("node")) {
            try policy(signature: .apple).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        }
        #expect(throws: ProcessTerminationViolation.signatureUnknown("node")) {
            try policy(signature: .unknown).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        }
        #expect(try policy(signature: .notApple).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node") == .running(Self.node))
    }

    /// Im Helper schützt die Policy das Bundle um das eigene Programm; die Bundle-Prüfung greift vor der
    /// Signaturprüfung. Der Inspektor ist ein Fake, es wird kein echter Prozess gelesen.
    @Test func helperProtectsItsOwnBundle() {
        let app = RunningProcess(pid: 4242, uid: 501, executablePath: "/Applications/Grantry.app/Contents/MacOS/Grantry", startTime: 1)
        let policy = ProcessTerminationPolicy.helper(
            executablePath: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper", inspector: FixedProcessInspector([app])
        )
        #expect(throws: ProcessTerminationViolation.grantryProcess("Grantry")) {
            try policy.validate(pid: 4242, executablePath: "/Applications/Grantry.app/Contents/MacOS/Grantry")
        }
    }

    /// Fail-closed: Ohne bestimmbares eigenes Bundle schützt die Policy nicht still nichts, sondern lehnt alles ab –
    /// noch bevor sie einen Prozess liest.
    @Test(arguments: [nil, "/usr/local/libexec/GrantryHelper"] as [String?])
    func helperWithoutOwnBundleRejectsEverything(_ executablePath: String?) {
        let policy = ProcessTerminationPolicy.helper(executablePath: executablePath)
        #expect(throws: ProcessTerminationViolation.ownBundleUnknown) {
            try policy.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        }
    }

    /// Die Signaturprüfung dauert; danach wird die Identität erneut bestätigt. Eine inzwischen neu vergebene PID
    /// (andere Startzeit) bricht ab, ein inzwischen beendeter Prozess ist `.gone`.
    @Test func identityIsConfirmedAgainAfterTheSignatureCheck() throws {
        let reused = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 2_000)
        func policy(_ answers: [RunningProcess?]) -> ProcessTerminationPolicy {
            ProcessTerminationPolicy(
                inspector: SequencedInspector(answers), appleSignature: FixedAppleSignature(.notApple), ownPID: 555,
                protectedBundlePaths: []
            )
        }
        #expect(throws: ProcessTerminationViolation.processChanged(4242)) {
            try policy([Self.node, reused]).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)
        }
        #expect(try policy([Self.node, nil]).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node") == .gone)
        #expect(try policy([Self.node]).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node") == .running(Self.node))
    }

    /// #153, Codex-Runde 3: Ein `exec` zwischen den beiden Token-Lesungen lässt `process(_:)` `nil` liefern, obwohl PID
    /// und Startzeit bestehen. Das ist kein Exitnachweis: Die Policy meldet `identityUnknown` statt `.gone` (kein
    /// „bereits beendet“ ohne Signal) – bei der ersten Lesung wie bei der Bestätigung nach der Signaturprüfung.
    @Test func unconfirmedIdentityOfARunningProcessIsNotGone() throws {
        let unconfirmed = ProcessTerminationPolicy(
            inspector: FixedProcessInspector([Self.node], unconfirmed: [4242]), ownPID: 555, protectedBundlePaths: []
        )
        #expect(throws: ProcessTerminationViolation.identityUnknown(4242)) {
            try unconfirmed.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)
        }
        let execDuringConfirmation = ProcessTerminationPolicy(
            inspector: SequencedInspector([Self.node, nil], liveness: .running(startTime: 1_000)),
            appleSignature: FixedAppleSignature(.notApple), ownPID: 555, protectedBundlePaths: []
        )
        #expect(throws: ProcessTerminationViolation.identityUnknown(4242)) {
            try execDuringConfirmation.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)
        }
        let undeterminable = ProcessTerminationPolicy(
            inspector: SequencedInspector([nil], liveness: .unknown), ownPID: 555, protectedBundlePaths: []
        )
        #expect(throws: ProcessTerminationViolation.identityUnknown(4242)) {
            try undeterminable.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        }
    }

    /// Meldungen nennen das geprüfte Programm laut Inspektor, nicht den übergebenen Text, und ohne Steuerzeichen.
    @Test func messagesUseTheInspectedPathSingleLine() {
        let odd = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/evil\nFAKE", startTime: 1)
        #expect(throws: ProcessTerminationViolation.appleSigned("node")) {
            try policy(signature: .apple).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node/.")
        }
        #expect(throws: ProcessTerminationViolation.appleSigned("evil FAKE")) {
            try policy([odd], signature: .apple).validate(pid: 4242, executablePath: odd.executablePath)
        }
    }

    // MARK: Nur lauschende Prozesse

    private func listeningPolicy(_ answers: [RunningProcess?] = [Self.node], listening: Set<pid_t>)
        -> ProcessTerminationPolicy {
        ProcessTerminationPolicy(
            inspector: SequencedInspector(answers), appleSignature: FixedAppleSignature(.notApple),
            listening: ListeningRequirement(checker: FixedListeningPIDs(listening)), ownPID: 555, protectedBundlePaths: []
        )
    }

    @Test func listeningProcessIsAllowed() throws {
        #expect(try listeningPolicy(listening: [4242]).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
            == .running(Self.node))
    }

    /// Ein Prozess ohne lauschenden Socket bekommt kein Signal – weder SIGTERM noch SIGKILL.
    @Test(arguments: [false, true])
    func processWithoutListenerIsRejected(force: Bool) {
        #expect(throws: ProcessTerminationViolation.notListening("node")) {
            try listeningPolicy(listening: []).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", force: force)
        }
    }

    /// Wer auf SIGTERM seinen Lauscher schließt und dann hängt, bleibt für SIGKILL zulässig – nur derselbe Prozess
    /// (gleiche Startzeit), und nur SIGKILL.
    @Test func sigkillReachesAProcessThatClosedItsListenerAfterSIGTERM() throws {
        let checker = MutableListening([4242])
        let policy = ProcessTerminationPolicy(
            inspector: FixedProcessInspector([Self.node]), appleSignature: FixedAppleSignature(.notApple),
            listening: ListeningRequirement(checker: checker), ownPID: 555, protectedBundlePaths: []
        )
        #expect(try policy.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000) == .running(Self.node))
        checker.set([])
        #expect(try policy.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000, force: true)
            == .running(Self.node))
        #expect(throws: ProcessTerminationViolation.notListening("node")) {
            try policy.validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)
        }
    }

    /// Ein abgelehntes SIGTERM macht den Prozess nicht für SIGKILL zulässig; ebenso wenig ein anderer Prozess unter
    /// derselben PID (andere Startzeit).
    @Test func sigkillExemptionNeedsAnAcceptedSIGTERMOfTheSameProcess() throws {
        let reused = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 2_000)
        let checker = MutableListening([])
        let requirement = ListeningRequirement(checker: checker)
        func policy(_ process: RunningProcess) -> ProcessTerminationPolicy {
            ProcessTerminationPolicy(
                inspector: FixedProcessInspector([process]), appleSignature: FixedAppleSignature(.notApple),
                listening: requirement, ownPID: 555, protectedBundlePaths: []
            )
        }
        #expect(throws: ProcessTerminationViolation.notListening("node")) {
            try policy(Self.node).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        }
        #expect(throws: ProcessTerminationViolation.notListening("node")) {
            try policy(Self.node).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", force: true)
        }
        checker.set([4242])
        _ = try policy(Self.node).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
        checker.set([])
        #expect(throws: ProcessTerminationViolation.notListening("node")) {
            try policy(reused).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", force: true)
        }
    }

    /// Die Lauscher-Prüfung liegt vor der erneuten Bestätigung der Identität: Ein inzwischen beendeter Prozess ist
    /// `.gone`, ein neu vergebener `processChanged` – nicht „lauscht nicht“.
    @Test func identityIsConfirmedAfterTheListeningCheck() throws {
        let reused = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 2_000)
        #expect(try listeningPolicy([Self.node, nil], listening: []).validate(pid: 4242, executablePath: "/opt/homebrew/bin/node")
            == .gone)
        #expect(throws: ProcessTerminationViolation.processChanged(4242)) {
            try listeningPolicy([Self.node, reused], listening: [4242])
                .validate(pid: 4242, executablePath: "/opt/homebrew/bin/node", startTime: 1_000)
        }
    }

    @Test func notListeningMessage() {
        #expect(ProcessTerminationViolation.notListening("node").errorDescription
            == "node lauscht nicht im Netzwerk – Grantry beendet nur Prozesse lauschender Dienste")
    }

    @Test func enclosingBundleIsTheOutermostApp() {
        #expect(ProcessTerminationPolicy.enclosingAppBundle(ofExecutable: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper")
            == "/Applications/Grantry.app")
        #expect(ProcessTerminationPolicy.enclosingAppBundle(
            ofExecutable: "/Applications/A.app/Contents/Library/LoginItems/B.app/Contents/MacOS/b") == "/Applications/A.app")
        #expect(ProcessTerminationPolicy.enclosingAppBundle(ofExecutable: "/usr/local/bin/node") == nil)
    }

    @Test func bundleMembershipIsByWholeComponents() {
        #expect(ProcessTerminationPolicy.isInBundle("/Applications/Grantry.app/Contents/MacOS/Grantry", bundlePath: "/Applications/Grantry.app"))
        #expect(!ProcessTerminationPolicy.isInBundle("/Applications/Grantry.app.evil/x", bundlePath: "/Applications/Grantry.app"))
    }
}
