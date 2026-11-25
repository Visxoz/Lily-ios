extension ScrobbleService {
    /// Plays a service has yet to accept, oldest first, kept on disk.
    struct Pending: Codable, Sendable {
        /// Last.fm's most per request; ListenBrainz takes more.
        static let batchSize = 50
        /// A fortnight of heavy listening, as Last.fm refuses older plays.
        static let limit = 3000

        private(set) var plays: [Play] = []
        /// The account the plays were heard under, so they never go to another that connects after its access was
        /// revoked.
        private(set) var account: String?

        var isEmpty: Bool { plays.isEmpty }

        mutating func push(_ play: Play) {
            if plays.count >= Self.limit { plays.removeFirst(plays.count - Self.limit + 1) }
            plays.append(play)
        }

        mutating func clear() {
            plays.removeAll()
        }

        /// Drops any plays heard under another account.
        mutating func hold(for account: String) {
            guard self.account != account else { return }
            if self.account != nil { clear() }
            self.account = account
        }

        func batch(one: Bool) -> [Play] {
            Array(plays.prefix(one ? 1 : Self.batchSize))
        }

        /// Drops `sent` from the front, less any the limit dropped while they were on their way.
        mutating func remove(_ sent: [Play]) {
            plays.removeFirst(plays.prefix(while: sent.contains).count)
        }
    }
}
