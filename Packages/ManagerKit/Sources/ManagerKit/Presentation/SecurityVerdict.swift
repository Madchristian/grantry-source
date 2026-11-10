import Foundation

/// Lagezeile und Panel „Schutz“ des Bereichs Sicherheit im Lagebild (Spec 2026-11-08 §5.5, Design-Standard §3.10,
/// #407): das Urteil entsteht aus den Prüfungen, nie aus einem einzelnen Wert. „Offen“ heißt Hinweis oder kritisch;
/// nicht prüfbare Prüfungen zählen eigens – weder als offen noch als Entwarnung.
extension SecurityOverview {
    /// Höchstens so viele Chips trägt die Lagezeile.
    static let maximumVerdictItems = 3
    /// Damit füllt die Lagezeile freie Chips auf, wenn sie in Ordnung sind.
    private static let coreKinds: [SecurityCheckKind] = [.fileVault, .firewall, .sip]

    public var goodCount: Int { checks.count { $0.state == .good } }
    public var uncheckedCount: Int { checks.count { $0.state == .unknown } }

    /// Prüfungen außer „in Ordnung“: kritisch, dann Hinweis, dann nicht prüfbar, je in Anzeigereihenfolge.
    private var pending: [SecurityCheckPresentation] {
        let order: [SecurityState] = [.critical, .warning, .unknown]
        return order.flatMap { state in checks.filter { $0.state == state } }
    }

    /// Die Prüfung, die Urteil und Grund bestimmt und beim Öffnen aufgeklappt ist; `nil`, wenn alle in Ordnung sind.
    public var leadingCheckID: String? { pending.first?.id }

    /// Peilkopf des Panels: „8 von 10 in Ordnung · 1 nicht prüfbar“.
    public var panelDetail: String {
        let good = "\(goodCount) von \(checks.count) in Ordnung"
        return uncheckedCount > 0 ? "\(good) · \(uncheckedCount) nicht prüfbar" : good
    }

    /// Wert im Peilkopf: offene Punkte („2 offen“), sonst leer.
    public var panelValue: String { hintCount > 0 ? "\(hintCount) offen" : "" }

    /// Urteil für die Lagezeile; `helperState` ergänzt die Kenndaten, weil die Aktionen davon abhängen.
    public func verdict(helperState: HelperState?) -> SystemVerdict {
        let pending = pending
        let unchecked = pending.filter { $0.state == .unknown }
        let level: SystemVerdict.Level = criticalCount > 0 ? .critical : hintCount > 0 ? .finding : .calm
        let facts = ["\(checks.count) Prüfungen", helperState.map { $0 == .ready ? "Helper bereit" : "Helper nicht bereit" }]
        return SystemVerdict(level: level, title: title(lead: pending.first, unchecked: unchecked.count),
                             reason: reason(lead: pending.first, unchecked: unchecked),
                             items: items(pending), processFindings: [],
                             facts: facts.compactMap(\.self).joined(separator: " · "))
    }

    private func title(lead: SecurityCheckPresentation?, unchecked: Int) -> String {
        switch (criticalCount, hintCount, unchecked) {
        case (1, _, _): "Kritisch: \(lead?.brief ?? "")"
        case (2..., _, _): "\(criticalCount) Punkte kritisch"
        case (_, 1, _): "1 Punkt offen"
        case (_, 2..., _): "\(hintCount) Punkte offen"
        case (_, _, 1): "1 Prüfung nicht möglich"
        case (_, _, 2...): "\(unchecked) Prüfungen nicht möglich"
        default: "Geschützt"
        }
    }

    private func reason(lead: SecurityCheckPresentation?, unchecked: [SecurityCheckPresentation]) -> String {
        if hintCount > 0, let lead { return lead.summary }
        guard !unchecked.isEmpty else { return "Alle \(checks.count) Prüfungen sind in Ordnung." }
        let titles = unchecked.map(\.title)
        let names = titles.count == 1 ? titles[0] : titles.dropLast().joined(separator: ", ") + " und " + titles[titles.count - 1]
        let verb = titles.count == 1 ? "konnte" : "konnten"
        return "\(names) \(verb) nicht geprüft werden, die übrigen Prüfungen sind in Ordnung."
    }

    /// Offene und nicht prüfbare Punkte zuerst, bei mehr als drei die übrigen als „n weitere“; freie Plätze füllen
    /// FileVault, Firewall und SIP, wenn sie in Ordnung sind.
    private func items(_ pending: [SecurityCheckPresentation]) -> [SystemVerdict.Item] {
        let limit = Self.maximumVerdictItems
        var items = pending.prefix(pending.count > limit ? limit - 1 : limit).map { Self.item($0) }
        if pending.count > limit {
            let rest = pending.dropFirst(limit - 1)
            items.append(SystemVerdict.Item(text: "\(rest.count) weitere", tone: rest.first?.state.tone ?? .neutral))
        }
        let core = Self.coreKinds.compactMap { kind in checks.first { $0.kind == kind && $0.state == .good } }
        return items + core.prefix(max(limit - items.count, 0)).map { Self.item($0) }
    }

    /// Chip im Ton der Ampel (`SecurityState.tone`), Text als Kurzbefund.
    private static func item(_ check: SecurityCheckPresentation) -> SystemVerdict.Item {
        SystemVerdict.Item(text: check.brief, tone: check.state.tone)
    }
}
