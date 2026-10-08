import CryptoKit
import Foundation
import GrantryShared
import os

/// Fingerabdruck maskierter Rohwerte (#137): erkennt, dass sich ein maskiertes Geheimnis geändert hat, ohne es zu
/// speichern. Ein HMAC-SHA256 mit einem zufälligen Schlüssel dieser Installation (`SecretFingerprinter`) – kein
/// ungesalzener Hash: Kurze Passwörter und Token mit bekanntem Präfix ließen sich aus einem durchgesickerten Verlauf
/// sonst per Wörterbuch zurückrechnen. Ohne den Schlüssel ist der Wert wertlos.
///
/// `keyID` nennt den Schlüssel, mit dem der Fingerabdruck entstand. Fingerabdrücke mit verschiedenen Schlüsseln (Datei
/// verloren, Rückfall auf einen flüchtigen Schlüssel) sind nicht vergleichbar – das ist dann „unbekannt“, keine Änderung.
public struct SecretFingerprint: Hashable, Sendable, Codable {
    public let keyID: String
    public let digest: String

    public init(keyID: String, digest: String) {
        self.keyID = keyID
        self.digest = digest
    }

    /// `true`/`false`, wenn beide mit demselben Schlüssel entstanden; sonst `nil` (nicht vergleichbar).
    public func differs(from other: SecretFingerprint) -> Bool? {
        keyID == other.keyID ? digest != other.digest : nil
    }

    /// Meldenswerte Änderung zwischen zwei Fingerabdrücken: Beide sind bekannt, mit demselben Schlüssel entstanden und
    /// verschieden. Ein fehlender (älterer Snapshot, nichts maskiert) oder ein mit anderem Schlüssel gebildeter
    /// Fingerabdruck ist „unbekannt“ – kein Ereignis, auch wenn der Snapshot deshalb neu gespeichert wird.
    public static func reportablyDiffers(_ lhs: SecretFingerprint?, _ rhs: SecretFingerprint?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.differs(from: rhs) ?? false
    }
}

/// Bildet `SecretFingerprint`s mit einem Schlüssel dieser Installation.
///
/// Der Schlüssel liegt als private Datei im Ablageort der App (`StorageLocation.secretFingerprintKeyURL`,
/// `SecretFingerprintKeyFile`: `0600`, ohne ACL, geprüft wie die Instanzsperre, vom Backup ausgenommen) – bewusst
/// nicht im Schlüsselbund: Wer die Datei lesen kann, kann auch die Plists selbst lesen, in denen die Geheimnisse
/// ohnehin im Klartext stehen. Der Schlüssel schützt den Verlauf, wenn er ohne ihn die
/// Maschine verlässt (Backup, Diagnose, Weitergabe), und erspart Schlüsselbund-Abfragen bei Signaturwechseln.
public struct SecretFingerprinter: Sendable {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "secrets")
    /// Schlüssellänge in Bytes (256 Bit).
    static let keyLength = 32

    private let key: SymmetricKey
    /// Kennung des Schlüssels: gekürzter SHA-256 über den Schlüssel – verrät ihn bei 256 Bit Zufall nicht.
    public let keyID: String

    init(key: Data) {
        self.key = SymmetricKey(data: key)
        keyID = Self.hex(SHA256.hash(data: Data("Grantry.SecretFingerprint.keyID".utf8) + key).prefix(8))
    }

    /// Ein flüchtiger Schlüssel, für die ganze Laufzeit des Prozesses derselbe: für Vergleiche, die den Prozess nie
    /// verlassen (Inhalts-Stempel, Bearbeiten), und als Vorgabe in Tests.
    public static let processLocal = ephemeral()

    /// Flüchtiger Schlüssel nur für diesen Prozess – für Tests und als Rückfall, wenn die Schlüsseldatei nicht nutzbar
    /// ist. Fingerabdrücke daraus sind nach einem Neustart nicht mehr vergleichbar (kein Ereignis, nur neu gespeichert).
    public static func ephemeral() -> SecretFingerprinter {
        SecretFingerprinter(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Schlüssel aus `url` (`SecretFingerprintKeyFile`); fehlt die Datei oder ist sie unzulässig, wird ein neuer Schlüssel
    /// angelegt. Scheitert das – etwa in einem nicht vertrauenswürdigen Ordner –, gilt ein flüchtiger Schlüssel
    /// (`ephemeral()`).
    public static func persistent(at url: URL) -> SecretFingerprinter {
        do {
            return SecretFingerprinter(key: try SecretFingerprintKeyFile.loadOrCreate(at: url, length: keyLength))
        } catch {
            logger.error("Schlüssel für Fingerabdrücke nicht nutzbar: \(error.readableDescription, privacy: .public)")
            return ephemeral()
        }
    }

    /// Fingerabdruck einer Werteliste. Jeder Wert geht mit seiner Länge ein, damit Grenzen zwischen Werten zählen
    /// (`["a b"]` ≠ `["a", "b"]`).
    public func fingerprint(of values: [String]) -> SecretFingerprint {
        var message = Data()
        for value in values {
            let bytes = Data(value.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { message.append(contentsOf: $0) }
            message.append(bytes)
        }
        let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return SecretFingerprint(keyID: keyID, digest: Self.hex(Data(code).prefix(16)))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension StorageLocation {
    /// Schlüssel der Fingerabdrücke maskierter Argumente (`SecretFingerprinter`).
    public var secretFingerprintKeyURL: URL { directory.appending(path: "SecretFingerprint.key") }

    /// Fingerabdrücke mit dem Schlüssel dieses Ablageorts; legt ihn beim ersten Aufruf an.
    public func secretFingerprinter() -> SecretFingerprinter { .persistent(at: secretFingerprintKeyURL) }
}
