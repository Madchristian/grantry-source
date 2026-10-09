import AppKit
import CoreServices
import Synchronization

/// Papierkorb über den Finder (Spec v3 §4): ein Apple Event `core/delo` mit allen Dateien. So legt der Finder sie wie
/// beim Bewegen in den Papierkorb ab („Zurücklegen“ funktioniert) und fragt bei geschützten Dateien selbst nach dem
/// Passwort.
///
/// Review N2: Unmittelbar vor dem Senden – im selben Block auf der Queue des Senders – prüft `verify` jeden Kandidaten
/// erneut (`RemovalGuard`: dasselbe Objekt, erlaubter Ort), und Ziele auf Volumes ohne Papierkorb (Netzlaufwerk,
/// schreibgeschützt; `TrashVolumeChecking`) gehen nicht mit – der Finder löscht dort sofort endgültig. Das Ergebnis je
/// Datei prüft danach `lstat`: fehlt der Pfad, liegt das Original im Papierkorb – sofern der Nachweis unten nicht
/// widerspricht; liegt dort ein anderes Objekt, wurde er inzwischen neu angelegt (`.recreated`); sonst ist er noch
/// vorhanden – der Finder meldet bei einem Teilabbruch nur einen Fehler.
///
/// Verbleibende Grenze (#104): Das Apple Event trägt nur Pfade (`typeFileURL`), keine Inode – der Finder löst sie
/// selbst auf. Ersetzt ein Prozess den Eintrag zwischen `verify` und dieser Auflösung, legt der Finder das Ersatzobjekt
/// in den Papierkorb. Dieses Fenster ist nicht klein: Für Reste unter `/Library` liegt darin die Passwortabfrage des
/// Finders (Sekunden bis Minuten, `eventTimeout`). Verhindern lässt sich das mit dem Finder nicht. Am echten Finder
/// (macOS 27, 2026-10-04) geprüft: `/.vol/<Gerät>/<Inode>` und `file:///.file/id=<Gerät>.<Inode>` lehnt er mit -10010 ab;
/// Bookmark-Daten (`typeBookmarkData`) löst er wie Pfade zuerst über den Pfad auf und entsorgte nach einem Tausch den
/// Ersatz. Ohne Finder (eigenes `rename` in eine Zwischenablage) gingen „Zurücklegen“ und die
/// Passwortabfrage verloren. Nachgewiesen wird deshalb das Ergebnis: Fehlt das geprüfte Original am Pfad, zeigt
/// `FileLocating` (`fsgetpath`, Gerät/Inode aus `LeftoverCandidate.identity`), wo es jetzt liegt. Nur ein Pfad in einem
/// Papierkorb-Ordner (`.Trash`, `.Trashes`) ohne weitere harte Verknüpfungen zählt als „im Papierkorb“; liegt das
/// Original anderswo, nirgends mehr oder hat es weitere Namen, meldet der Bericht das als `.remaining` mit Grund
/// (`movedAwayPrefix`, `vanishedReason`, `hardLinkedReason`) statt als Erfolg. Ohne Nachweis (Identität unbekannt,
/// Pfad nicht aufbaubar) gilt wie bisher der Pfad.
///
/// Der Nachweis ist nachträglich und selbst ein Rennen: Er erkennt Zufall und unkooperative Nebenläufigkeit (Update,
/// Sync, Aufräumskript), nicht einen Angreifer mit den Rechten des Nutzers, der das Original kurz in einen
/// Papierkorb-Ordner legt und nach dem Bericht zurückholt – wer das kann, braucht Grantry nicht. Fehlalarme: Bestätigt
/// der Nutzer den Finder-Dialog „sofort löschen“ (lokales Volume ohne anlegbaren Papierkorb), meldet der Bericht
/// `vanishedReason`. Am echten Finder geprüft: Er verschiebt per Umbenennen auf demselben Volume (Inode bleibt) nach
/// `~/.Trash`. Ungeprüft ist das nur für root-eigene Einträge nach der Passwortabfrage; `/Library`, `/Applications` und
/// `~` liegen auf demselben APFS-Volume (Firmlinks). Kopierte er dort, erschiene ein korrekt entsorgter Eintrag als
/// `vanishedReason`.
///
/// Ein Tausch braucht nicht zwingend Schreibrecht auf den direkten Elternordner: Schon ein beschreibbarer
/// Großelternordner reicht, um den Elternordner durch einen Symlink zu ersetzen und die spätere Finder-Auflösung
/// umzulenken. Deshalb prüft `RemovalGuard` vor der Freigabe die ganze Kette vom erlaubten Wurzelort bis zum
/// Elternordner auf Eigentümer, Modusbits und ACLs (#203). Root und der ausführende Benutzer sind vertrauenswürdig;
/// root-eigene Ordner dürfen für `admin`/`wheel` schreibbar sein (etwa `/Applications`), andere Gruppenschreibrechte,
/// Other-Write und fremde ACL-Änderungsrechte sperren den Vorgang. Die verbleibende Grenze betrifft damit weiterhin
/// Prozesse innerhalb dieser Vertrauensgrenze; der nachträgliche Identitätsnachweis bleibt notwendig.
public struct FinderTrash: TrashPerforming {
    public static let finderBundleID = "com.apple.finder"
    /// Frist für das Apple Event; der Finder wartet ggf. auf die Passworteingabe.
    public static let eventTimeout: TimeInterval = 600
    /// Das Original wurde nach der letzten Prüfung verschoben (Pfad folgt) – an seiner Stelle ging ggf. ein anderes
    /// Objekt in den Papierkorb (#104).
    static let movedAwayPrefix = "Original liegt nicht im Papierkorb, sondern unter "
    static let movedAwaySuffix = " – an seiner Stelle wurde evtl. ein anderes Objekt in den Papierkorb gelegt"
    /// Das Original existiert nirgends mehr, auch nicht im Papierkorb (#104).
    static let vanishedReason = "Original ist weg, liegt aber nicht im Papierkorb (evtl. sofort gelöscht)"
    /// Das Original liegt im Papierkorb, hat aber weitere harte Verknüpfungen – sein Inhalt bleibt unter anderen Namen
    /// erhalten (#104).
    static let hardLinkedReason = "Original liegt im Papierkorb, hat aber weitere harte Verknüpfungen – Inhalt bleibt erhalten"

