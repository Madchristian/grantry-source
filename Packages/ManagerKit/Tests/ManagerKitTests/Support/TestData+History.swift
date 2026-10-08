import Foundation
@testable import ManagerKit

extension TestData {
    /// Gespeichertes Event zu `subject`; bei `.removed` ist `subject` der letzte bekannte Zustand.
    static func historyEvent(
        _ kind: ChangeEvent.Kind, _ subject: ChangeSubject, at date: Date = date, isRead: Bool = false
    ) -> HistoryEvent {
        let event = ChangeEvent(
            kind: kind, before: kind == .added ? nil : subject, after: kind == .removed ? nil : subject, detectedAt: date
        )
        return HistoryEvent(id: UUID(), event: event, isRead: isRead)
    }
}
