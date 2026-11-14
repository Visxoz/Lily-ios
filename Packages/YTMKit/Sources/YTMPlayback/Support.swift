import Foundation
import os
import YTMCore

// Small helpers the player's files share.

extension Logger {
    /// What the player did, for Console; never cookies or stream URLs.
    static let playback = Logger(subsystem: "YTMusic", category: "Playback")
    /// The Premium path's decisions, beside YTMCore's own.
    static let premium = Logger(subsystem: "YTMusic", category: "Premium")
}

extension Result where Failure == any Error {
    /// The outcome of `body`, as `init(catching:)` for async work.
    init(_ body: @Sendable () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
