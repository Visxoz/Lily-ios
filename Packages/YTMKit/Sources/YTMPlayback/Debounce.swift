import Foundation

/// Each `schedule` replaces the last, so a burst of changes costs one write.
@MainActor final class Debounce {
    private static let persistAfter = Duration.seconds(2)

    private var pending: Task<Void, Never>?

    var isPending: Bool { pending != nil }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.persistAfter)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
