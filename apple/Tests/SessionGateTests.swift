import Testing
@testable import Xenia

@Suite("Session gate")
struct SessionGateTests {
    @Test("A cancelled wait ends without the session opening", .timeLimit(.minutes(1)))
    func cancelledWait() async {
        let gate = SessionGate()
        let waiting = Task { await gate.wait() }
        await Task.yield()
        waiting.cancel()
        await waiting.value
        #expect(!gate.isOpen)
    }

    @Test("Waits end when the session opens", .timeLimit(.minutes(1)))
    func opening() async {
        let gate = SessionGate()
        let waiting = Task { await gate.wait() }
        await Task.yield()
        gate.open()
        await waiting.value
        #expect(gate.isOpen)
    }
}
