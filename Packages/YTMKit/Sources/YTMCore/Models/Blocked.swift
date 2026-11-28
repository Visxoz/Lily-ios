/// Artists named on a list, by a hash of each name folded to lower case, sorted: about 90 KB for 11,000 names, far
/// less than a set of strings. Two names sharing a 64-bit hash is a risk accepted.
public struct ListedArtists: Sendable {
    private let keys: [Int]

    public init(_ names: some Sequence<Substring>) {
        keys = Set(names.lazy.map(Self.key)).sorted()
    }

    public var count: Int { keys.count }

    public func has(_ name: String) -> Bool {
        let key = Self.key(Substring(name))
        var (low, high) = (0, keys.count)
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low < keys.count && keys[low] == key
    }

    /// Hashed as it folds, so checking an ASCII name allocates nothing. Never saved, as `Hasher` is seeded per launch.
    private static func key(_ name: Substring) -> Int {
        var hasher = Hasher()
        for scalar in name.unicodeScalars {
            if scalar.isASCII {
                let value = scalar.value
                hasher.combine((65...90).contains(value) ? value + 32 : value)
            } else {
                // As UInt32 too, so a capital that folds to ASCII, as the Kelvin sign does, keys as its letter.
                for lower in scalar.properties.lowercaseMapping.unicodeScalars { hasher.combine(lower.value) }
            }
        }
        return hasher.finalize()
    }
}

/// What leaves songs out of queues, radios and shuffles: the user's own blocked artists, by ID or name, and the
/// artists a list names, by name alone.
public struct Blocked: Sendable {
    public let artists: [ArtistRef]
    public let listed: ListedArtists?

    public init(artists: [ArtistRef] = [], listed: ListedArtists? = nil) {
        self.artists = artists
        self.listed = listed
    }

    public var isEmpty: Bool { artists.isEmpty && listed == nil }

    /// Cheap when nothing is blocked.
    public func has(_ track: Track) -> Bool {
        if track.isBy(anyOf: artists) { return true }
        guard let listed else { return false }
        return track.artists.contains { listed.has($0.name) }
    }
}
