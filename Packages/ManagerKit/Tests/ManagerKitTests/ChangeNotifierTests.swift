import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1)))
struct ChangeNotifierTests {
    private let fake = RecordingNotifier()
    private let clock = TestClock()

    private func makeNotifier() -> ChangeNotifier {
        ChangeNotifier(notifier: fake, clock: clock)
    }

    private func events(_ count: Int) -> [HistoryEvent] {
        (0..<count).map { index in
            let item = TestData.item("com.example.agent\(index)")
            return HistoryEvent(
                id: UUID(), event: ChangeEvent(kind: .added, before: nil, after: .autostartItem(item), detectedAt: TestData.date),
                isRead: false
            )
        }
    }

    private func expectedPost(for event: HistoryEvent) -> RecordingNotifier.Post {
        let description = ChangeDescription(event.event)
        return .init(title: description.title, body: description.body, identifier: event.id.uuidString, destination: .history)
    }

    /// Stellt die Uhr auf den absoluten Zeitpunkt `seconds`.
    private func advance(to seconds: Int) {
        clock.advance(by: clock.now.duration(to: .at(.seconds(seconds))))
    }

    private func nextPosts(_ count: Int) async -> [RecordingNotifier.Post] {
        var iterator = fake.posts.makeAsyncIterator()
        var result: [RecordingNotifier.Post] = []
        for _ in 0..<count {
            guard let post = await iterator.next() else { break }
            result.append(post)
        }
        return result
    }

    @Test func upToThreeEventsArePostedIndividuallyAfterTheWindow() async {
        let notifier = makeNotifier()
        let batch = events(3)
        await notifier.notify(batch)
        await clock.waitForSleeper(until: .at(.seconds(10)))
        #expect(fake.all.isEmpty)

        advance(to: 10)
        #expect(await nextPosts(3) == batch.map(expectedPost(for:)))
        await notifier.flushNow()
        #expect(fake.all.count == 3)
    }

    @Test func singleSecurityEventLeadsToItsCheck() async {
        let notifier = makeNotifier()
        let event = TestData.historyEvent(.modified, .securityCheck(TestData.securityCheck(TestData.firewallOff, state: .critical)))
        await notifier.notify([event])
        await clock.waitForSleeper(until: .at(.seconds(10)))
        advance(to: 10)

        #expect(await nextPosts(1).map(\.destination) == [.securityCheck(.firewall)])
    }

    @Test func summaryOfSecurityEventsLeadsToHistory() async {
        let notifier = makeNotifier()
        let events = SecurityCheckKind.allCases.prefix(4).map { kind in
            TestData.historyEvent(.modified, .securityCheck(SecurityCheck(kind: kind, state: .critical, facts: nil)))
        }
        await notifier.notify(events)
        await clock.waitForSleeper(until: .at(.seconds(10)))
        advance(to: 10)

        let posts = await nextPosts(1)
        #expect(posts.map(\.title) == ["4 Änderungen"])
        #expect(posts.map(\.destination) == [.history])
    }

    @Test func moreThanThreeEventsAreBundledIntoOneSummary() async {
        let notifier = makeNotifier()
        let batch = events(5)
        await notifier.notify(batch)
        await clock.waitForSleeper(until: .at(.seconds(10)))
        advance(to: 10)

        let posts = await nextPosts(1)
        let summary = ChangeDescription.summary(for: batch.map(\.event))
        #expect(posts.map(\.title) == ["5 Änderungen"])
        #expect(posts.first?.body == summary.body)
        await notifier.flushNow()
        #expect(fake.all.count == 1)
    }

    @Test func eventsDuringAPendingWindowJoinIt() async {
        let notifier = makeNotifier()
        await notifier.notify(events(2))
        await clock.waitForSleeper(until: .at(.seconds(10)))
        advance(to: 5)
        await notifier.notify(events(2))
        advance(to: 10)

        #expect(await nextPosts(1).map(\.title) == ["4 Änderungen"])
    }

    @Test func separateWindowsAreReportedSeparately() async {
        let notifier = makeNotifier()
        let first = events(1)
        await notifier.notify(first)
        await clock.waitForSleeper(until: .at(.seconds(10)))
        advance(to: 10)
        #expect(await nextPosts(1) == first.map(expectedPost(for:)))

        advance(to: 15)
        await notifier.notify(events(4))
        await clock.waitForSleeper(until: .at(.seconds(25)))
        advance(to: 24)
        #expect(fake.all.count == 1)
        advance(to: 25)
        #expect(await nextPosts(1).map(\.title) == ["4 Änderungen"])
    }

    @Test func emptyEventListStartsNoWindow() async {
        let notifier = makeNotifier()
        await notifier.notify([])
        await notifier.flushNow()
        #expect(fake.all.isEmpty)
    }

    @Test func flushNowPostsImmediatelyAndCancelsTheWindow() async {
        let notifier = makeNotifier()
        let batch = events(2)
        await notifier.notify(batch)
        await notifier.flushNow()
        #expect(fake.all == batch.map(expectedPost(for:)))

        // Die abgebrochene Frist meldet nichts mehr; das nächste Fenster beginnt neu.
        advance(to: 10)
        let later = events(1)
        await notifier.notify(later)
        await clock.waitForSleeper(until: .at(.seconds(20)))
        advance(to: 20)
        _ = await nextPosts(3)
        #expect(fake.all == (batch + later).map(expectedPost(for:)))
    }
}

@Suite("UNUserNotificationCenterNotifier")
struct UNUserNotificationCenterNotifierTests {
    @Test func contentIsGroupedUnderChangesCategoryAndThread() {
        let content = UNUserNotificationCenterNotifier.content(
            title: "Neue Berechtigung", body: "Zoom darf jetzt Kamera.", destination: .history
        )
        #expect(content.title == "Neue Berechtigung")
        #expect(content.body == "Zoom darf jetzt Kamera.")
        #expect(content.categoryIdentifier == "changes")
        #expect(content.threadIdentifier == "de.cstrube.Grantry.changes")
    }

    @Test func contentCarriesTheDestinationForTheClick() {
        let content = UNUserNotificationCenterNotifier.content(title: "t", body: "b", destination: .securityCheck(.firewall))
        #expect(NotificationDestination(userInfo: content.userInfo) == .securityCheck(.firewall))
    }
}
