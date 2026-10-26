import Foundation

/// Verknüpfte Git-Worktrees lesen, ohne `git` zu starten (#250, #255): Dort ist `.git` eine reguläre Datei mit der
/// Zeile `gitdir: <Pfad>`; ein relativer Pfad gilt ab dem Worktree. Gelesen wird ohne Blockieren und begrenzt.
enum GitWorktree {
    /// Höchstgröße einer gelesenen `.git`- oder `HEAD`-Datei – echte enthalten nur eine Zeile.
    static let maximumFileLength = 4_096

    /// Was `HEAD` ausgecheckt hat.
    enum Head: Equatable {
        case branch(String)
        case detached
    }

    /// Der in `<directory>/.git` genannte Git-Ordner; `nil`, wenn `.git` keine solche Datei ist (Hauptklon, kein Git).
    static func linkedGitDirectory(of directory: String) -> String? {
        guard let path = firstLine(of: directory + "/.git", after: "gitdir: ") else { return nil }
        return path.hasPrefix("/") ? path : directory + "/" + path
    }

    /// `HEAD` im Git-Ordner: Branch oder losgelöst (Commit-ID); `nil`, wenn nicht lesbar oder unbekannt.
    static func head(inGitDirectory gitDirectory: String) -> Head? {
        let file = gitDirectory + "/HEAD"
        if let reference = firstLine(of: file, after: "ref: ") {
            let branchPrefix = "refs/heads/"
            return .branch(reference.hasPrefix(branchPrefix) ? String(reference.dropFirst(branchPrefix.count)) : reference)
        }
        guard let commit = firstLine(of: file, after: ""), [40, 64].contains(commit.count),
              commit.allSatisfy(\.isHexDigit) else { return nil }
        return .detached
    }

    /// Erste Zeile einer regulären Datei (kein Symlink) hinter `prefix`; `nil`, wenn sie fehlt oder danach leer ist.
    private static func firstLine(of path: String, after prefix: String) -> String? {
        guard FileType.isPlainRegularFile(atPath: path),
              let data = FileType.contentsOfRegularFile(atPath: path, maximumLength: maximumFileLength),
              let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first,
              line.hasPrefix(prefix), line.count > prefix.count else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}
