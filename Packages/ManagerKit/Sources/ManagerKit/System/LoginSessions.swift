import Darwin
import Foundation
import Synchronization

/// Art einer Anmeldung (Spec 2026-11-06 §6, Stufe 4): am Bildschirm, in einem Terminal oder von einem anderen Rechner.
public enum LoginSessionKind: Hashable, Sendable, Comparable {
    case graphical, terminal, remote

    public var title: String {
        switch self {
        case .graphical: "Bildschirm"
        case .terminal: "Terminal"
        case .remote: "Fernanmeldung"
        }
    }

    public var systemImage: String {
        switch self {
        case .graphical: "display"
        case .terminal: "terminal"
        case .remote: "network"
        }
    }
}

/// Eine Anmeldung wie bei `who`: Benutzer, Anschluss und bei SSH die Gegenstelle.
public struct LoginSession: Hashable, Sendable, Identifiable {
    static let consoleLine = "console"
    private static let locale = Locale(identifier: "de_DE")

    public let user: String
    /// Anschluss, z. B. „console“ oder „ttys001“.
    public let line: String
    /// Gegenstelle einer Fernanmeldung (SSH); `nil` bei lokalen Sitzungen.
    public let host: String?
    public let loginDate: Date

    public init(user: String, line: String, host: String?, loginDate: Date) {
        self.user = user
        self.line = line
        self.host = host
        self.loginDate = loginDate
    }

    /// Je Anschluss gibt es höchstens eine aktive Anmeldung.
    public var id: String { line }

    public var kind: LoginSessionKind {
        if line == Self.consoleLine { return .graphical }
        return host == nil ? .terminal : .remote
    }

    /// „ttys004 von 10.0.0.7“ bzw. nur der Anschluss.
    public var detail: String {
        host.map { "\(line) von \($0)" } ?? line
    }

    /// „seit 26.10.2026, 08:33“.
    public func sinceText(timeZone: TimeZone = .current) -> String {
        "seit " + loginDate.formatted(Date.FormatStyle(locale: Self.locale, timeZone: timeZone)
            .day(.twoDigits).month(.twoDigits).year().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// Rohdaten eines Eintrags der utmpx-Datenbank.
struct UtmpxRecord: Hashable, Sendable {
    let type: Int32
    let user: String
    let line: String
    let host: String
    let loginSeconds: Int
}

/// Angemeldete Benutzer aus der utmpx-Datenbank (`/var/run/utmpx`), wie `who`. Nur lesend; die Datenbank ist eine
/// kleine lokale Datei, ein Aufruf dauert unter einer Millisekunde.
public enum LoginSessions {
    /// Aktuelle Anmeldungen, nach Benutzer, Art und Anschluss sortiert.
    public static func current() -> [LoginSession] {
        sessions(from: UtmpxDatabase.records())
    }

    /// Nur Einträge angemeldeter Benutzer (`USER_PROCESS`); eine leere Gegenstelle heißt lokal.
    static func sessions(from records: [UtmpxRecord]) -> [LoginSession] {
        records.filter { $0.type == USER_PROCESS && !$0.user.isEmpty && !$0.line.isEmpty }
            .map {
                LoginSession(user: $0.user, line: $0.line, host: $0.host.isEmpty ? nil : $0.host,
                             loginDate: Date(timeIntervalSince1970: TimeInterval($0.loginSeconds)))
            }
            .sorted { ($0.user, $0.kind, $0.line) < ($1.user, $1.kind, $1.line) }
    }
}

/// Zugriff auf die utmpx-Datenbank. `setutxent`/`getutxent` teilen sich einen Lesezeiger je Prozess; die Sperre
/// verhindert, dass zwei Aufrufer ihn gleichzeitig bewegen.
enum UtmpxDatabase {
    private static let lock = Mutex(())

    static func records() -> [UtmpxRecord] {
        lock.withLock { _ in
            setutxent()
            defer { endutxent() }
            var records: [UtmpxRecord] = []
            while let entry = getutxent()?.pointee {
                records.append(UtmpxRecord(type: Int32(entry.ut_type), user: text(entry.ut_user),
                                           line: text(entry.ut_line), host: text(entry.ut_host),
                                           loginSeconds: Int(entry.ut_tv.tv_sec)))
            }
            return records
        }
    }

    /// Text eines C-Felds fester Länge, das nicht nullterminiert sein muss.
    private static func text<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
