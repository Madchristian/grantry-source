import Darwin
import Foundation

/// Art eines Dateisystemeintrags, soweit sie für das gefahrlose Öffnen zählt.
///
/// Signaturprüfung (`SecStaticCodeCreateWithPath`), Shebang-Lesen und das Lesen von `Info.plist` öffnen Dateien. Eine
/// FIFO kann dabei blockieren, bis ein Schreiber kommt, Geräte und Sockets verhalten sich ähnlich unberechenbar – jeder
/// Benutzerprozess könnte so einen Scan anhalten. Geöffnet werden daher nur reguläre Dateien und Bundles, deren
/// `Info.plist` und Hauptprogramm reguläre Dateien sind.
///
/// Die Prüfung schließt ein Rennen nicht aus (Austausch gegen eine FIFO nach der Prüfung); dagegen laufen
/// Signaturprüfungen zusätzlich mit Zeitgrenze (`BlockingCallGuard`).
enum FileType {
    /// Höchstgröße einer gelesenen `Info.plist` – echte sind wenige KB groß.
    static let maximumInfoPlistLength = 1 << 20

    /// `true`, wenn `path` (Symlinks aufgelöst) eine reguläre Datei ist oder ein Verzeichnis, dessen `Info.plist`,
    /// `_CodeSignature/CodeResources` und Hauptprogramm (`CFBundleExecutable`) – soweit vorhanden – reguläre Dateien
    /// sind (`BundleLayout`). Bei einer
    /// iOS-App im Wrapper gilt das zusätzlich für alles, was Security.framework dort öffnet
    /// (`WrapperLayout.isSafeToInspect`).
    static func isSafeToInspect(atPath path: String) -> Bool {
        guard let info = status(of: path) else { return false }
        if isRegularFile(info) { return true }
        guard isDirectory(info), BundleLayout(path: path).hasOnlyRegularFiles else { return false }
        return WrapperLayout(path: path)?.isSafeToInspect ?? true
    }

