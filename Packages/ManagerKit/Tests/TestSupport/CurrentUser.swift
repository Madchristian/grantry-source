import Foundation

/// Angaben zum Benutzer, der die Tests ausführt.
public enum CurrentUser {
    /// `true`, wenn `id -Gn` die Gruppe `admin` enthält – unabhängig von `AdminMembership` ermittelt.
    public static var isAdministrator: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        process.arguments = ["-Gn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(whereSeparator: \.isWhitespace).contains("admin")
    }
}