    private let sender: any FinderEventSending
    private let volumes: any TrashVolumeChecking
    private let locator: any FileLocating

    public init() {
        self.init(sender: AppleEventFinderSender())
    }

    /// Weist Originale über die offen gehaltenen Deskriptoren von `locator` nach (#143).
    public init(tracking locator: TrackedFileLocator) {
        self.init(sender: AppleEventFinderSender(), locator: locator)
    }

    public func track(_ candidates: [LeftoverCandidate]) {
        (locator as? TrackedFileLocator)?.track(candidates)
    }

    init(
        sender: any FinderEventSending, volumes: any TrashVolumeChecking = LocalVolumeTrashCheck(),
        locator: any FileLocating = FSGetPathLocator()
    ) {
        self.sender = sender
        self.volumes = volumes
        self.locator = locator
    }

    public func requestPermission() async -> TrashPermission {
        let status = await sender.permissionStatus()
        switch Int(status) {
        case Int(noErr): return .granted
        case ErrorCode.notPermitted: return .denied
        case ErrorCode.processNotFound: return .unavailable(Self.message(for: ErrorCode.processNotFound))
        default: return .unavailable("Automation-Freigabe für den Finder nicht prüfbar (Fehler \(status)).")
        }
    }

    public func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        let unique = Self.uniqueByPath(candidates)
        guard !unique.isEmpty else { return TrashReport(outcomes: [:], failure: nil) }
        let refused = Refusals()
        let volumes = volumes
        let code = await sender.delete(timeout: Self.eventTimeout) {
            unique.compactMap { candidate -> URL? in
                let reason: String? = switch verify(candidate) {
                case .blocked(let reason): reason
                case .allowed: volumes.refusalReason(forPath: candidate.path)
                }
                if let reason {
                    refused.add(reason, for: candidate.path)
                    return nil
                }
                return URL(fileURLWithPath: candidate.path)
            }
        }
        let failure = code.map(Self.message(for:))
        let blocked = refused.all
        let outcomes = unique.map { candidate -> (String, TrashItemOutcome) in
            if let reason = blocked[candidate.path] { return (candidate.path, .blocked(reason)) }
            return (candidate.path, outcome(of: candidate, failure: failure))
        }
        return TrashReport(outcomes: Dictionary(outcomes) { first, _ in first }, failure: failure)
    }

    /// Zustand nach dem Event: fehlt der Pfad → im Papierkorb; anderes Objekt → neu angelegt; sonst noch vorhanden.
    /// Beides nur, wenn das Original nachweislich (oder nicht widerlegbar) im Papierkorb liegt (`provenInTrash`).
    private func outcome(of candidate: LeftoverCandidate, failure: String?) -> TrashItemOutcome {
        guard let now = FileIdentity.of(candidate.path) else { return provenInTrash(candidate, otherwise: .trashed) }
        if let original = candidate.identity, !now.isSameObject(as: original) { return provenInTrash(candidate, otherwise: .recreated) }
        return .remaining(failure ?? "Noch vorhanden")
    }

    /// `outcome`, wenn das Original des Kandidaten in einem Papierkorb-Ordner liegt oder sein Ort nicht ermittelbar
    /// ist; sonst `.remaining` mit dem Befund – anderswo (verschoben), nirgends (gelöscht) oder mit weiteren harten
    /// Verknüpfungen (#104). Letztere zählen auch im Papierkorb nicht als entsorgt: Eine harte Verknüpfung auf einen
    /// Rest ist anomal, und `fsgetpath` nennt nur einen seiner Namen.
    private func provenInTrash(_ candidate: LeftoverCandidate, otherwise outcome: TrashItemOutcome) -> TrashItemOutcome {
        guard let original = candidate.identity else { return outcome }
        switch locator.locate(original) {
        case .unknown: return outcome
        case .gone: return .remaining(Self.vanishedReason)
        case .found(let path, _) where !Self.isInTrashFolder(path): return .remaining(Self.movedAwayReason(path))
        case .found(_, hasOtherNames: true): return .remaining(Self.hardLinkedReason)
        case .found: return outcome
        }
    }

    /// Nur mit Nachweis: Das Original liegt in einem Papierkorb-Ordner ohne weitere Namen (`FileLocating`); fehlt die
    /// Identität oder ist der Ort nicht ermittelbar, bleibt der Eintrag offen.
    public func settledOutcome(of candidate: LeftoverCandidate) -> TrashItemOutcome? {
        guard let original = candidate.identity, case .found(let path, hasOtherNames: false) = locator.locate(original),
              Self.isInTrashFolder(path) else { return nil }
        guard let now = FileIdentity.of(candidate.path) else { return .trashed }
        return now.isSameObject(as: original) ? nil : .recreated
    }

    static func movedAwayReason(_ path: String) -> String {
        movedAwayPrefix + "„\(PathDisplay.abbreviatingHome(path))“" + movedAwaySuffix
    }

    /// Papierkorb-Ordner des Finders: `~/.Trash`, `/Volumes/…/.Trashes/<uid>` (und `/.Trashes/<uid>`).
    static func isInTrashFolder(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Bei der letzten Prüfung abgelehnte Pfade samt Grund (geschrieben auf der Queue des Senders).
    private final class Refusals: Sendable {
        private let reasons = Mutex<[String: String]>([:])
        func add(_ reason: String, for path: String) { reasons.withLock { $0[path] = reason } }
        var all: [String: String] { reasons.withLock { $0 } }
    }

    private static func uniqueByPath(_ candidates: [LeftoverCandidate]) -> [LeftoverCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    /// Fehlercodes der Apple Events. `MacErrors.h` (mit `userCanceledErr`, `procNotFound`, `errAETimeout`) liegt im
    /// SDK 27 nicht mehr bei; die Werte sind die dokumentierten.
    enum ErrorCode {
        static let userCanceled = -128
        static let processNotFound = -600
        static let timeout = -1712
        static let notPermitted = Int(errAEEventNotPermitted)  // -1743, AppleEvents.h
    }

    /// Deutscher Text zu einem Fehlercode des Apple Events. Nach einer Zeitüberschreitung arbeitet der Finder ggf. noch
    /// (Review N3) – das Ergebnis je Datei kann sich danach noch ändern.
    static func message(for code: Int) -> String {
        switch code {
        case ErrorCode.userCanceled: "Abgebrochen (z. B. Passwortabfrage)"
        case ErrorCode.timeout: "Finder antwortet nicht – Löschen läuft evtl. weiter"
        case ErrorCode.notPermitted: "Keine Automation-Freigabe für den Finder"
        case ErrorCode.processNotFound: "Der Finder läuft nicht."
        default: "Finder-Fehler \(code)"
        }
    }
}

/// Ob ein Ziel auf einem Volume mit Papierkorb liegt. Auf Netzlaufwerken (z. B. Netz-Home) und schreibgeschützten
/// Volumes legt der Finder nichts in den Papierkorb, sondern löscht sofort bzw. scheitert.
protocol TrashVolumeChecking: Sendable {
    /// `nil`, wenn das Volume von `path` einen Papierkorb hat; sonst der Grund der Ablehnung.
    func refusalReason(forPath path: String) -> String?
}

/// Lokales, beschreibbares Volume laut `statfs` (`MNT_LOCAL`, nicht `MNT_RDONLY`); nicht prüfbar zählt als abgelehnt.
struct LocalVolumeTrashCheck: TrashVolumeChecking {
    static let networkReason = "Liegt auf einem Volume ohne Papierkorb (z. B. Netzlaufwerk)"
    static let readOnlyReason = "Liegt auf einem schreibgeschützten Volume"
    static let uncheckedReason = "Volume nicht prüfbar"

    func refusalReason(forPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return Self.uncheckedReason }
        return Self.refusalReason(flags: info.f_flags)
    }

    static func refusalReason(flags: UInt32) -> String? {
        if flags & UInt32(MNT_LOCAL) == 0 { return networkReason }
        if flags & UInt32(MNT_RDONLY) != 0 { return readOnlyReason }
        return nil
    }
}

