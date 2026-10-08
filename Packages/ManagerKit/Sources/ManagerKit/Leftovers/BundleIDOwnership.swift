import Foundation
import GrantryShared

/// Ordnet Kennungen aus Eintragsnamen installierten Apps zu: exakt oder als `<id>.`-Präfix; der längste Treffer
/// gewinnt (`com.foo.app.pro` gehört `com.foo.app.pro`, nicht `com.foo.app`). Ohne Groß-/Kleinschreibung.
///
/// Bundle-IDs, die nur ein Namensraum sind, besitzen nichts: Eine Kennung braucht mindestens zwei Bestandteile (`com`
/// allein zählt nicht) und für Präfix-Treffer drei (`org.darktable` besitzt `org.darktable`, aber nicht
/// `org.darktable.helper`). Apple-Kennungen (`com.apple.…`) gehören nur Apps mit Apple-Kennung, die nachweislich von
/// Apple stammen und keine System-App sind (`AppleAppVerification`) – eine unsignierte Kopie mit der Bundle-ID
/// `com.apple.Notes` erbt so nie die Daten von Notizen.
struct BundleIDOwnership: Sendable {
    /// Mindestzahl der Bestandteile einer Bundle-ID für exakte Treffer bzw. für Präfix-Treffer.
    static let minimumExactComponents = 2
    static let minimumPrefixComponents = 3

    private let identifiers: [String]

    init(_ apps: [InstalledApp], verification: AppleAppVerification) {
        self.init(bundleIDs: apps.filter(verification.mayOwnEntries).compactMap(\.bundleID))
    }

    /// Ohne Herkunftsprüfung – jede Bundle-ID besitzt ihre Einträge (für Abgleiche, in denen Apple-Kennungen ohnehin
    /// ausgeschlossen sind).
    init(bundleIDs: some Sequence<String>) {
        identifiers = Set(bundleIDs.map { $0.lowercased() }.filter(Self.canOwn))
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// Bundle-ID (klein) der App, der `identifier` gehört.
    func owner(of identifier: String) -> String? {
        let identifier = identifier.lowercased()
        let isApple = AppleEntryName.isApple(identifier)
        return identifiers.first { owner in
            Self.isOwned(identifier, by: owner) && (!isApple || AppleEntryName.isApple(owner))
        }
    }

    /// `identifier` gehört `owner` (beide klein): gleich, oder `<owner>.`-Präfix ab `minimumPrefixComponents`
    /// Bestandteilen; byteweise verglichen.
    static func isOwned(_ identifier: String, by owner: String) -> Bool {
        identifier == owner
            || (components(of: owner).count >= minimumPrefixComponents && identifier.utf8.starts(with: (owner + ".").utf8))
    }

    private static func canOwn(_ identifier: String) -> Bool {
        let parts = components(of: identifier)
        return parts.count >= minimumExactComponents && !parts.contains { $0.isEmpty }
    }

    private static func components(of identifier: String) -> [Substring.UTF8View] {
        identifier.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    }
}

/// Herstellerbestandteil einer Bundle-ID (`com.valvesoftware.steam` → `valvesoftware`), mindestens 4 Zeichen; Hosting-
/// und Sammelnamen sagen nichts über den Hersteller.
enum VendorToken {
    static let ignored: Set<String> = ["github", "gitlab", "bitbucket", "sourceforge", "googlecode", "codeberg", "apple"]

    static func of(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3, parts[1].count >= 4, !ignored.contains(String(parts[1])) else { return nil }
        return String(parts[1])
    }
}

/// Name eines Gruppen-Containers: `<TEAMID>.<rest>` (Team-ID: 10 Großbuchstaben/Ziffern) oder `group.<rest>`.
enum GroupContainerName: Equatable {
    case team(String, rest: String)
    case group(String)

    init?(_ name: String) {
        if name.hasPrefix("group.") {
            guard name.count > "group.".count else { return nil }
            self = .group(String(name.dropFirst("group.".count)))
            return
        }
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10,
              parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        self = .team(String(parts[0]), rest: String(parts[1]))
    }
}
