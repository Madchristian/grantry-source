#if DEBUG
import Testing
@testable import ManagerKit

/// Fake-Quelle des Render-Wächters (#372): eine feste Folge von Messtakten, in der sich Werte und die Rangfolge der
/// Prozesse nach CPU ändern – sonst gäbe es nichts neu zu zeichnen und nichts umzusortieren.
@Suite struct TaskManagerPreviewDataTests {
    @Test func framesFollowTheStillFrame() {
        let frames = TaskManagerPreviewData.frames(count: 3)
        #expect(frames.count == 3)
        #expect(frames[0].history == TaskManagerPreviewData.frame.history)
        #expect(frames[1].history != frames[0].history)
        #expect(frames.allSatisfy { $0.snapshot.thermal == .nominal })
    }

    @Test func framesAreReproducible() {
        #expect(TaskManagerPreviewData.frames(count: 4) == TaskManagerPreviewData.frames(count: 4))
    }

    @Test func processesChangeTheirRankingByCPU() {
        let frames = TaskManagerPreviewData.frames(count: 10, processes: true)
        let rankings = frames.map { frame in
            frame.snapshot.processes.sorted { ($0.cpuLoad ?? 0) > ($1.cpuLoad ?? 0) }.map(\.key)
        }
        #expect(frames.allSatisfy { $0.snapshot.processes.count >= 8 })
        #expect(zip(rankings, rankings.dropFirst()).filter { $0 != $1 }.count >= 5)
    }

    @Test func stillFrameHasNoProcesses() {
        #expect(TaskManagerPreviewData.frame.snapshot.processes.isEmpty)
    }
}
#endif
