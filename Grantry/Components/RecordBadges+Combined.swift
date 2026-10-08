import ManagerKit

extension RecordBadges {
    /// Zusammengefasste Badges mehrerer Einträge (z. B. einer App-Gruppe): jede Art höchstens einmal, „prüfen“ mit
    /// dem höchsten Schweregrad; Reihenfolge wie bei `badges(for:)`.
    func badges(forAll recordIDs: some Sequence<String>) -> [RecordBadge] {
        let all = recordIDs.flatMap(badges(for:))
        let highestSeverity = all.compactMap { badge -> RiskFinding.Severity? in
            if case .review(let severity) = badge { severity } else { nil }
        }.max()
        return [
            all.contains(.new) ? RecordBadge.new : nil,
            highestSeverity.map(RecordBadge.review),
            all.contains(.cleanup) ? RecordBadge.cleanup : nil,
        ].compactMap(\.self)
    }
}
