import Foundation

/// Warum Grantry eine Agenten-Konfiguration nicht ändert (Stufe 2). Texte nennen nie Inhalte der Datei.
public enum AgentConfigEditError: LocalizedError, Equatable, Sendable {
    /// Die Datei darf nicht geändert werden; Grund im Klartext („Der Pfad enthält einen symbolischen Link“).
    case notEditable(String)
    /// Die Datei fehlt.
    case missing
    /// Die Datei ist nicht lesbar oder kein gültiges JSON/TOML; Grund ohne Inhalt.
    case unreadable(String)
    /// Der Eintrag fehlt oder ist nicht mehr der angezeigte (anderer Befehl/andere URL).
    case entryChanged
    /// Die Datei hat sich zwischen Lesen und Schreiben geändert.
    case fileChanged
    /// Der Eintrag steht so in der Datei, dass er sich nicht gezielt ändern lässt (doppelt, in einer Inline-Tabelle …).
    case unsupportedLayout
    /// Das Ergebnis wäre mehr als die beabsichtigte Änderung – nichts geschrieben.
    case verificationFailed
    /// Der Schalter steht schon so.
    case alreadyInState
    /// Unter dem Namen des wiederherzustellenden Servers steht inzwischen ein anderer Server.
    case nameTaken
    /// Kein Beleg mit dieser Kennung.
    case changeNotFound
    /// Die Sicherung fehlt, ist nicht vertrauenswürdig oder passt nicht zu ihrer Prüfsumme.
    case backupUnusable(String)
    /// Sichern oder Schreiben gescheitert – die Datei ist unverändert.
    case writeFailed(String)
    /// Die neue Fassung steht in der Datei, obwohl die Nachprüfung nach dem Tausch scheiterte und der Rücktausch nicht
    /// gelang; Grund ohne Inhalt. Sicherung und Beleg bleiben erhalten.
    case replacedUnverified(String)

    /// `true`, wenn die Konfigurationsdatei nachweislich unverändert blieb – nur dann darf eine Sicherung verworfen
    /// werden. Allein `replacedUnverified` hat die Datei geändert.
    public var leavesFileUnchanged: Bool {
        if case .replacedUnverified = self { false } else { true }
    }

    public var errorDescription: String? {
        switch self {
        case .notEditable(let reason): "\(reason) – bitte im Editor ändern."
        case .missing: "Die Konfigurationsdatei gibt es nicht mehr."
        case .unreadable(let reason): "Die Konfigurationsdatei ist nicht lesbar (\(reason))."
        case .entryChanged: "Der Eintrag hat sich seit dem letzten Scan geändert oder fehlt – bitte erneut versuchen."
        case .fileChanged: "Die Datei hat sich geändert, bitte erneut versuchen."
        case .unsupportedLayout: "Der Eintrag steht so in der Datei, dass Grantry ihn nicht gezielt ändern kann – bitte im Editor ändern."
        case .verificationFailed: "Die Änderung hätte mehr als diesen Eintrag berührt und wurde nicht geschrieben – bitte im Editor ändern."
        case .alreadyInState: "Der Server hat diesen Zustand bereits."
        case .nameTaken: "Unter diesem Namen steht inzwischen ein anderer Server in der Datei – bitte im Editor prüfen."
        case .changeNotFound: "Der Wiederherstellungsbeleg wurde nicht gefunden."
        case .backupUnusable(let reason): "Die Sicherung ist nicht verwendbar: \(reason)."
        case .writeFailed(let reason): "Die Datei wurde nicht geändert: \(reason)."
        case .replacedUnverified(let reason):
            "Die Datei wurde trotz gescheiterter Nachprüfung geändert: \(reason). Die Sicherung bleibt im Verlauf erhalten."
        }
    }
}

extension AgentConfigEditError {
    /// Führt `parse` aus; ein Syntaxfehler wird zu `unreadable` (Zeile und Art, nie Inhalt).
    static func parsing<Value>(_ parse: () throws(ConfigParseError) -> Value) throws(AgentConfigEditError) -> Value {
        do {
            return try parse()
        } catch {
            throw .unreadable(error.description)
        }
    }
}