    static func isRegularFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
    }

    static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR
    }

    /// FIFO, Socket oder Gerät – Dateiarten, deren Öffnen blockieren oder Nebenwirkungen haben kann.
    static func isSpecialFile(mode: mode_t) -> Bool {
        RegularFileReader.isSpecialFile(mode: mode)
    }

    /// Ergebnis der Suche nach Sonderdateien in einem Verzeichnisbaum.
    enum SpecialFileScan: Equatable, Sendable {
        /// Keine Sonderdatei, auch nicht als Symlink-Ziel.
        case clean
        case found
        /// Grenze erreicht (`SpecialFileScanLimits`) – der Baum ist nicht vollständig geprüft.
        case incomplete
    }

    /// Grenzen der Suche (Review N5): `stat` auf ein Symlink-Ziel kann an einem hängenden Volume (Netz, Automounter)
    /// lange dauern – höchstens `maximumLinkChecks` solche Aufrufe, und die ganze Suche endet nach `deadline`.
    struct SpecialFileScanLimits: Equatable, Sendable {
        var maximumLinkChecks: Int
        var deadline: Duration

        /// Großzügig: Xcode hat einige Tausend Symlinks, die Suche dauert dort Sekunden.
        static let standard = SpecialFileScanLimits(maximumLinkChecks: 50_000, deadline: .seconds(120))
    }

    /// Sucht im Verzeichnisbaum unter `path` eine Sonderdatei (`isSpecialFile(mode:)`) – auch als Ziel eines Symlinks
    /// im Baum, dem die Signaturprüfung folgen könnte. Durchsucht wird per `fts` physisch (`lstat`), ohne eine Datei zu
    /// öffnen und ohne Symlinks zu betreten; Symlink-Ziele werden nur per `stat` angesehen, begrenzt durch `limits`.
    /// Ist `path` selbst kein Verzeichnis, `clean` (das beurteilt `isSafeToInspect(atPath:)`).
    static func specialFiles(inTreeAt path: String, limits: SpecialFileScanLimits = .standard) -> SpecialFileScan {
        guard status(of: path).map(isDirectory) == true, let argument = strdup(path) else { return .clean }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, nil) else { return .clean }
        defer { fts_close(stream) }
        let deadline = ContinuousClock.now + limits.deadline
        var linkChecks = 0
        while let entry = fts_read(stream) {
            guard ContinuousClock.now < deadline else { return .incomplete }
            switch Int32(entry.pointee.fts_info) {
            case FTS_SL, FTS_SLNONE:
                linkChecks += 1
                guard linkChecks <= limits.maximumLinkChecks else { return .incomplete }
                let target = String(cString: entry.pointee.fts_path)
                if let info = status(of: target), isSpecialFile(mode: info.st_mode) { return .found }
            case FTS_DEFAULT:
                if isSpecialFile(mode: entry.pointee.fts_statp.pointee.st_mode) { return .found }
            default:
                continue
            }
        }
        return .clean
    }

    /// `stat` von `path` (folgt Symlinks); `nil`, wenn der Pfad fehlt oder nicht lesbar ist.
    static func status(of path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }

    /// `lstat` von `path` (folgt Symlinks **nicht**); `nil`, wenn der Pfad fehlt oder nicht lesbar ist.
    static func linkStatus(of path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func isSymbolicLink(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFLNK
    }

    /// Verzeichnis, das selbst kein Symlink ist.
    static func isPlainDirectory(atPath path: String) -> Bool {
        linkStatus(of: path).map(isDirectory) == true
    }

    /// Reguläre Datei, die selbst kein Symlink ist.
    static func isPlainRegularFile(atPath path: String) -> Bool {
        linkStatus(of: path).map(isRegularFile) == true
    }

    /// Eintrag vorhanden – auch ein ins Leere zeigender Symlink zählt.
    static func exists(atPath path: String) -> Bool {
        linkStatus(of: path) != nil
    }

    /// Höchstens `maximumLength` Bytes vom Anfang der regulären Datei `path` (Symlinks aufgelöst); `nil` für alles
    /// andere. Geöffnet wird mit `O_NONBLOCK` (eine FIFO blockiert so nicht) und `O_NOCTTY` (ein Terminal wird nie zum
    /// steuernden Terminal), die Art prüft `fstat` am geöffneten Deskriptor – ohne Rennen zwischen Prüfung und Lesen.
    static func contentsOfRegularFile(atPath path: String, maximumLength: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isRegularFile(info) else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        var count = 0
        while count < maximumLength {
            let chunk = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + count, maximumLength - count) }
            if chunk < 0, errno == EINTR { continue }
            guard chunk > 0 else { break }
            count += chunk
        }
        return count > 0 ? Data(buffer.prefix(count)) : nil
    }
}

/// Aufbau eines Bundles, soweit Security.framework ihn öffnet: `Info.plist` und Hauptprogramm unter `Contents/`
/// (`Contents/MacOS/<CFBundleExecutable>`, macOS) oder direkt im Bundle (flache Bundles).
struct BundleLayout {
    let infoPlist: String
    let executableDirectory: String
    /// `Contents/Resources` (macOS) bzw. das Bundle selbst (flach).
    let resourcesDirectory: String
    /// `_CodeSignature/CodeResources` – liest Security.framework (`SecStaticCode`) bei jeder Prüfung.
    let codeResources: String
    /// Bundle-Name ohne Endung – Hauptprogramm, wenn `CFBundleExecutable` fehlt (wie bei CFBundle).
    private let bundleName: String

    init(path: String) {
        bundleName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let contents = path + "/Contents"
        let isDeep = FileType.status(of: contents).map(FileType.isDirectory) == true
        infoPlist = (isDeep ? contents : path) + "/Info.plist"
        executableDirectory = isDeep ? contents + "/MacOS" : path
        resourcesDirectory = isDeep ? contents + "/Resources" : path
        codeResources = (isDeep ? contents : path) + "/_CodeSignature/CodeResources"
    }

    /// `true`, wenn `Info.plist`, `_CodeSignature/CodeResources` und Hauptprogramm reguläre Dateien sind oder fehlen.
    /// Ein Programmname mit `/` (oder `.`, `..`) könnte aus dem Bundle hinauszeigen und gilt als unsicher.
    var hasOnlyRegularFiles: Bool {
        guard isRegularOrMissing(infoPlist), isRegularOrMissing(codeResources) else { return false }
        guard let name = executableName else { return true }
        guard let executable = executablePath(named: name) else { return false }
        return isRegularOrMissing(executable)
    }

