/// Autostart-Programm ohne zugehörige App ist unsigniert (**mittel**), ein Skript ohne Signatur (Skripte mit `#!` tragen
/// meist keine Signatur, siehe `AutostartItem.programScript`), nur ad hoc signiert (**niedrig**, typisch für Homebrew &
/// Co.: Linker und `brew` signieren ad hoc) oder ein Interpreter, der ein Skript ausführt (**niedrig**, etwa
/// `/bin/sh -c …` oder `osascript`: Die Signatur des Interpreters belegt nichts über das Skript – wie bei ad hoc
/// signierten Programmen fehlt ein Herkunftsnachweis, der Aufbau ist aber auch bei harmlosen Agents üblich).
///
/// Ein unsigniertes Skript wiegt wie sein Interpreter (`ProgramScript.interpreterOrigin`): mit nachgewiesener Herkunft
/// (geprüfte Apple- oder Zertifikatssignatur; bei genau `/usr/bin/env <name>` ohne eigenen `PATH` das über launchds
/// Standard-PATH gefundene Programm) **niedrig**, mit ad hoc signiertem Interpreter ebenfalls **niedrig** (wie ein ad
/// hoc signiertes Programm), sonst – auch im Zweifel – **mittel** wie ein unsigniertes Programm: Ein beliebiges
/// Programm als Interpreter (`#!/Users/x/Library/.x/evil`) führt fremden Code genauso aus.
///
/// Bewertet wird `AutostartItem.programSigning`, das nur launchd-Einträge mit absolutem, vorhandenem Programmpfad
/// tragen, sowie `AutostartItem.launchesInterpreter`. Einträge mit Eigentümer-App sind ausgenommen – deren Signatur
/// bewertet `UnsignedClientRule` an der App –, ebenso Programme echter Apple-Herkunft
/// (`AppleComponent.hasAppleProgram(_:)`: bei bekannter Signatur Apple-signiert, sonst unter einem Apple-Pfad; nie ein
/// Interpreter mit Argumenten). Ein `com.apple.`-Label allein nimmt nichts aus – es ist die übliche Tarnung von Adware,
/// auch bei Skripten. Erkennt `AppleComponent.isDisguised(_:)` eine solche Tarnung, wiegen Skript- und Interpreter-
/// Befunde mindestens **mittel** („gibt sich als Apple-Komponente aus“): Wer sich als Apple ausgibt, hat etwas zu
/// verbergen. Skripte und Interpreter-Starts ohne Tarnung bleiben niedrig.
///
/// Programme mit `SigningInfo.unknown` (Signatur nicht lesbar, z. B. fehlende Leserechte) erzeugen bewusst keinen
/// Befund: Ein Befund braucht einen Beleg, und „nicht prüfbar“ ist keiner.
public struct UnsignedProgramRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.autostartItems
            .filter { $0.owner == nil && !AppleComponent.hasAppleProgram($0) }
            .compactMap { item in
                Self.assessment(of: item).map { severity, statement in
                    RiskFinding(
                        rule: .unsignedProgram, severity: severity, recordID: item.id,
                        message: "Programm von \(item.label) \(statement)"
                    )
                }
            }
    }

    /// Schweregrad und Aussage der Meldung, `nil` ohne Befund. Eine fehlende Signatur wiegt schwerer als der
    /// Interpreter-Start; getarnte Skripte und Interpreter-Starts heben `disguised(_:)` auf mittel an.
    private static func assessment(of item: AutostartItem) -> (RiskFinding.Severity, String)? {
        switch item.programSigning?.kind {
        case .unsigned: item.programScript.map { disguised(item, scriptAssessment(of: $0)) } ?? (.medium, "ist nicht signiert")
        case .adHoc: (.low, "ist nur ad hoc signiert")
        default: item.launchesInterpreter ? disguised(item, (.low, "startet ein Skript über einen Systeminterpreter")) : nil
        }
    }

    /// Schweregrad und Aussage für ein unsigniertes Skript, nach der Herkunft seines Interpreters.
    private static func scriptAssessment(of script: ProgramScript) -> (RiskFinding.Severity, String) {
        guard !script.interpreter.isEmpty else { return (.medium, "ist ein Skript ohne Angabe des Interpreters") }
        return switch script.interpreterOrigin {
        case .verified: (.low, "ist ein Skript (ohne Signatur)")
        case .adHoc: (.low, "ist ein Skript mit nur ad hoc signiertem Interpreter \(script.interpreterDescription)")
        case .unknown: (.medium, "ist ein Skript mit unbekanntem Interpreter \(script.interpreterDescription)")
        }
    }

    /// `assessment`, bei einer Apple-Tarnung (`AppleComponent.isDisguised(_:)`) mindestens mittel und mit Hinweis.
    private static func disguised(
        _ item: AutostartItem, _ assessment: (severity: RiskFinding.Severity, statement: String)
    ) -> (RiskFinding.Severity, String) {
        guard AppleComponent.isDisguised(item) else { return assessment }
        return (max(assessment.severity, .medium), assessment.statement + " und gibt sich als Apple-Komponente aus")
    }
}

