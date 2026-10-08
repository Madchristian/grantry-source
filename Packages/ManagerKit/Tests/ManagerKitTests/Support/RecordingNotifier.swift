import Synchronization
@testable import ManagerKit

/// Zeichnet Meldungen auf, statt sie zuzustellen; `posts` liefert sie zusätzlich als Strom zum Abwarten.
final class RecordingNotifier: UserNotifying {
    struct Post: Equatable {
        let title: String
        let body: String
        let identifier: String
        let destination: NotificationDestination
    }

    private let recorded = Mutex<[Post]>([])
    private let continuation: AsyncStream<Post>.Continuation
    let posts: AsyncStream<Post>

    init() { (posts, continuation) = AsyncStream<Post>.makeStream() }

    var all: [Post] { recorded.withLock { $0 } }

    func requestAuthorization() async -> Bool { true }

    func post(title: String, body: String, identifier: String, destination: NotificationDestination) async {
        let post = Post(title: title, body: body, identifier: identifier, destination: destination)
        recorded.withLock { $0.append(post) }
        continuation.yield(post)
    }
}