/// Sendet die Apple Events an den Finder; in Tests eine Attrappe.
protocol FinderEventSending: Sendable {
    func permissionStatus() async -> OSStatus
    /// Ruft `urls` unmittelbar vor dem Senden im selben Block auf (letzte Prüfung) und sendet das Event mit dem
    /// Ergebnis; ohne Dateien wird nichts gesendet. `nil` bei Erfolg, sonst der Fehlercode des Apple Events.
    func delete(timeout: TimeInterval, urls: @escaping @Sendable () -> [URL]) async -> Int?
}

/// Echte Anbindung: beide Aufrufe blockieren (Rückfrage, Passwortdialog) und laufen daher auf einer eigenen Queue.
struct AppleEventFinderSender: FinderEventSending {
    private static let queue = DispatchQueue(label: "de.cstrube.Grantry.finder-events", qos: .userInitiated)

    func permissionStatus() async -> OSStatus {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: FinderTrash.finderBundleID)
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEDelete), true
                ))
            }
        }
    }

    func delete(timeout: TimeInterval, urls makeURLs: @escaping @Sendable () -> [URL]) async -> Int? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let urls = makeURLs()
                guard !urls.isEmpty else { return continuation.resume(returning: nil) }
                do {
                    let reply = try FinderDeleteEvent.make(urls: urls).sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
                    continuation.resume(returning: FinderDeleteEvent.errorCode(in: reply))
                } catch {
                    continuation.resume(returning: (error as NSError).code)
                }
            }
        }
    }
}

/// `tell application "Finder" to delete {…}` als Deskriptor – ohne AppleScript-Quelltext (kein Escaping von Pfaden).
enum FinderDeleteEvent {
    static func make(urls: [URL]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: FinderTrash.finderBundleID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
        }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// Fehlernummer aus der Antwort des Finders; `nil` ohne oder mit `noErr`. Ein Fehler des Empfängers steht nur in
    /// der Antwort (`keyErrorNumber`), ohne dass `sendEvent` wirft.
    static func errorCode(in reply: NSAppleEventDescriptor) -> Int? {
        guard let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != noErr else {
            return nil
        }
        return Int(code)
    }
}
