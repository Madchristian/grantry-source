import Darwin
import Synchronization

/// Findet Originale über offen gehaltene Deskriptoren wieder (#143) – auch dann, wenn die App den Papierkorb nicht mehr
/// lesen darf. `~/.Trash` ist TCC-geschützt: Nach dem Zurücksetzen des Festplattenvollzugriffs (das die
/// Selbstdeinstallation vor dem Papierkorb erledigt) scheitert `FSGetPathLocator` dort voraussichtlich – `fsgetpath`
/// prüft das Suchrecht jedes Ordners, und das anschließende `lstat` im Papierkorb verweigert TCC. Ein vorher (mit
/// Freigabe) geöffneter Deskriptor folgt dagegen dem Inode: `fcntl(F_GETPATH)` liefert den aktuellen Pfad ohne
/// Zugriffsprüfung der Ordner, `fstat` Identität und Verknüpfungszahl.
///
/// `track(_:)` öffnet je Original – nur reguläre Dateien und Ordner – einen Deskriptor mit `O_EVTONLY | O_NOFOLLOW |
/// O_NONBLOCK | O_NOCTTY` (nur für Ereignisse, ohne Lese- oder Schreibzugriff; blockiert kein Auswerfen; Symlinks werden
/// nicht geöffnet; eine untergeschobene FIFO hält `open` nicht fest) – nur, wenn am Pfad vorher und nachher dasselbe
/// Objekt liegt. Ohne Deskriptor (etwa nach einem Neustart der App) gilt `fallback`. `release()` bzw. das Freigeben des
/// Objekts schließt alle.
public final class TrackedFileLocator: FileLocating, Sendable {
    private let descriptors = Mutex<[FileIdentity: Int32]>([:])
    private let fallback: any FileLocating

    public convenience init() {
        self.init(fallback: FSGetPathLocator())
    }

    init(fallback: any FileLocating) {
        self.fallback = fallback
    }

    deinit {
        release()
    }

    /// Öffnet für jedes noch nicht verfolgte Original mit bekannter Identität einen Deskriptor.
    func track(_ candidates: [LeftoverCandidate]) {
        for candidate in candidates {
            guard let identity = candidate.identity, Self.isTrackable(identity.type),
                  descriptors.withLock({ $0[identity] == nil }),
                  let current = FileIdentity.of(candidate.path), current == identity else { continue }
            // `O_NONBLOCK`/`O_NOCTTY`: Wird der Pfad zwischen Prüfung und Öffnen gegen eine FIFO oder ein Gerät getauscht,
            // blockiert `open` nicht (eine FIFO ohne Schreiber hielte es sonst unbegrenzt fest – auch `O_EVTONLY` hilft
            // dort nicht) und wird kein steuerndes Terminal; die Identitätsprüfung danach verwirft das fremde Objekt.
            let fd = open(candidate.path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            guard let opened = Self.status(of: fd), FileIdentity(opened) == identity else {
                close(fd)
                continue
            }
            let previous = descriptors.withLock { descriptors in
                defer { descriptors[identity] = fd }
                return descriptors[identity]
            }
            if let previous { close(previous) }
        }
    }

    /// Nur reguläre Dateien und Ordner (Bundles) werden festgehalten; Sonderdateien (FIFO, Gerät, Socket) und Symlinks
    /// nie – für sie gilt der bisherige Weg ohne Öffnen.
    static func isTrackable(_ type: FileIdentity.Kind) -> Bool {
        type == .regularFile || type == .directory
    }

    /// Schließt alle Deskriptoren.
    public func release() {
        let all = descriptors.withLock { descriptors in
            defer { descriptors.removeAll() }
            return Array(descriptors.values)
        }
        for fd in all { close(fd) }
    }

    func locate(_ identity: FileIdentity) -> FileLocation {
        guard let fd = descriptors.withLock({ $0[identity] }) else { return fallback.locate(identity) }
        return Self.locate(descriptor: fd, identity: identity)
    }

    /// `fstat`: keine Verknüpfung mehr → gelöscht; `F_GETPATH`: aktueller Pfad. Zeigt der Pfad – soweit lesbar – ein
    /// anderes Objekt, war die Auflösung überholt (`unknown`); ein verweigertes `lstat` (TCC) widerlegt nichts.
    static func locate(descriptor fd: Int32, identity: FileIdentity) -> FileLocation {
        guard let status = status(of: fd), FileIdentity(status).isSameObject(as: identity) else { return .unknown }
        guard status.st_nlink > 0 else { return .gone }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return .unknown }
        let path = String(cString: buffer)
        if let atPath = FileType.linkStatus(of: path), !FileIdentity(atPath).isSameObject(as: identity) { return .unknown }
        return .found(path: path, hasOtherNames: status.st_mode & S_IFMT == S_IFREG && status.st_nlink > 1)
    }

    private static func status(of fd: Int32) -> stat? {
        var info = stat()
        return fstat(fd, &info) == 0 ? info : nil
    }
}