    /// Name des Hauptprogramms laut `Info.plist` (gelesen ohne Blockieren, siehe `executableName(in:)`).
    var executableName: String? {
        executableName(in: info)
    }

    /// `CFBundleExecutable` aus `info`; fehlt der Schlüssel, der Bundle-Name (so startet macOS etwa
    /// `CameraSurveyProgram.app`). `nil`, wenn der Wert kein Text ist.
    func executableName(in info: [String: Any]) -> String? {
        guard let value = info["CFBundleExecutable"] else { return bundleName }
        return value as? String
    }

    /// Pfad des Hauptprogramms `name` im Bundle; `nil`, wenn der Name aus dem Bundle hinauszeigen könnte (`/`, `.`,
    /// `..`) oder leer ist.
    func executablePath(named name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return executableDirectory + "/" + name
    }

    /// Inhalt der `Info.plist`, gelesen ohne Blockieren (`FileType.contentsOfRegularFile`); leer, wenn sie fehlt, keine
    /// reguläre Datei, zu groß oder unlesbar ist.
    var info: [String: Any] {
        guard let data = FileType.contentsOfRegularFile(atPath: infoPlist, maximumLength: FileType.maximumInfoPlistLength),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    private func isRegularOrMissing(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return errno == ENOENT }
        return FileType.isRegularFile(info)
    }
}

/// iOS-App im Wrapper (vgl. `/Applications/tunneldebugger.app`): kein `Contents/`, das eigentliche Bundle liegt in
/// `Wrapper/<Name>.app`, `WrappedBundle` ist ein Symlink darauf, daneben `iTunesMetadata.plist` u. a.
struct WrapperLayout {
    let path: String
    private var wrapper: String { path + "/Wrapper" }
    private var wrappedBundleLink: String { path + "/WrappedBundle" }

    /// `nil`, wenn `path` kein Wrapper ist: Es hat `Contents/` oder weder `Wrapper` noch `WrappedBundle`.
    init?(path: String) {
        guard !FileType.exists(atPath: path + "/Contents"),
              FileType.exists(atPath: path + "/Wrapper") || FileType.exists(atPath: path + "/WrappedBundle") else { return nil }
        self.path = path
    }

    /// Das innere Bundle, aus dem Grantry liest: genau ein `.app`-Verzeichnis (kein Symlink) in `Wrapper/`. Der
    /// `WrappedBundle`-Symlink wird bewusst nicht verfolgt.
    var innerBundle: String? {
        guard FileType.isPlainDirectory(atPath: wrapper) else { return nil }
        let apps = wrapperEntries.filter { $0.hasSuffix(".app") && FileType.isPlainDirectory(atPath: wrapper + "/" + $0) }
        return apps.count == 1 ? wrapper + "/" + apps[0] : nil
    }

    /// `true`, wenn nichts, was Security.framework im Wrapper öffnen könnte, eine Sonderdatei ist:
    /// jedes `.app` in `Wrapper/` und das Ziel von `WrappedBundle` (falls vorhanden) ist ein Verzeichnis mit sicherem
    /// `BundleLayout`, jeder andere Eintrag in `Wrapper/` (Symlinks aufgelöst) eine reguläre Datei oder ein Verzeichnis.
    /// Geprüft wird nur per `stat`/`lstat`.
    var isSafeToInspect: Bool {
        if FileType.exists(atPath: wrapper) {
            guard let info = FileType.status(of: wrapper), FileType.isDirectory(info) else { return false }
            for name in wrapperEntries {
                guard Self.isSafeEntry(wrapper + "/" + name, isBundle: name.hasSuffix(".app")) else { return false }
            }
        }
        // Ein ins Leere zeigender Symlink öffnet nichts.
        guard FileType.exists(atPath: wrappedBundleLink), FileType.status(of: wrappedBundleLink) != nil else { return true }
        return Self.isSafeEntry(wrappedBundleLink, isBundle: true)
    }

    private var wrapperEntries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: wrapper)) ?? []).sorted()
    }

    private static func isSafeEntry(_ path: String, isBundle: Bool) -> Bool {
        guard let info = FileType.status(of: path) else { return true }
        if isBundle { return FileType.isDirectory(info) && BundleLayout(path: path).hasOnlyRegularFiles }
        return FileType.isRegularFile(info) || FileType.isDirectory(info)
    }
}
