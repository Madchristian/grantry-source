import Testing
@testable import ManagerKit

@Suite struct UnsignedProgramRuleTests {
    private func item(_ label: String, signing: SigningInfo?, owner: AppIdentity? = nil) -> AutostartItem {
        var item = TestData.item(label, owner: owner)
        item.programSigning = signing
        return item
    }

    @Test func unsignedProgramIsMediumAndAdHocIsLow() {
        let snapshot = TestData.snapshot(items: [
            item("unsigned", signing: SigningInfo(kind: .unsigned)),
            item("brew", signing: SigningInfo(kind: .adHoc)),
        ])
        let findings = UnsignedProgramRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["launchAgent|user|unsigned", "launchAgent|user|brew"])
        #expect(findings.map(\.severity) == [.medium, .low])
        #expect(findings.allSatisfy { $0.rule == .unsignedProgram })
        #expect(findings.map(\.message) == [
            "Programm von unsigned ist nicht signiert", "Programm von brew ist nur ad hoc signiert",
        ])
    }

    /// `.unknown` (Signatur nicht lesbar) erzeugt bewusst keinen Befund – auch bei Programmen außerhalb der Apple-Pfade.
    @Test(arguments: [SigningInfo.Kind.apple, .appStore, .developerID, .development, .unknown])
    func signedOrUnknownProgramsAreFine(kind: SigningInfo.Kind) {
        let snapshot = TestData.snapshot(items: [item("x", signing: SigningInfo(kind: kind))])
        #expect(UnsignedProgramRule().evaluate(snapshot).isEmpty)
    }

    @Test func itemsWithoutProgramSigningAreSkipped() {
        #expect(UnsignedProgramRule().evaluate(TestData.snapshot(items: [item("x", signing: nil)])).isEmpty)
    }

    /// Die Signatur einer Eigentümer-App bewertet `UnsignedClientRule`.
    @Test func itemsWithAnOwnerAreSkipped() {
        let snapshot = TestData.snapshot(items: [item("x", signing: SigningInfo(kind: .unsigned), owner: TestData.app())])
        #expect(UnsignedProgramRule().evaluate(snapshot).isEmpty)
    }

    /// Echte Apple-Herkunft: Programm Apple-signiert. Bei bekannter Signatur zählt nur sie – ein ad hoc signiertes
    /// Programm unter `/usr/libexec` ist nicht von Apple.
    @Test func appleProgramsAreSkippedButKnownSignatureOutweighsPath() {
        var appleSigned = item("tool", signing: SigningInfo(kind: .apple))
        appleSigned.program = "/usr/libexec/tool"
        var adHocUnderUsr = item("other", signing: SigningInfo(kind: .adHoc))
        adHocUnderUsr.program = "/usr/libexec/other"
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [appleSigned, adHocUnderUsr]))
        #expect(findings.map(\.recordID) == [adHocUnderUsr.id])
    }

    /// Ein Systeminterpreter mit Argumenten führt ein Skript aus, dessen Herkunft keine Signatur belegt (**niedrig**,
    /// wie ad hoc signierte Programme) – solange der Eintrag sich nicht als Apple-Komponente ausgibt.
    @Test func interpreterLaunchIsLow() {
        var shell = item("com.example.shell", signing: SigningInfo(kind: .apple))
        shell.program = "/bin/sh"
        shell.launchesInterpreter = true
        var unsignedInterpreter = item("com.example.py", signing: SigningInfo(kind: .unsigned))
        unsignedInterpreter.program = "/Users/test/.venv/bin/python3"
        unsignedInterpreter.launchesInterpreter = true
        var bareName = item("com.example.node", signing: nil)
        bareName.program = "node"
        bareName.launchesInterpreter = true
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [shell, unsignedInterpreter, bareName]))
        #expect(findings.map(\.recordID) == [shell.id, unsignedInterpreter.id, bareName.id])
        #expect(findings.map(\.severity) == [.low, .medium, .low])
        #expect(findings.map(\.message) == [
            "Programm von com.example.shell startet ein Skript über einen Systeminterpreter",
            "Programm von com.example.py ist nicht signiert",
            "Programm von com.example.node startet ein Skript über einen Systeminterpreter",
        ])
    }

    /// Ein Interpreter-Start unter `com.apple.`-Label, dessen Plist außerhalb der Apple-Pfade liegt, ist getarnt:
    /// mindestens **mittel** samt Hinweis. Liegt die Plist an einem Apple-Pfad, ist es keine Tarnung (**niedrig**).
    @Test func disguisedInterpreterLaunchIsMedium() {
        var disguised = item("com.apple.update.agent", signing: SigningInfo(kind: .apple))
        disguised.program = "/bin/sh"
        disguised.launchesInterpreter = true
        var inApplePlist = disguised
        inApplePlist.label = "com.apple.genuine.agent"
        inApplePlist.plistPath = "/System/Library/LaunchAgents/com.apple.genuine.agent.plist"
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [disguised, inApplePlist]))
        #expect(findings.map(\.recordID) == [disguised.id, inApplePlist.id])
        #expect(findings.map(\.severity) == [.medium, .low])
        #expect(findings.map(\.message) == [
            "Programm von com.apple.update.agent startet ein Skript über einen Systeminterpreter"
                + " und gibt sich als Apple-Komponente aus",
            "Programm von com.apple.genuine.agent startet ein Skript über einen Systeminterpreter",
        ])
    }

    /// Ein `com.apple.`-Label schützt kein unsigniertes Programm außerhalb der Apple-Pfade – klassische Adware-Tarnung.
    @Test func disguisedAppleLabelDoesNotHideAnUnsignedProgram() {
        let disguised = TestData.disguisedAppleAgent
        var inSystemPlist = TestData.disguisedAppleAgent
        inSystemPlist.label = "com.apple.other"
        inSystemPlist.domain = .system
        inSystemPlist.plistPath = "/Library/LaunchAgents/com.apple.other.plist"
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [disguised, inSystemPlist]))
        #expect(findings.map(\.recordID) == [disguised.id, inSystemPlist.id])
        #expect(findings.first?.message == "Programm von com.apple.update.agent ist nicht signiert")
        #expect(findings.allSatisfy { $0.severity == .medium })
    }

    /// Skript, dessen Interpreter `interpreter` die Signatur `signing` trägt; bei `env` mit `arguments` und dem über
    /// den Standard-PATH aufgelösten Programm `resolved`.
    private static func script(
        _ interpreter: String, signing: SigningInfo?, arguments: [String] = [],
        resolved: ProgramScript.ResolvedProgram? = nil
    ) -> ProgramScript {
        ProgramScript(interpreter: interpreter, arguments: arguments, interpreterSigning: signing, resolvedEnvProgram: resolved)
    }

    private static func resolved(_ path: String, _ kind: SigningInfo.Kind?) -> ProgramScript.ResolvedProgram {
        ProgramScript.ResolvedProgram(path: path, signing: kind.map { SigningInfo(kind: $0) })
    }

    private static let appleShell = script("/bin/sh", signing: SigningInfo(kind: .apple))

    /// Ein Skript (`#!`) trägt meist keine Signatur – mit einem Apple-Interpreter ist es daher nur **niedrig**, ein
    /// unsigniertes Binärprogramm bleibt **mittel**.
    @Test func unsignedScriptIsLow() {
        var script = item("com.example.script", signing: SigningInfo(kind: .unsigned))
        script.programScript = Self.appleShell
        let binary = item("com.example.binary", signing: SigningInfo(kind: .unsigned))
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [script, binary]))
        #expect(findings.map(\.recordID) == [script.id, binary.id])
        #expect(findings.map(\.severity) == [.low, .medium])
        #expect(findings.first?.message == "Programm von com.example.script ist ein Skript (ohne Signatur)")
    }

    /// Der Interpreter entscheidet: Apple-Herkunft (`/bin/zsh`, `/usr/bin/env` mit bekanntem Interpreter) ist niedrig;
    /// ein beliebiges Programm als Interpreter (`#!/Users/…/evil`, unsigniert oder nicht prüfbar) oder `env` mit
    /// unbekanntem Programm wiegt wie ein unsigniertes Programm (**mittel**). Ein ad hoc signierter Interpreter
    /// (Homebrew-`bash`) wiegt wie ein ad hoc signiertes Programm (**niedrig**) – das Skript führt nichts aus, was
    /// nicht auch ein ad hoc signiertes Programm direkt dürfte.
    @Test(arguments: [
        (script("/bin/zsh", signing: SigningInfo(kind: .apple)), RiskFinding.Severity.low, "ist ein Skript (ohne Signatur)"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["python3"],
                resolved: resolved("/usr/bin/python3", .apple)), .low, "ist ein Skript (ohne Signatur)"),
        (script("/usr/bin/env", signing: nil, arguments: ["zsh"], resolved: resolved("/bin/zsh", .apple)), .medium,
         "ist ein Skript mit unbekanntem Interpreter /usr/bin/env zsh"),
        // Nicht aufgelöst: Optionen, Zuweisungen, eigener PATH der Plist oder nicht im Standard-PATH.
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["-S", "-P/Users/x", "python3"]), .medium,
         "ist ein Skript mit unbekanntem Interpreter /usr/bin/env -S -P/Users/x python3"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["python3"]), .medium,
         "ist ein Skript mit unbekanntem Interpreter /usr/bin/env python3"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["x"], resolved: resolved("/usr/bin/x", nil)),
         .medium, "ist ein Skript mit unbekanntem Interpreter /usr/bin/env x"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["x"], resolved: resolved("/usr/bin/x", .unsigned)),
         .medium, "ist ein Skript mit unbekanntem Interpreter /usr/bin/env x"),
        (script("/Library/Frameworks/Python.framework/Versions/3.13/bin/python3", signing: SigningInfo(kind: .developerID)),
         .low, "ist ein Skript (ohne Signatur)"),
        (script("/opt/homebrew/bin/bash", signing: SigningInfo(kind: .adHoc)), .low,
         "ist ein Skript mit nur ad hoc signiertem Interpreter /opt/homebrew/bin/bash"),
        (script("/Users/x/Library/.x/evil", signing: SigningInfo(kind: .unsigned)), .medium,
         "ist ein Skript mit unbekanntem Interpreter /Users/x/Library/.x/evil"),
        (script("/Users/x/Library/.x/bash", signing: SigningInfo(kind: .unsigned)), .medium,
         "ist ein Skript mit unbekanntem Interpreter /Users/x/Library/.x/bash"),
        (script("/Users/x/Library/.x/evil", signing: .unknown), .medium,
         "ist ein Skript mit unbekanntem Interpreter /Users/x/Library/.x/evil"),
        (script("/Users/x/Library/.x/gone", signing: nil), .medium,
         "ist ein Skript mit unbekanntem Interpreter /Users/x/Library/.x/gone"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple), arguments: ["evil"]), .medium,
         "ist ein Skript mit unbekanntem Interpreter /usr/bin/env evil"),
        (script("/usr/bin/env", signing: SigningInfo(kind: .apple)), .medium,
         "ist ein Skript mit unbekanntem Interpreter /usr/bin/env"),
        (script("/Users/x/bin/env", signing: SigningInfo(kind: .unsigned), arguments: ["python3"],
                resolved: resolved("/usr/bin/python3", .apple)), .medium,
         "ist ein Skript mit unbekanntem Interpreter /Users/x/bin/env python3"),
        (script("", signing: nil), .medium, "ist ein Skript ohne Angabe des Interpreters"),
        // Ohne geprüfte Signatur zählt der Ort nicht: `/usr/bin/zsh\r` (CRLF-Datei) gibt es nicht.
        (script("/usr/bin/zsh\r", signing: nil), .medium, "ist ein Skript mit unbekanntem Interpreter /usr/bin/zsh\\r"),
        (script("/usr/bin/zsh", signing: nil), .medium, "ist ein Skript mit unbekanntem Interpreter /usr/bin/zsh"),
        (script("/usr/bin/zsh", signing: .unknown), .medium, "ist ein Skript mit unbekanntem Interpreter /usr/bin/zsh"),
        // Relative Interpreter löst der Kernel gegen das Arbeitsverzeichnis auf – nie belegt.
        (script("bin/sh", signing: SigningInfo(kind: .apple)), .medium, "ist ein Skript mit unbekanntem Interpreter bin/sh"),
    ])
    func scriptSeverityFollowsItsInterpreter(_ script: ProgramScript, severity: RiskFinding.Severity, statement: String) {
        var item = item("com.example.script", signing: SigningInfo(kind: .unsigned))
        item.programScript = script
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [item]))
        #expect(findings.map(\.severity) == [severity])
        #expect(findings.map(\.message) == ["Programm von com.example.script \(statement)"])
    }

    /// Ein Skript ohne Apple-Anspruch bleibt **niedrig**, auch mit Plist im Benutzerverzeichnis.
    @Test func unsignedScriptWithoutAppleClaimStaysLow() {
        var script = TestData.disguisedAppleAgent
        script.label = "com.example.script"
        script.plistPath = "/Users/test/Library/LaunchAgents/com.example.script.plist"
        script.programScript = Self.appleShell
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [script]))
        #expect(findings.map(\.severity) == [.low])
        #expect(findings.map(\.message) == ["Programm von com.example.script ist ein Skript (ohne Signatur)"])
    }

    /// Ein Skript unter einem `com.apple.`-Label außerhalb der Apple-Pfade bleibt Tarnung: kein Apple-Bestandteil,
    /// der Befund bleibt bestehen und wiegt mindestens **mittel**, mit Hinweis auf die Tarnung.
    @Test func disguisedAppleScriptIsMedium() {
        var disguised = TestData.disguisedAppleAgent
        disguised.programScript = Self.appleShell
        var unknownInterpreter = disguised
        unknownInterpreter.label = "com.apple.other.agent"
        unknownInterpreter.programScript = Self.script("/Users/test/Library/.x/evil", signing: SigningInfo(kind: .unsigned))
        #expect(!AppleComponent.contains(disguised))
        #expect(!AppleComponent.hasAppleProgram(disguised))
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [disguised, unknownInterpreter]))
        #expect(findings.map(\.recordID) == [disguised.id, unknownInterpreter.id])
        #expect(findings.map(\.severity) == [.medium, .medium])
        #expect(findings.map(\.message) == [
            "Programm von com.apple.update.agent ist ein Skript (ohne Signatur) und gibt sich als Apple-Komponente aus",
            "Programm von com.apple.other.agent ist ein Skript mit unbekanntem Interpreter /Users/test/Library/.x/evil"
                + " und gibt sich als Apple-Komponente aus",
        ])
    }

    /// Ad hoc signierte oder signierte Skripte bewertet weiter die Signatur.
    @Test func scriptDoesNotOverrideAKnownSignature() {
        var adHoc = item("adhoc", signing: SigningInfo(kind: .adHoc))
        adHoc.programScript = Self.appleShell
        var signed = item("signed", signing: SigningInfo(kind: .developerID))
        signed.programScript = Self.script("/Users/x/evil", signing: SigningInfo(kind: .unsigned))
        let findings = UnsignedProgramRule().evaluate(TestData.snapshot(items: [adHoc, signed]))
        #expect(findings.map(\.message) == ["Programm von adhoc ist nur ad hoc signiert"])
    }

    @Test func standardEvaluatorIncludesTheRule() {
        let snapshot = TestData.snapshot(items: [item("x", signing: SigningInfo(kind: .unsigned))])
        #expect(RiskEvaluator.standard.evaluate(snapshot).map(\.rule) == [.unsignedProgram])
    }
}

