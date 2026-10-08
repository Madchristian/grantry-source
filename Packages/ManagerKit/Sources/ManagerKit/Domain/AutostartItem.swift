import Foundation

/// Art eines Autostart-Eintrags.
public enum AutostartKind: String, Hashable, Sendable, Codable, CaseIterable {
    case loginItem, launchAgent, launchDaemon, backgroundTask
}

/// `user`: im Benutzerkontext änderbar; `system`: Änderung braucht root (Helper).
public enum AutostartDomain: String, Hashable, Sendable, Codable {
    case user, system
}

/// Ein Eintrag, der beim Login oder im Hintergrund automatisch startet.
public struct AutostartItem: InventoryRecord, Codable {
    public var kind: AutostartKind
    public var domain: AutostartDomain
    public var label: String
    /// Bei Login-Items der Pfad des App-Bundles, bei launchd-Einträgen und Hintergrund-Diensten das ausgeführte
    /// Programm – bei launchd maskiert wie die Argumente (`MaskedCommand`, #137): Ohne `Program` ist es `argv[0]`, und das
    /// kann Zugangsdaten tragen (`https://user:pw@host/…`).
    public var program: String?
    /// Ob `program` auf der Platte vorhanden ist; `unknown`, wenn der Pfad fehlt, nicht absolut oder nicht prüfbar ist.
    public var programPresence: Presence
    public var isEnabled: Bool
    /// `nil`, wenn die Quelle den Ladezustand nicht kennt (z. B. BTM). Bei launchd bedeutet `false` „nicht in der
    /// abgefragten Domain geladen“: Agents, die per `LimitLoadToSessionType` auf andere Sessions als Aqua beschränkt
    /// sind (z. B. `Background`, `LoginWindow`), tauchen in der `gui`-Domain nie auf.
    public var isLoaded: Bool?
    public var plistPath: String?
    public var owner: AppIdentity?
    public var source: SourceID
    /// Signatur von `program`; `nil`, wenn die Quelle sie nicht prüft (Login-Items, BTM), das Programm nicht als
    /// absoluter, vorhandener Pfad vorliegt oder der Snapshot älter als dieses Feld ist. Reine Anzeige- und
    /// Risikoinformation: Sie zählt nicht zu `hasSignificantChanges` – ein Update, das nur die Signatur ändert, soll
    /// kein Änderungs-Event auslösen (der Programmpfad bleibt gleich).
    public var programSigning: SigningInfo?
    /// `LimitLoadToSessionType` eines launchd-Eintrags; `nil`, wenn nicht gesetzt oder nicht bekannt (andere Quellen,
    /// ältere Snapshots). Reine Zusatzinformation für die `ActionPolicy`, zählt nicht zu `hasSignificantChanges`.
    public var sessionTypes: [String]?
    /// Ob ein launchd-Eintrag einen Skript- oder Systeminterpreter mit Argumenten startet (`/bin/sh -c …`,
    /// `osascript`, `python3`, `curl` …, siehe `ScriptInterpreter`): `program` ist dann Apple-signiert, der
    /// ausgeführte Code aber nicht. `false` für andere Quellen und ältere Snapshots; zählt nicht zu
    /// `hasSignificantChanges` (ein Wechsel des Programms zählt ohnehin).
    public var launchesInterpreter: Bool
    /// Ist `program` ein Skript (beginnt mit `#!`), dessen Interpreter samt Signatur: Skripte tragen meist keine
    /// Code-Signatur, maßgeblich ist der Interpreter (`ProgramScript.interpreterOrigin`). Nur für absolute, vorhandene
    /// Programme von launchd-Einträgen ermittelt, sonst `nil` – auch für ältere Snapshots, die nur ein `programIsScript`
    /// ohne Interpreter kennen; zählt nicht zu `hasSignificantChanges` (ein Wechsel des Programms zählt ohnehin).
    public var programScript: ProgramScript?
    /// Fingerabdruck der Plist-Datei (`plistPath`) beim Scan; `nil` für andere Quellen und ältere Snapshots. Reine
    /// Identitätsinformation für das Aufräumen aus einer Beobachtung (`ObservationCleanupOffer`, #156): Eine seither
    /// umgeschriebene oder ausgetauschte Plist ist nicht mehr der beobachtete Eintrag. Zählt nicht zu
    /// `hasSignificantChanges` – ein bloßes Neuschreiben der Datei ist keine Änderung des Eintrags.
    public var plistFingerprint: FileFingerprint?
    /// `ProgramArguments` eines launchd-Eintrags (`argv` samt `argv[0]`), maskiert durch den `ArgumentRedactor` (#137);
    /// leer, wenn die Plist nur `Program` setzt. `nil` heißt „unbekannt“: andere Quellen und Snapshots von vor diesem
    /// Feld – ein Wechsel von `nil` zu einem Wert ist daher kein Änderungsereignis (`reportsChange(to:)`), wird aber
    /// gespeichert (`hasSignificantChanges`).
    public var programArguments: [String]?
    /// Fingerabdruck des unmaskierten Programms samt `ProgramArguments`, falls darin etwas maskiert wurde
    /// (`MaskedCommand`): Ändert sich nur ein maskiertes Geheimnis, bleiben `program` und die maskierten Argumente
    /// gleich, der Fingerabdruck nicht. `nil` ohne Maskierung, für andere Quellen und ältere Snapshots.
    public var programArgumentsFingerprint: SecretFingerprint?
    /// Ganz verborgenes Skript, beim Scan ermittelt (auch bei später fehlendem Interpreter).
    public var hasHiddenScript: Bool
    /// Gesetzt, wenn dieser Eintrag nur fortgeschrieben ist (#139): Seine Plist bzw. ihr Verzeichnis war beim Scan nicht
    /// auswertbar (`InventoryContribution.incompletePlistPaths`), gezeigt wird der Stand des Scans zu diesem Zeitpunkt –
    /// des letzten, der die Plist tatsächlich gelesen hat. `nil` für in diesem Scan gelesene Einträge, andere Quellen
    /// und ältere Snapshots. Zählt zu `hasSignificantChanges` (damit der Snapshot den Wechsel speichert), aber nicht zu
    /// `reportsChange(to:)`: Ein Lesefehler ist keine Änderung des Eintrags.
    public var lastVerifiedAt: Date?

