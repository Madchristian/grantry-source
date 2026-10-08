import Foundation

/// Hinweise, wenn ein Fund oder Eintrag auch zu weiteren Apps gehören kann.
enum OwnershipNote {
    /// „Gehört evtl. auch zu: A, B“ (sortiert, ohne Doppelte); `nil` ohne Namen. Für Reste weiterer Apps desselben
    /// Herstellers bzw. derselben Bundle-ID (`LeftoverMatcher`) und für Berechtigungen und Autostart-Einträge weiterer
    /// Installationen (`RemovalReview`).
    static func mayBelong(to names: [String]) -> String? {
        names.isEmpty ? nil : "Gehört evtl. auch zu: \(Set(names).sorted().joined(separator: ", "))"
    }

    /// „Tool (~/Applications/Tool.app)“ – unterscheidet Installationen gleichen Namens.
    static func installation(_ app: InstalledApp, home: String) -> String {
        "\(app.name) (\(PathDisplay.abbreviatingHome(app.path, home: home)))"
    }
}
