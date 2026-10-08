import ManagerKit
import SwiftUI

/// Was der nächste Schritt einer Abdeckungslücke auslöst (`AreaCoverage.nextStep(missingSetupSteps:)`); stellt
/// `RootView` bereit. Ohne ihn (Vorschauen, Menüleiste) zeigt `AreaCoverageBar` keine Schaltfläche.
struct CoverageStepHandler {
    /// Nachweislich fehlende erforderliche Einrichtungsschritte (`PrerequisitesModel.missingSetupSteps`).
    var missingSetupSteps: Set<SetupStep> = []
    /// Während eines Scans ist „Erneut prüfen“ gesperrt.
    var isScanning = false
    var perform: @MainActor (CoverageNextStep) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var coverageSteps: CoverageStepHandler?
}

/// Scan-Abdeckung eines Inventarbereichs (#142) – derselbe Baustein über jeder Liste und in der Übersicht: Zustand mit
/// Symbol, Farbe und Text, Zeitpunkt, bei Lücken Umfang und Grund sowie der passende nächste Schritt (falls einer hilft).
/// Aktuelle Bereiche zeigen nur eine dezente Zeile, dazu ruhige Hinweise zu bewusst nicht gescannten Quellen. Die
/// Gestaltung teilt sie mit anderen Hinweisleisten (`NoticeBarLayout`).
struct AreaCoverageBar: View {
    let coverage: AreaCoverage
    /// Bereichsname voranstellen (Übersicht).
    var showsArea = false
    /// „Anzeigen“ – öffnet den Bereich (Übersicht); `nil`: keine Schaltfläche.
    var onShow: (() -> Void)?
    @Environment(\.coverageSteps) private var steps

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        NoticeBarLayout(
            systemImage: coverage.systemImage, tone: coverage.tone,
            headline: showsArea ? coverage.summaryLine(now: now) : coverage.statusLine(now: now),
            accessibilityLabel: coverage.accessibilityLabel(now: now), isEmphasized: !coverage.isComplete,
            reasons: coverage.isComplete ? [] : coverage.reasons(now: now),
            // Bewusst nicht gescannte Quellen und Zwischenmessungen: ruhiger Hinweis, ohne Einfluss auf den Zustand.
            notes: coverage.notes(now: now)
        ) {
            if !coverage.isComplete { actions }
        }
    }

    @ViewBuilder
    private var actions: some View {
        let step = steps.flatMap { coverage.nextStep(missingSetupSteps: $0.missingSetupSteps) }
        if step != nil || onShow != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons(step) }
                VStack(alignment: .leading, spacing: 4) { actionButtons(step) }
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func actionButtons(_ step: CoverageNextStep?) -> some View {
        if let step, let steps {
            Button(step.title) { steps.perform(step) }
                .disabled(step == .rescan && steps.isScanning)
                .accessibilityHint(Text(verbatim: step.hint))
        }
        if let onShow {
            Button("\(coverage.area.title) anzeigen") { onShow() }
        }
    }
}

/// Abdeckung über einer Liste, darunter eine Trennlinie; ohne Snapshot nichts (die Liste zeigt dann „Noch keine Daten“).
struct SectionCoverageHeader: View {
    let coverage: AreaCoverage?

    var body: some View {
        if let coverage {
            AreaCoverageBar(coverage: coverage)
            Divider()
        }
    }
}

/// Leerer Zustand einer Liste, der bei unvollständiger Abdeckung keine Entwarnung gibt (#142): Symbol des
/// Abdeckungszustands statt des Entwarnungssymbols und der Hinweis `AreaCoverage.emptyListCaveat`.
struct CoverageAwareUnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    var description: LocalizedStringKey?
    let coverage: AreaCoverage?

    var body: some View {
        if let coverage, let caveat = coverage.emptyListCaveat {
            ContentUnavailableView {
                Label(title, systemImage: coverage.systemImage)
            } description: {
                VStack(spacing: 6) {
                    if let description { Text(description) }
                    Text(verbatim: caveat)
                }
            }
        } else {
            ContentUnavailableView(title, systemImage: systemImage, description: description.map { Text($0) })
        }
    }
}

extension MainSection {
    /// Bereich des Hauptfensters zu einem Inventarbereich.
    init(_ area: InventoryArea) {
        self = switch area {
        case .apps: .apps
        case .permissions: .permissions
        case .autostart: .autostart
        case .agents: .agents
        case .network: .network
        case .security: .security
        }
    }
}

// MARK: - Vorschauen

/// Feste Abdeckungen für die Vorschauen: je Zustand ein Bereich.
private enum CoveragePreviewData {
    static let now = Date.now

    static let snapshot: Snapshot = {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.example.agent.plist"
        let outdated = AutostartItem(
            kind: .launchAgent, domain: .user, label: "com.example.agent", program: "/usr/local/bin/agent",
            programPresence: .present, isEnabled: true, isLoaded: true, plistPath: plistPath, owner: nil, source: .launchd,
            lastVerifiedAt: now - 86_400
        )
        return Snapshot(
            takenAt: now, grants: [], autostartItems: [outdated],
            sourceErrors: [
                SourceError(source: .btm, message: "Hintergrund-Items nicht lesbar: Helper nicht erreichbar"),
                SourceError(source: .networkListeners, message: "Zeitüberschreitung: keine Antwort nach 120 s"),
                SourceError(source: .tccUser, message: "nicht gescannt – zählt nicht"),
            ],
            sourceLimitations: [
                SourceLimitation(source: .launchd, message: "Plist \(plistPath) nicht auswertbar: keine Leserechte"),
                SourceLimitation(source: .agents, message: "Projekte auf Netzlaufwerk /Volumes/Team nicht gelesen"),
            ],
            baselineSources: [.tccUser, .tccSystem, .launchd, .btm, .apps, .agents, .securityPosture],
            lastDeliveryBySource: [.tccUser: now - 300, .tccSystem: now - 300, .launchd: now - 300, .btm: now - 86_400,
                                   .apps: now - 300, .agents: now - 300, .securityPosture: now - 300]
        )
    }()

    /// Wie in der App: ohne Benutzer-TCC (v1), daher bei den Berechtigungen der ruhige Hinweis.
    static let overview = CoverageOverview(
        snapshot: snapshot,
        activeSources: [.tccSystem, .launchd, .btm, .securityPosture, .apps, .agents, .networkListeners]
    )
    static func coverage(_ area: InventoryArea) -> AreaCoverage { overview[area]! }

    static let steps = CoverageStepHandler(missingSetupSteps: [.helper])
}

#Preview("Abdeckung je Zustand") {
    VStack(spacing: 0) {
        ForEach([InventoryArea.permissions, .agents, .autostart, .network], id: \.self) { area in
            AreaCoverageBar(coverage: CoveragePreviewData.coverage(area))
            Divider()
        }
    }
    .environment(\.coverageSteps, CoveragePreviewData.steps)
    .frame(width: 280)
}

#Preview("Übersicht") {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(CoveragePreviewData.overview.incomplete) { coverage in
            AreaCoverageBar(coverage: coverage, showsArea: true, onShow: {})
        }
    }
    .environment(\.coverageSteps, CoveragePreviewData.steps)
    .padding()
    .frame(width: 600)
}

#Preview("Leere Liste, nicht geprüft") {
    CoverageAwareUnavailableView(title: "Keine Netzwerkdienste", systemImage: MainSection.network.systemImage,
                                 description: "Kein Programm nimmt Verbindungen an (Systemdienste ausgeblendet).",
                                 coverage: CoveragePreviewData.coverage(.network))
        .frame(width: 300, height: 300)
}