    public init(
        kind: AutostartKind, domain: AutostartDomain, label: String, program: String?,
        programPresence: Presence, isEnabled: Bool, isLoaded: Bool?, plistPath: String?,
        owner: AppIdentity?, source: SourceID, programSigning: SigningInfo? = nil, sessionTypes: [String]? = nil,
        launchesInterpreter: Bool = false, programScript: ProgramScript? = nil, plistFingerprint: FileFingerprint? = nil,
        programArguments: [String]? = nil, programArgumentsFingerprint: SecretFingerprint? = nil, lastVerifiedAt: Date? = nil, hasHiddenScript: Bool = false
    ) {
        self.kind = kind
        self.domain = domain
        self.label = label
        self.program = program
        self.programPresence = programPresence
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
        self.plistPath = plistPath
        self.owner = owner
        self.source = source
        self.programSigning = programSigning
        self.sessionTypes = sessionTypes
        self.launchesInterpreter = launchesInterpreter
        self.programScript = programScript
        self.plistFingerprint = plistFingerprint
        self.programArguments = programArguments
        self.programArgumentsFingerprint = programArgumentsFingerprint
        self.lastVerifiedAt = lastVerifiedAt
        self.hasHiddenScript = hasHiddenScript
    }

    /// Identität des Eintrags – bei launchd die der **Plist**, nicht die des Dienstes (`launchdServiceID`, #138): Zwei
    /// Plists derselben Domain mit gleichem Label sind zwei Einträge in Listen, Auswahl, Findings und Verlauf.
    ///
    /// Heißt die Plist wie ihr Label (`<label>.plist`, der Normalfall) oder fehlt sie (andere Quellen), bleibt die ID die
    /// bisherige `art|domäne|label` – gespeicherte Snapshots, Verlaufseinträge und Findings behalten ihre IDs, ohne
    /// Schein-Ereignisse. Sonst kommt der Dateiname dazu: `art|domäne|label/datei.plist`. Das ist eindeutig, weil ein
    /// Dateiname kein `/` enthält: Ein Label ohne angehängten Namen stammt aus `<label>.plist` und enthält daher selbst
    /// keines, und hinter dem letzten `/` steht immer der vollständige Dateiname. Den Ordner bestimmen Art und Domäne
    /// (`LaunchdDirectory.standard`); da die ID aus gespeicherten Feldern berechnet wird, gilt sie auch für alte Snapshots.
    public var id: String {
        let base = "\(kind.rawValue)|\(domain.rawValue)|\(label)"
        return distinctPlistName.map { base + "/" + $0 } ?? base
    }

    /// Dateiname der Plist, wenn er nicht `<label>.plist` lautet – dann unterscheidet er den Eintrag von anderen Plists
    /// mit demselben Label (`id`) und wird in Liste und Verlauf genannt; sonst `nil`.
    public var distinctPlistName: String? {
        guard let plistPath else { return nil }
        let name = plistPath.lastIndex(of: "/").map { String(plistPath[plistPath.index(after: $0)...]) } ?? plistPath
        return name == label + ".plist" ? nil : name
    }