@Suite struct InvalidSignatureRuleTests {
    let app = TestData.app("com.corsair.icue")
    var path: String { app.path! }
    let broken = DeepSignatureVerdict.invalid(status: -67023)

    @Test func flagsSensitiveGrantsAndAutostartOwnersWithInvalidSignature() {
        let snapshot = TestData.snapshot(
            grants: [TestData.grant("kTCCServiceListenEvent", client: app)],
            items: [TestData.item("com.corsair.agent", owner: app)]
        )
        let findings = InvalidSignatureRule().evaluate(snapshot, signatures: [path: broken])
        #expect(findings.map(\.recordID) == ["user|kTCCServiceListenEvent|com.corsair.icue", "launchAgent|user|com.corsair.agent"])
        #expect(findings.allSatisfy { $0.rule == .invalidSignature && $0.severity == .high })
        #expect(findings.map(\.message) == [
            "Signatur von com.corsair.icue ist ungültig oder verändert: Ressourcen des Bundles verändert (Fehler -67023)",
            "Signatur der zugehörigen App von com.corsair.agent ist ungültig oder verändert: Ressourcen des Bundles verändert (Fehler -67023)",
        ])
    }

    @Test(arguments: [DeepSignatureVerdict.valid, .unverifiable])
    func validOrUnverifiableSignaturesAreFine(verdict: DeepSignatureVerdict) {
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: app)])
        #expect(InvalidSignatureRule().evaluate(snapshot, signatures: [path: verdict]).isEmpty)
    }

    /// Sonderdateien im Bundle: Signatur nicht prüfbar, aber ein eigener Befund (mittel) – sonst ließe sich die
    /// Tiefenprüfung mit einer FIFO dauerhaft ausschalten (Review M1).
    @Test func specialFilesAreReportedAsMedium() {
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: app)])
        let findings = InvalidSignatureRule().evaluate(snapshot, signatures: [path: .containsSpecialFiles])
        #expect(findings.map(\.rule) == [.specialFiles])
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.map(\.message) == [
            "com.corsair.icue enthält Sonderdateien (FIFO, Socket oder Gerät) – Signatur nicht prüfbar",
        ])
    }

    @Test func withoutVerdictsThereAreNoFindings() {
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: app)])
        #expect(InvalidSignatureRule().evaluate(snapshot).isEmpty)
        #expect(InvalidSignatureRule().evaluate(snapshot, signatures: [:]).isEmpty)
    }

    @Test func targetsOnlyGrantedSensitiveClientsAndOwnersOnce() {
        let camera = TestData.app("com.camera.only")
        let denied = TestData.app("com.denied")
        let owner = TestData.app("com.owner")
        let snapshot = TestData.snapshot(
            grants: [
                TestData.grant("kTCCServiceAccessibility", client: app),
                TestData.grant("kTCCServiceScreenCapture", client: app),
                TestData.grant("kTCCServiceCamera", client: camera),
                TestData.grant("kTCCServiceAccessibility", client: denied, authValue: .denied),
            ],
            items: [TestData.item("a", owner: owner), TestData.item("b", owner: app), TestData.item("ownerless")]
        )
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot) == [path, "/Applications/com.owner.app"])
    }

    @Test func skipsAppleUnsignedAdHocAndAbsentApps() {
        let apps = [
            TestData.app("com.apple.x", signing: SigningInfo(kind: .apple)),
            TestData.app("com.unsigned", signing: SigningInfo(kind: .unsigned)),
            TestData.app("com.adhoc", signing: SigningInfo(kind: .adHoc)),
            TestData.app("com.gone", presence: .missing),
            TestData.app("com.maybe", presence: .unknown),
        ]
        let snapshot = TestData.snapshot(
            grants: apps.map { TestData.grant("kTCCServiceAccessibility", client: $0) },
            items: apps.map { TestData.item("item.\($0.bundleID!)", owner: $0) }
        )
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot).isEmpty)
        let verdicts = Dictionary(uniqueKeysWithValues: apps.map { ($0.path!, broken) })
        #expect(InvalidSignatureRule().evaluate(snapshot, signatures: verdicts).isEmpty)
    }

    /// Ein Developer-ID-Programm mit gefälschter Apple-Kennung (Berechtigung, Autostart-Eigentümer) wird geprüft.
    @Test func fakeAppleBundleIDIsVerified() {
        let fake = TestData.app("com.apple.update", signing: SigningInfo(kind: .developerID, teamID: "EVIL123456"))
        let snapshot = TestData.snapshot(
            grants: [TestData.grant("kTCCServiceAccessibility", client: fake)],
            items: [TestData.item("com.evil.agent", owner: fake)]
        )
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot) == [fake.path!])
        #expect(InvalidSignatureRule().evaluate(snapshot, signatures: [fake.path!: broken]).count == 2)
    }

    @Test func standardEvaluatorPassesVerdictsToTheRule() {
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: app)])
        #expect(RiskEvaluator.standard.evaluate(snapshot).isEmpty)
        #expect(RiskEvaluator.standard.evaluate(snapshot, signatures: [path: broken]).map(\.rule) == [.invalidSignature])
    }
}
