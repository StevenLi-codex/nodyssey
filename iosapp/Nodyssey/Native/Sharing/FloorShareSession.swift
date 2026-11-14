import Foundation
import Combine

@MainActor final class FloorShareSession: ObservableObject {
    @Published private(set) var document: FloorShareDocument?
    @Published private(set) var failure: FloorShareError?
    private var artifact: FloorShareArtifact?
    private var generation: Int?

    func prepare(_ document: FloorShareDocument, dark: Bool, generation: Int, root: URL = FileManager.default.temporaryDirectory) {
        clear()
        guard artifact == nil else { return }
        do {
            let rendered = try FloorShareRenderer.render(document, dark: dark)
            artifact = try FloorShareArtifact(png: rendered.png, root: root)
            self.document = rendered.document
            self.generation = generation
            failure = nil
        } catch {
            self.document = nil
            self.generation = nil
            failure = .renderFailed
        }
    }

    func shareURL(generation: Int) -> URL? {
        guard self.generation == generation else { clear(); return nil }
        return artifact?.url
    }

    /// Completion is not interpreted as proof of an external post. A dismissal is not an error.
    func finish(activityFailed: Bool) {
        clear()
        if activityFailed { failure = .renderFailed }
    }

    func clear() {
        document = nil
        generation = nil
        failure = nil
        do { try artifact?.remove(); artifact = nil }
        catch { failure = .renderFailed } // Retain the lease for cleanup retry/deinit.
    }
}
