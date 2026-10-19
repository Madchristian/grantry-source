import Foundation
import GrantryShared

/// Herkunft (Website) von WebKit-Websitedaten aus der Datei `origin` neben `LocalStorage`/`IndexedDB` (#226).
///
/// Format (WebKit, `WTF::Persistence::Encoder`): zwei Herkünfte – oberste Seite, dann der Rahmen –, je Schema und Host
/// als Zeichenkette (`UInt32` Länge LE, ein Byte „8 Bit“, dann die Zeichen in Latin-1 oder UTF-16LE) und der Port als
/// Optional (ein Byte, ggf. `UInt16` LE). Alles Unerwartete ergibt `nil`; dann bleibt der Eintrag ohne Herkunft.
struct WebKitOrigin: Hashable, Sendable {
    /// Größe, ab der die Datei nicht gelesen wird (echte Dateien haben unter 200 Byte).
    static let maximumFileSize = 4096
    /// Längste akzeptierte Zeichenkette.
    static let maximumStringLength = 1024

    let scheme: String
    let host: String
    let port: UInt16?

    /// „unifi.ui.com“, „example.com:8443“; ohne Host das Schema („file:“).
    var text: String {
        guard !host.isEmpty else { return scheme + ":" }
        return host + (port.map { ":\($0)" } ?? "")
    }

    /// Titel für den Eintrag: der Rahmen, ist die oberste Seite eine andere, mit „(in …)“.
    static func title(fromFileAt path: String) -> String? {
        guard FileIdentity.of(path)?.type == .regularFile,
              case .contents(let data, _) = RegularFileReader.read(atPath: path, maximumSize: maximumFileSize),
              let (top, frame) = parse(data) else { return nil }
        return frame == top ? frame.text : "\(frame.text) (in \(top.text))"
    }

    static func parse(_ data: Data) -> (top: WebKitOrigin, frame: WebKitOrigin)? {
        var reader = Reader(bytes: [UInt8](data))
        guard let top = reader.origin(), let frame = reader.origin() else { return nil }
        return (top, frame)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func origin() -> WebKitOrigin? {
            guard let scheme = string(), !scheme.isEmpty, let host = string(), let hasPort = byte(), hasPort <= 1 else {
                return nil
            }
            var port: UInt16?
            if hasPort == 1 {
                guard let low = byte(), let high = byte() else { return nil }
                port = UInt16(high) << 8 | UInt16(low)
            }
            return WebKitOrigin(scheme: DisplayText.singleLine(scheme), host: DisplayText.singleLine(host), port: port)
        }

        private mutating func string() -> String? {
            guard index + 5 <= bytes.count else { return nil }
            let length = (0..<4).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * $1) }
            let isLatin1 = bytes[index + 4]
            index += 5
            guard length <= WebKitOrigin.maximumStringLength, isLatin1 <= 1 else { return nil }
            let byteCount = isLatin1 == 1 ? length : length * 2
            guard index + byteCount <= bytes.count else { return nil }
            let slice = bytes[index..<index + byteCount]
            index += byteCount
            if isLatin1 == 1 { return String(slice.map { Character(Unicode.Scalar($0)) }) }
            let units = stride(from: slice.startIndex, to: slice.endIndex, by: 2).map { UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }

        private mutating func byte() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }
}
