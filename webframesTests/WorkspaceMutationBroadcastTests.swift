import Testing
import Foundation
@testable import Web_Frames

@Suite("Workspace mutation broadcast") @MainActor struct WorkspaceMutationBroadcastTests {
    @Test func observersSeeTheMutationOnlyWhileItIsBroadcast() {
        let store = WorkspaceStore()
        var seen: [String] = []
        let subscription = store.observe {
            switch store.mutationInFlight {
            case .none: seen.append("none")
            case .viewportChanged: seen.append("viewport")
            default: seen.append("other")
            }
        }
        defer { withExtendedLifetime(subscription) {} }
        // The synchronous registration call carries no mutation.
        #expect(seen == ["none"])
        store.setViewport(ViewportModel(scale: 2, panX: 0, panY: 0))
        #expect(seen == ["none", "viewport"])
        var cleared = false
        if case .none = store.mutationInFlight { cleared = true }
        #expect(cleared)
        store.setViewport(ViewportModel(scale: 2, panX: 0, panY: 0))   // no-op: unchanged
        #expect(seen == ["none", "viewport"])
    }

    @Test func viewportChangeUpdatesOnlyTheCanvasSlotOfThePayload() throws {
        let document = makeTestDocument()
        let store = document.workspace
        let before = document.payload
        store.setViewport(ViewportModel(scale: 0.5, panX: 12, panY: -7))
        let after = document.payload
        #expect(after.canvas == ViewportModel(scale: 0.5, panX: 12, panY: -7).jsonValue)
        #expect(after.frames == before.frames)
        #expect(after.annotations == before.annotations)
        #expect(after.links == before.links)
        #expect(after.name == before.name)
        // A round-trip through the store must agree with the incremental update.
        #expect(store.serialize().canvas == after.canvas)
    }
}