    /// Identität des launchd-**Dienstes** (#138): launchd führt Dienste je Domain nach Label – LaunchDaemons in
    /// `system`, LaunchAgents (aus `~/Library` wie aus `/Library`) in `gui/<uid>`. Plists mit derselben Dienst-ID
    /// konkurrieren um einen Dienst; labelgebundene launchctl-Befehle (Override) träfen alle. `nil` für andere Arten.
    public var launchdServiceID: String? { Self.launchdServiceID(kind: kind, label: label) }

    /// `launchdServiceID` für einen Eintrag der Art `kind` mit `label`.
    public static func launchdServiceID(kind: AutostartKind, label: String) -> String? {
        switch kind {
        case .launchDaemon: "system/" + label
        case .launchAgent: "gui/" + label
        case .loginItem, .backgroundTask: nil
        }
    }

    /// Der Ladezustand zählt nur, wenn beide Seiten ihn kennen – ein Wechsel von/zu `nil` ist keine Änderung.
    /// `programSigning`, `sessionTypes`, `launchesInterpreter`, `programScript` und `plistFingerprint` zählen bewusst
    /// nicht (siehe dort). Argumente und ihr Fingerabdruck zählen auch beim Wechsel von „unbekannt“ (`nil`) oder zu
    /// einem anderen Schlüssel – damit der Snapshot gespeichert wird; gemeldet wird das nicht (`reportsChange(to:)`).
    /// Ebenso ein Wechsel von `lastVerifiedAt` (fortgeschrieben bzw. wieder gelesen, #139).
    public func hasSignificantChanges(comparedTo other: AutostartItem) -> Bool {
        hasReportableChanges(comparedTo: other) || program != other.program || programArguments != other.programArguments
            || programArgumentsFingerprint != other.programArgumentsFingerprint || hasHiddenScript != other.hasHiddenScript || lastVerifiedAt != other.lastVerifiedAt
    }

    /// `true`, wenn der Eintrag aus dem Scan stammt, der ihn geliefert hat – nicht nur fortgeschrieben (`lastVerifiedAt`).
    public var isCurrent: Bool { lastVerifiedAt == nil }

    /// Dieser Eintrag als Fortschreibung aus dem Scan von `date` (#139): `lastVerifiedAt` bleibt beim ersten
    /// Fortschreiben `date`, danach unverändert – maßgeblich ist der letzte Scan, der die Plist gelesen hat.
    func carriedForward(scannedAt date: Date) -> AutostartItem {
        var result = self
        result.lastVerifiedAt = lastVerifiedAt ?? date
        return result
    }

    /// Wie `hasSignificantChanges`, Argumente zählen aber nur, wenn beide Seiten sie kennen
    /// (`argumentsDiffer(from:)`): Der erste Scan nach dem Update auf einen Snapshot ohne Argumente meldet keine
    /// Änderungsflut (#137).
    public func reportsChange(to other: AutostartItem) -> Bool {
        hasReportableChanges(comparedTo: other)
    }

    /// Ob sich der ausgeführte Befehl nachweislich geändert hat: Die maskierten Argumente unterscheiden sich, oder sie
    /// sind gleich und der Fingerabdruck der maskierten Teile weicht ab (`secretArgumentsDiffer(from:)`). `false`,
    /// wenn eine Seite die Argumente nicht kennt.
    public func argumentsDiffer(from other: AutostartItem) -> Bool {
        guard let programArguments, let otherArguments = other.programArguments else { return false }
        return programArguments != otherArguments || secretArgumentsDiffer(from: other)
    }

    /// Gleiche maskierte Argumente, aber ein anderes maskiertes Geheimnis – nur bei vergleichbaren Fingerabdrücken.
    public func secretArgumentsDiffer(from other: AutostartItem) -> Bool {
        programArguments == other.programArguments
            && SecretFingerprint.reportablyDiffers(programArgumentsFingerprint, other.programArgumentsFingerprint)
    }

    /// Ausgeführter Befehl in einer Zeile mit Shell-Quoting (`ShellQuoting`), Geheimnisse maskiert: das Programm,
    /// dahinter die Argumente ab `argv[1]` (`argv[0]` ist neben `Program` nur der Prozessname). `nil`, wenn Programm
    /// oder Argumente unbekannt sind.
    public var commandLine: String? {
        guard let programArguments, let executable = program ?? programArguments.first else { return nil }
        return ShellQuoting.commandLine([executable] + programArguments.dropFirst())
    }

