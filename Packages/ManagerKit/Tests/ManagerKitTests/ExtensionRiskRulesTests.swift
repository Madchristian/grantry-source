import Foundation
import Testing
@testable import ManagerKit

/// Sicherheitsbewertung der Erweiterungen (Spec 2026-11-08 § 5.2, #390): je Regel Befund, Schweregrad und Grenzen.
struct ExtensionRiskRulesTests {
    // MARK: Kernel-Erweiterungen

    @Test func loadedThirdPartyKernelExtensionIsAFinding() {
        let kext = Self.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let findings = KernelExtensionRule().evaluate(Self.snapshot(kext))
        #expect(findings.map(\.rule) == [.kernelExtension])
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.first?.recordID == kext.id)
        #expect(findings.first?.message == "Tool läuft im Kern – auf Apple Silicon nur mit reduzierter Sicherheit")
    }

    @Test(arguments: [(SigningInfo.Kind.unsigned, "nicht signiert"), (.adHoc, "nur ad hoc signiert")])
    func unsignedOrAdHocKernelExtensionIsCritical(_ kind: SigningInfo.Kind, _ statement: String) {
        let kext = Self.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: kind))
        let findings = KernelExtensionRule().evaluate(Self.snapshot(kext))
        #expect(findings.map(\.severity) == [.high])
        #expect(findings.first?.message == "Tool läuft im Kern und ist \(statement)")
    }

    /// Ohne Pfad (Rückfall `kmutil`) oder nach abgelaufener Prüfung bleibt es beim Befund ohne „kritisch“.
    @Test func kernelExtensionWithoutConclusiveSigningStaysAFinding() {
        let withoutPath = Self.record(.kernelExtension, state: .loaded, signing: nil)
        let timedOut = Self.record(.kernelExtension, bundleID: "com.example.other", state: .loaded, signing: .unknown,
                                   isSigningConclusive: false)
        let findings = KernelExtensionRule().evaluate(Self.snapshot(withoutPath, timedOut))
        #expect(findings.map(\.severity) == [.medium, .medium])
    }

    @Test func installedButNotLoadedKernelExtensionIsNoKernelFinding() {
        let kext = Self.record(.kernelExtension, state: .notLoaded, signing: SigningInfo(kind: .unsigned))
        #expect(KernelExtensionRule().evaluate(Self.snapshot(kext)).isEmpty)
    }

    // MARK: Endpoint Security und Netzwerk

    @Test(arguments: [
        (ExtensionKind.endpointSecurity, "Tool (Endpoint Security) sieht alle Prozesse und Dateizugriffe"),
        (.network, "Tool (Netzwerkerweiterung) kann den Netzwerkverkehr sehen"),
    ])
    func privilegedExtensionWithAppIsANote(_ kind: ExtensionKind, _ message: String) {
        let record = Self.record(kind, owner: .app(path: "/Applications/Tool.app", evidence: .bundleID))
        let findings = PrivilegedExtensionRule().evaluate(Self.snapshot(record))
        #expect(findings.map(\.rule) == [.privilegedExtension])
        #expect(findings.map(\.severity) == [.low])
        #expect(findings.first?.message == message)
    }

    @Test func privilegedExtensionWithoutAppIsAFinding() {
        let record = Self.record(.endpointSecurity, owner: .missing)
        let findings = PrivilegedExtensionRule().evaluate(Self.snapshot(record))
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.first?.message == "Tool (Endpoint Security) sieht alle Prozesse und Dateizugriffe – die zugehörige App fehlt")
    }

    /// Ohne Team-ID lässt sich nicht prüfen, wer die Erweiterung signiert hat (etwa im Entwicklermodus).
    @Test func privilegedExtensionWithoutTeamIsAFinding() {
        let record = Self.record(.network, teamID: nil, owner: .unclear(candidates: []))
        let findings = PrivilegedExtensionRule().evaluate(Self.snapshot(record))
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.first?.message == "Tool (Netzwerkerweiterung) kann den Netzwerkverkehr sehen – Signatur nicht prüfbar")
    }

    /// Unklare Zuordnung (mehrere Apps, Inventar unvollständig) belegt kein Fehlen.
    @Test func unclearOwnerStaysANote() {
        let record = Self.record(.network, owner: .unclear(candidates: ["/Applications/A.app", "/Applications/B.app"]))
        #expect(PrivilegedExtensionRule().evaluate(Self.snapshot(record)).map(\.severity) == [.low])
    }

    @Test(arguments: [ExtensionKind.driver, .camera, .otherSystemExtension("com.apple.system_extension.new")])
    func otherSystemExtensionsAreNotPrivilegedFindings(_ kind: ExtensionKind) {
        let record = Self.record(kind, owner: .missing)
        #expect(PrivilegedExtensionRule().evaluate(Self.snapshot(record)).isEmpty)
    }

    // MARK: Rest ohne App

    @Test(arguments: [ExtensionKind.kernelExtension, .driver, .camera, .audioPlugin, .videoPlugin])
    func extensionWithoutAppIsALeftover(_ kind: ExtensionKind) {
        let record = Self.record(kind, state: Self.defaultState(kind), owner: .missing)
        let findings = ExtensionLeftoverRule().evaluate(Self.snapshot(record))
        #expect(findings.map(\.rule) == [.extensionLeftover])
        #expect(findings.map(\.severity) == [.low])
        #expect(findings.first?.message == "Tool (\(kind.displayName)) gehört zu keiner installierten App mehr – ein Rest")
    }

    /// Endpoint Security und Netzwerk melden die fehlende App bereits als Befund (kein Doppelalarm).
    @Test(arguments: [ExtensionKind.endpointSecurity, .network])
    func privilegedLeftoverIsReportedOnlyOnce(_ kind: ExtensionKind) {
        let record = Self.record(kind, owner: .missing)
        #expect(ExtensionLeftoverRule().evaluate(Self.snapshot(record)).isEmpty)
        #expect(RiskEvaluator.standard.evaluate(Self.snapshot(record)).map(\.rule) == [.privilegedExtension])
    }

    @Test func unclearOrUnassignedOwnerIsNoLeftover() {
        let unclear = Self.record(.driver, owner: .unclear(candidates: []))
        let unassigned = Self.record(.camera, bundleID: "com.example.camera", owner: nil)
        #expect(ExtensionLeftoverRule().evaluate(Self.snapshot(unclear, unassigned)).isEmpty)
    }

    // MARK: Plug-ins

    @Test(arguments: [(SigningInfo.Kind.unsigned, "nicht signiert"), (.adHoc, "nur ad hoc signiert")])
    func pluginWithoutValidSignatureIsAFinding(_ kind: SigningInfo.Kind, _ statement: String) {
        let plugin = Self.record(.audioPlugin, state: .installed, signing: SigningInfo(kind: kind))
        let findings = ServicePluginSignatureRule().evaluate(Self.snapshot(plugin))
        #expect(findings.map(\.rule) == [.pluginSignature])
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.first?.message == "Tool (Audio-Plug-in) ist \(statement)")
    }

    /// Kein Beleg, kein Befund: unbekannte oder nicht rechtzeitig geprüfte Signatur, reguläre Signatur.
    @Test func pluginWithRegularOrUnknownSignatureIsNoFinding() {
        let signed = Self.record(.audioPlugin, state: .installed, signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let unknown = Self.record(.audioPlugin, bundleID: "com.example.unknown", state: .installed, signing: .unknown)
        let timedOut = Self.record(.videoPlugin, bundleID: "com.example.late", state: .installed, signing: .unknown,
                                   isSigningConclusive: false)
        #expect(ServicePluginSignatureRule().evaluate(Self.snapshot(signed, unknown, timedOut)).isEmpty)
    }

    @Test func videoPluginIsADeprecationNote() {
        let video = Self.record(.videoPlugin, state: .installed, signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let audio = Self.record(.audioPlugin, bundleID: "com.example.audio", state: .installed,
                                signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let findings = DeprecatedPluginRule().evaluate(Self.snapshot(video, audio))
        #expect(findings.map(\.rule) == [.deprecatedPlugin])
        #expect(findings.map(\.recordID) == [video.id])
        #expect(findings.map(\.severity) == [.low])
        #expect(findings.first?.message == "Tool ist ein Video-Plug-in in veralteter Technik (DAL)")
    }

    // MARK: Gemeinsam

    /// Wird beim Neustart entfernt: schon deinstalliert, keine Bewertung mehr.
    @Test func extensionsAwaitingRemovalAreNotAssessed() {
        let records = [
            Self.record(.endpointSecurity, owner: .missing, state: .removalPending),
            Self.record(.driver, bundleID: "com.example.driver", owner: .missing, state: .removalPending),
        ]
        #expect(RiskEvaluator.standard.evaluate(Self.snapshot(records)).isEmpty)
    }

    /// Plug-ins von Apple (etwa ein mitgeliefertes Audio-Plug-in) sind kein fremder Code.
    @Test func appleSignedPluginsAreNotAssessed() {
        let video = Self.record(.videoPlugin, state: .installed, signing: SigningInfo(kind: .apple), owner: .missing)
        #expect(RiskEvaluator.standard.evaluate(Self.snapshot(video)).isEmpty)
    }

    @Test func standardEvaluatorAppliesAllExtensionRules() {
        let kext = Self.record(.kernelExtension, bundleID: "com.example.kext", state: .loaded,
                               signing: SigningInfo(kind: .unsigned), owner: .missing)
        let plugin = Self.record(.videoPlugin, bundleID: "com.example.dal", state: .installed,
                                 signing: SigningInfo(kind: .adHoc))
        let rules = Set(RiskEvaluator.standard.evaluate(Self.snapshot(kext, plugin)).map(\.rule))
        #expect(rules == [.kernelExtension, .extensionLeftover, .pluginSignature, .deprecatedPlugin])
    }

    /// Fremde Namen kommen einzeilig und gekürzt in die Meldung; ohne Namen steht die Bundle-ID.
    @Test func messagesUseSanitizedNameOrBundleID() {
        let longName = String(repeating: "X", count: 500)
        let named = Self.record(.videoPlugin, name: "Evil\nName " + longName, state: .installed)
        let unnamed = Self.record(.videoPlugin, bundleID: "com.example.unnamed", name: nil, state: .installed)
        let messages = DeprecatedPluginRule().evaluate(Self.snapshot(named, unnamed)).map(\.message)
        #expect(messages.allSatisfy { !$0.contains("\n") })
        #expect(messages.allSatisfy { $0.count < 200 })
        #expect(messages.contains("com.example.unnamed ist ein Video-Plug-in in veralteter Technik (DAL)"))
    }

    // MARK: Hilfen

    static func defaultState(_ kind: ExtensionKind) -> ExtensionState {
        switch kind.group {
        case .kernelExtensions: .loaded
        case .systemExtensions: .enabled
        case .servicePlugins: .installed
        }
    }

    static func record(
        _ kind: ExtensionKind, bundleID: String = "com.example.tool", teamID: String? = "TEAM1", name: String? = "Tool",
        state: ExtensionState? = nil, signing: SigningInfo? = nil, isSigningConclusive: Bool = true,
        owner: ExtensionOwnership? = .app(path: "/Applications/Tool.app", evidence: .teamID)
    ) -> ExtensionRecord {
        let path: String? = switch kind.group {
        case .systemExtensions: nil
        case .kernelExtensions: signing == nil ? nil : "/Library/Extensions/\(bundleID).kext"
        case .servicePlugins: "/Library/Audio/Plug-Ins/HAL/\(bundleID).driver"
        }
        return ExtensionRecord(
            kind: kind, bundleID: bundleID, teamID: kind.group == .systemExtensions ? teamID : signing?.teamID,
            name: name, version: "1.0", buildVersion: nil, state: state ?? defaultState(kind), signing: signing,
            isSigningConclusive: isSigningConclusive, path: path, owner: owner,
            firstSeenAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    static func record(_ kind: ExtensionKind, bundleID: String = "com.example.tool", owner: ExtensionOwnership?,
                       state: ExtensionState) -> ExtensionRecord {
        record(kind, bundleID: bundleID, state: state, owner: owner)
    }

    static func snapshot(_ records: ExtensionRecord...) -> Snapshot { snapshot(records) }

    static func snapshot(_ records: [ExtensionRecord]) -> Snapshot {
        Snapshot(takenAt: Date(timeIntervalSince1970: 1_800_000_000), grants: [], autostartItems: [], extensions: records,
                 sourceErrors: [])
    }
}
