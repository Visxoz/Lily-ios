import Foundation

/// Runs an action once things settle: each `schedule` replaces the last, so
/// a burst of changes costs one write, as ytm-native's `persist_soon`.
@MainActor final class Debounce {
    /// How long after the last change saves are written, as ytm-native's
    /// `PERSIST_AFTER`. Skipping through songs then costs one write.
    private static let persistAfter = Duration.seconds(2)

    private var pending: Task<Void, Never>?

    /// An action is waiting to run.
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