    /// Ob sich das Programm geändert hat. Kennt eine Seite die Argumente nicht (Snapshot von vor #137, dort stand das
    /// Programm noch unmaskiert), wird ihr Programm mit der heutigen Maskierung verglichen – ein früher rohes
    /// `https://user:pw@host/…` ist dasselbe wie das heute maskierte.
    public func programDiffers(from other: AutostartItem) -> Bool {
        guard program != other.program else { return false }
        guard programArguments == nil || other.programArguments == nil else { return true }
        return Self.remasked(program) != Self.remasked(other.program)
    }

    /// `program` wie `MaskedCommand` es heute maskiert.
    private static func remasked(_ program: String?) -> String? {
        program.map { ArgumentRedactor.redact(arguments: [$0], resolvingPath: { _ in nil }).values.first ?? ArgumentRedactor.mask }
    }

    private func hasReportableChanges(comparedTo other: AutostartItem) -> Bool {
        isEnabled != other.isEnabled || programDiffers(from: other) || loadStateDiffers(from: other)
            || argumentsDiffer(from: other)
    }

    private func loadStateDiffers(from other: AutostartItem) -> Bool {
        guard let isLoaded, let otherIsLoaded = other.isLoaded else { return false }
        return isLoaded != otherIsLoaded
    }
}

extension AutostartItem {
    private enum CodingKeys: String, CodingKey {
        case kind, domain, label, program, programPresence, isEnabled, isLoaded, plistPath, owner, source, programSigning, sessionTypes
        case launchesInterpreter, programScript, plistFingerprint, programArguments, programArgumentsFingerprint
        case lastVerifiedAt, hasHiddenScript
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case programExists
    }

    /// Liest auch Snapshots von vor der Einführung von `programPresence`, die nur `programExists` speichern. Ohne
    /// Programmpfad bedeutete `false` dort schon „unbekannt“, nicht „fehlt“. Fehlen `programSigning` oder
    /// `sessionTypes` (ältere Snapshots), sind sie `nil`; fehlt `launchesInterpreter`, ist es `false`; fehlt
    /// `programScript`, `plistFingerprint`, `programArguments`, `programArgumentsFingerprint` oder `lastVerifiedAt`,
    /// sind sie `nil` (ein altes `programIsScript` ohne Interpreter wird nicht übernommen).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AutostartKind.self, forKey: .kind)
        domain = try container.decode(AutostartDomain.self, forKey: .domain)
        label = try container.decode(String.self, forKey: .label)
        program = try container.decodeIfPresent(String.self, forKey: .program)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isLoaded = try container.decodeIfPresent(Bool.self, forKey: .isLoaded)
        plistPath = try container.decodeIfPresent(String.self, forKey: .plistPath)
        owner = try container.decodeIfPresent(AppIdentity.self, forKey: .owner)
        source = try container.decode(SourceID.self, forKey: .source)
        programSigning = try container.decodeIfPresent(SigningInfo.self, forKey: .programSigning)
        sessionTypes = try container.decodeIfPresent([String].self, forKey: .sessionTypes)
        launchesInterpreter = try container.decodeIfPresent(Bool.self, forKey: .launchesInterpreter) ?? false
        programScript = try container.decodeIfPresent(ProgramScript.self, forKey: .programScript)
        plistFingerprint = try container.decodeIfPresent(FileFingerprint.self, forKey: .plistFingerprint)
        programArguments = try container.decodeIfPresent([String].self, forKey: .programArguments)
        programArgumentsFingerprint = try container.decodeIfPresent(SecretFingerprint.self, forKey: .programArgumentsFingerprint)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        hasHiddenScript = try container.decodeIfPresent(Bool.self, forKey: .hasHiddenScript) ?? false
        // Auch #137-Daten mit Fingerabdruck können die in #173 geschlossenen Lücken enthalten.
        if let arguments = programArguments {
            let redacted = ArgumentRedactor.redactStored(arguments: arguments, program: program,
                                                        hasScriptClassification: container.contains(.hasHiddenScript))
            programArguments = redacted.values
            hasHiddenScript = hasHiddenScript || redacted.hasHiddenScript
        }
        // launchd-Einträge von vor #137 (ohne Argumente) trugen `program` roh – es kann `argv[0]` mit Zugangsdaten sein.
        // Beim Lesen mit der heutigen Maskierung normalisieren, damit es nirgends angezeigt oder kopiert wird.
        if source == .launchd, programArguments == nil { program = Self.remasked(program) }
        if let presence = try container.decodeIfPresent(Presence.self, forKey: .programPresence) {
            programPresence = presence
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let exists = try legacy.decode(Bool.self, forKey: .programExists)
            programPresence = program == nil ? .unknown : Presence(legacyExists: exists)
        }
    }
}
