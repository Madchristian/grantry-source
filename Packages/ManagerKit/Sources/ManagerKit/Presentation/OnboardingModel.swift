import Foundation
import Observation

/// Wann das Onboarding erscheint (Spec §6): beim ersten Start und, solange ein erforderlicher Schritt behebbar fehlt,
/// bei jedem Start – je Start höchstens einmal von selbst; sonst über das Banner der Übersicht oder die Menüleiste.
@MainActor
@Observable
public final class OnboardingModel {
    /// Das Onboarding-Blatt ist sichtbar.
    public var isPresented = false
    /// „Fertig“ wurde einmal gewählt (dauerhaft in `UserDefaults`).
    public private(set) var hasCompleted: Bool

    private let defaults: any SettingsStore
    /// Nach „Fertig“, z. B. ein Scan als Baseline mit allen jetzt verfügbaren Quellen.
    private let onFinish: @MainActor () -> Void
    /// Zeigt das Onboarding bei jedem Start von selbst (nur Entwicklung, für Bildschirmprüfungen).
    private let forcesPresentation: Bool
    /// `true`, solange über die Update-Prüfung nicht entschieden ist; dann erscheint das Onboarding (einmal je Start)
    /// auch nach erledigter Einrichtung.
    private let needsUpdateDecision: @MainActor () -> Bool
    private var hasPresentedAutomatically = false

    nonisolated public static let completedKey = "onboardingCompleted"

    public init(
        defaults: any SettingsStore = UserDefaults.standard,
        forcesPresentation: Bool = false,
        needsUpdateDecision: @escaping @MainActor () -> Bool = { false },
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.forcesPresentation = forcesPresentation
        self.needsUpdateDecision = needsUpdateDecision
        self.onFinish = onFinish
        hasCompleted = defaults.bool(forKey: Self.completedKey)
    }

    /// Zeigt das Onboarding, wenn `checklist` es verlangt oder über Updates nicht entschieden ist und es in diesem Start noch nicht von selbst erschien.
    public func presentIfNeeded(_ checklist: SetupChecklist) {
        guard !hasPresentedAutomatically,
              forcesPresentation || checklist.shouldPresentAutomatically(hasCompletedOnboarding: hasCompleted)
                || needsUpdateDecision()
        else { return }
        hasPresentedAutomatically = true
        isPresented = true
    }

    public func present() {
        isPresented = true
    }

    /// Schließt das Onboarding, ohne es als erledigt zu vermerken; es erscheint beim nächsten Start wieder.
    public func postpone() {
        isPresented = false
    }

    /// Schließt das Onboarding und vermerkt es als erledigt; fehlende Schritte meldet danach das Banner.
    public func finish() {
        defaults.set(true, forKey: Self.completedKey)
        hasCompleted = true
        isPresented = false
        onFinish()
    }
}
