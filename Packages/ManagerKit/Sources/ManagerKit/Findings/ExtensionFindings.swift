import Foundation

extension SystemFinding {
    /// Befunde der Erweiterungen (`ExtensionRiskRules`) für Lagezeile und Wachbuch: je Erweiterung der schwerste Befund
    /// ab **mittel** – Hinweise und Reste sind keine Befunde –, **hoch** als kritisch. Akzeptierte Erweiterungen
    /// (`ExtensionRiskAcceptanceStore`) fehlen.
    ///
    /// Bestandsbefunde haben keine Messreihe: Beginn ist „erstmals gesehen“, damit ID und Wachbuch-Eintrag über Scans
    /// gleich bleiben; sie laufen, solange die Erweiterung auffällig ist. Das Ende setzt, wer sie über Scans verfolgt.
    /// Reihenfolge wie `records`.
    public static func extensionFindings(_ findings: [RiskFinding], in records: [ExtensionRecord],
                                         acceptedIDs: Set<String> = []) -> [SystemFinding] {
        let strongest = Dictionary(
            findings.filter { $0.severity >= .medium }.map { ($0.recordID, $0) },
            uniquingKeysWith: { first, second in second.severity > first.severity ? second : first }
        )
        return records.compactMap { record in
            guard !acceptedIDs.contains(record.id), let finding = strongest[record.id] else { return nil }
            return SystemFinding(
                kind: .extensionRisk, tone: finding.severity == .high ? .critical : .finding,
                reason: finding.message + ".", start: record.firstSeenAt, end: nil,
                evidence: .init(limit: FindingThresholds.standard.extensionRisk.limit, peak: 1, mean: 1),
                subject: .systemExtension(identifier: record.id, name: ExtensionTexts.label(of: record))
            )
        }
    }
}
