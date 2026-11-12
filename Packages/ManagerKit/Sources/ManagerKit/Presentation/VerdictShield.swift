import Foundation

/// Schildform eines Urteils in Lage- und Zustandszeilen (Spec 2026-11-10 § 11.3 c): ruhig (Häkchen), Befund
/// (Ausrufezeichen mit Bernstein-Punkt) oder offen (ohne Zeichen) für Zustände ohne Urteil – noch nicht geprüft,
/// unvollständig geprüft, nicht lesbar, noch nicht gesucht –, damit nichts wie eine Entwarnung wirkt.
public enum VerdictShield: Hashable, Sendable {
    case calm, finding, open
}
