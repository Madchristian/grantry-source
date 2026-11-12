import Foundation
import Testing
@testable import ManagerKit

/// Zustandszeile der Liste-Detail-Bereiche (Spec 2026-11-10 § 11.2 a): Urteil „N Apps auffällig“ bzw. „N Einträge
/// auffällig“, sonst „Ruhig“; höchstens drei Chips; nur aus vorhandenen Badges, keine neue Regel.
@Suite struct InventoryVerdictTests {
    @Test func countsEntriesWithMediumOrHighFindingAsConspicuous() {
        let verdict = InventoryVerdict(entryBadges: [[.review(.medium), .new], [.review(.high)], [.review(.low)], []],
                                       subject: .apps)
        #expect(verdict.title == "2 Apps auffällig")
        #expect(verdict.isFinding)
    }

    @Test func singularAndEntries() {
        #expect(InventoryVerdict(entryBadges: [[.review(.medium)]], subject: .apps).title == "1 App auffällig")
        #expect(InventoryVerdict(entryBadges: [[.review(.high)], [.review(.medium)]], subject: .entries).title
                == "2 Einträge auffällig")
        #expect(InventoryVerdict(entryBadges: [[.review(.medium)]], subject: .entries).title == "1 Eintrag auffällig")
    }

    /// Ohne auffälligen Eintrag ruhig – auch mit reinen Hinweisen (niedrig), wie die Kachel „Auffällig“.
    @Test func calmWithoutConspicuousEntries() {
        let verdict = InventoryVerdict(entryBadges: [[.review(.low)], [.cleanup], []], subject: .apps)
        #expect(verdict.title == "Ruhig")
        #expect(!verdict.isFinding)
        #expect(verdict.items.isEmpty)
    }

    /// Chips: kritisch, prüfen, neu seit 7 Tagen – in dieser Reihenfolge, je Eintrag einmal gezählt.
    @Test func chipsCountCriticalReviewAndNew() {
        let verdict = InventoryVerdict(entryBadges: [[.new, .review(.high)], [.review(.medium)], [.new], []],
                                       subject: .apps)
        #expect(verdict.items == [SystemVerdict.Item(text: "1 kritisch", tone: .critical),
                                  SystemVerdict.Item(text: "1 prüfen", tone: .warning),
                                  SystemVerdict.Item(text: "2 neu seit 7 Tagen", tone: .neutral)])
    }

    /// Ein bereichseigener dritter Chip (deaktiviert bzw. akzeptiert) und höchstens drei Chips.
    @Test func extraChipAndAtMostThree() {
        let extra = SystemVerdict.Item(text: "1 deaktiviert", tone: .neutral)
        let verdict = InventoryVerdict(entryBadges: [[.review(.high)], [.review(.medium)], [.new]], subject: .entries,
                                       extra: extra)
        #expect(verdict.items.count == 3)
        #expect(!verdict.items.contains(extra))
        let calm = InventoryVerdict(entryBadges: [[.new]], subject: .entries, extra: extra)
        #expect(calm.items == [SystemVerdict.Item(text: "1 neu seit 7 Tagen", tone: .neutral), extra])
    }

    /// Unvollständige Abdeckung: kein ruhiges Urteil als Entwarnung, Chip mit der Zahl fehlender Quellen zuerst.
    @Test func incompleteCoverageIsNoAllClear() {
        let verdict = InventoryVerdict(entryBadges: [[]], subject: .apps, missingSources: 1)
        #expect(verdict.title == "Nicht vollständig geprüft")
        #expect(verdict.isFinding)
        #expect(verdict.items.first == SystemVerdict.Item(text: "1 Quelle fehlt", tone: .warning))
        let flagged = InventoryVerdict(entryBadges: [[.review(.medium)]], subject: .apps, missingSources: 2)
        #expect(flagged.title == "1 App auffällig")
        #expect(flagged.items.first == SystemVerdict.Item(text: "2 Quellen fehlen", tone: .warning))
    }

    @Test func notScannedYet() {
        let verdict = InventoryVerdict.notScanned
        #expect(verdict.title == "Noch nicht geprüft")
        #expect(!verdict.isFinding)
        #expect(verdict.items.isEmpty)
    }

    /// Ohne Urteil keine Entwarnung: vor dem ersten Scan die Schildform „offen“ (Spec § 11.3 c), sonst ruhig oder Befund.
    @Test func shieldIsOpenOnlyWithoutVerdict() {
        #expect(InventoryVerdict.notScanned.shield == .open)
        #expect(InventoryVerdict(entryBadges: [[]], subject: .apps).shield == .calm)
        #expect(InventoryVerdict(entryBadges: [[.review(.high)]], subject: .apps).shield == .finding)
        #expect(InventoryVerdict(entryBadges: [[]], subject: .apps, missingSources: 1).shield == .finding)
    }
}