/// Die vollständige Signaturprüfung (`DeepSignatureVerifier`) hat eine ungültige oder veränderte Signatur ergeben
/// (**hoch**), wie sie auch Gatekeeper (`spctl`) meldet: Die App wurde nach dem Signieren verändert – beschädigt,
/// durch sich selbst überschrieben oder manipuliert. Die Meldung nennt den Grund im Klartext samt Fehlercode
/// (`DeepSignatureVerdict.failureReason`).
///
/// Geprüft werden Apps, bei denen die Prüfung etwas aussagt: Clients mit erteilter sensibler Berechtigung,
/// Eigentümer-Apps von Autostart-Einträgen und installierte Apps (Spec v3 §2; `verificationTargets(in:)`), jeweils
/// nachweislich vorhanden, keine echten Apple-Apps (`AppleComponent.isGenuineApple`) und nicht unsigniert bzw. ad hoc
/// signiert (das melden
/// `UnsignedClientRule` und `UnsignedAppRule`). Ohne Prüfergebnisse (`evaluate(_:)`) gibt es keinen Befund.
///
/// Enthält ein Bundle Sonderdateien (`DeepSignatureVerdict.containsSpecialFiles`), ist die Signatur nicht prüfbar – das
/// ist ein eigener Befund (`specialFiles`, **mittel**): Echte Apps enthalten keine, und eine FIFO im Bundle schaltete
/// die Tiefenprüfung sonst unbemerkt ab (Review M1).
public struct InvalidSignatureRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] { [] }

    public func evaluate(_ snapshot: Snapshot, signatures: [String: DeepSignatureVerdict]) -> [RiskFinding] {
        Self.subjects(in: snapshot).compactMap { subject in
            let verdict = signatures[subject.path]
            if let reason = verdict?.failureReason {
                return RiskFinding(rule: .invalidSignature, severity: .high, recordID: subject.recordID,
                                   message: "\(subject.signatureName) ist ungültig oder verändert: \(reason)")
            }
            guard verdict == .containsSpecialFiles else { return nil }
            return RiskFinding(rule: .specialFiles, severity: .medium, recordID: subject.recordID,
                               message: "\(subject.subjectName) enthält Sonderdateien (FIFO, Socket oder Gerät) – Signatur nicht prüfbar")
        }
    }


    /// Pfade, die der `DeepSignatureVerifier` für `snapshot` prüfen soll: eindeutig, in Snapshot-Reihenfolge
    /// (Berechtigungen, Autostart-Einträge, Apps).
    public static func verificationTargets(in snapshot: Snapshot) -> [String] {
        var seen = Set<String>()
        return subjects(in: snapshot).map(\.path).filter { seen.insert($0).inserted }
    }

    private struct Subject {
        let recordID: String
        let path: String
        /// Anfang der Meldung („Signatur von …“).
        let signatureName: String
        /// Name der geprüften App („iCUE“, „zugehörige App von …“).
        let subjectName: String
    }

    private static func subjects(in snapshot: Snapshot) -> [Subject] {
        let grants = snapshot.grants
            .filter { $0.authValue.isGranted && PermissionCatalog.service(for: $0.service).isSensitive }
            .compactMap { grant in
                verifiablePath(of: grant.client).map {
                    Subject(recordID: grant.id, path: $0,
                            signatureName: "Signatur von \(grant.client.displayName)",
                            subjectName: grant.client.displayName)
                }
            }
        let items = snapshot.autostartItems
            .compactMap { item in
                item.owner.flatMap(verifiablePath).map {
                    Subject(recordID: item.id, path: $0,
                            signatureName: "Signatur der zugehörigen App von \(item.label)",
                            subjectName: "Zugehörige App von \(item.label)")
                }
            }
        // Symlink-Bundles werden nie geprüft – die Tiefenprüfung folgte sonst dem Link (Review M3).
        let apps = snapshot.installedApps.filter { $0.symlinkTarget == nil }.compactMap { app in
            verifiablePath(of: app.identity).map {
                Subject(recordID: app.id, path: $0, signatureName: "Signatur von \(app.name)", subjectName: app.name)
            }
        }
        return grants + items + apps
    }

    /// Pfad einer vorhandenen, signierten App, die nicht nachweislich von Apple ist (`AppleComponent.isGenuineApple`);
    /// `nil`, wenn die Tiefenprüfung nichts beitrüge. Eine `com.apple.`-Kennung allein nimmt nicht aus – sie lässt sich
    /// in jedem Info.plist setzen (Review Task 4).
    private static func verifiablePath(of app: AppIdentity) -> String? {
        guard app.presence == .present, !AppleComponent.isGenuineApple(app),
              app.signing.kind != .unsigned, app.signing.kind != .adHoc else { return nil }
        return app.path
    }
}
