import Foundation

/// The little of Apple's HLS playlists a moving cover needs: a master's variants, and the one file each variant's
/// segments are byte ranges of, which is the whole clip.
enum HLSPlaylist {
    /// Sharp enough for the lock screen's cover, small enough for about 8 MB a clip.
    static let bandwidthCap = 3_000_000

    struct Variant {
        let uri: String
        let bandwidth: Int
        let pixels: Int
        let hevc: Bool

        /// Most pixels, then HEVC, which looks better at the same rate, then the smaller file.
        var rank: (Int, Int, Int) { (pixels, hevc ? 1 : 0, -bandwidth) }
    }

    /// The variant to download, resolved against the master's URL: the best under the cap, or failing any, the
    /// smallest.
    static func variant(inMaster text: String, at url: URL) -> URL? {
        let all = variants(in: text)
        let under = all.filter { $0.bandwidth <= bandwidthCap }
        let pick = under.isEmpty
            ? all.min { $0.bandwidth < $1.bandwidth }
            : under.max { $0.rank < $1.rank }
        return pick.flatMap { URL(string: $0.uri, relativeTo: url)?.absoluteURL }
    }

    static func variants(in text: String) -> [Variant] {
        var variants: [Variant] = []
        var pending: [Substring: Substring]?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if !line.hasPrefix("#"), let stream = pending {
                pending = nil
                // Narrow types, so a hostile playlist's numbers can't overflow the product or the rank's negation.
                guard let bandwidth = stream["BANDWIDTH"].flatMap({ UInt32($0) }) else { continue }
                let size = stream["RESOLUTION"]?.split(separator: "x").compactMap { UInt16($0) } ?? []
                variants.append(Variant(
                    uri: String(line), bandwidth: Int(bandwidth), pixels: size.count == 2 ? Int(size[0]) * Int(size[1]) : 0,
                    hevc: stream["CODECS"]?.hasPrefix("hvc1") ?? false
                ))
            }
        }
        return variants
    }

    /// The file the map and every segment name, resolved against the variant's URL; nil when they name several,
    /// as only one file is downloaded.
    static func mediaFile(inVariant text: String, at url: URL) -> URL? {
        var files = Set<Substring>()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = attributes(line.dropFirst("#EXT-X-MAP:".count))["URI"] else { return nil }
                files.insert(uri)
            } else if !line.hasPrefix("#") {
                files.insert(line)
            }
        }
        guard files.count == 1, let file = files.first else { return nil }
        return URL(string: String(file), relativeTo: url)?.absoluteURL
    }

    /// `KEY=value,KEY="quoted, value"`, split only at commas outside quotes, the quotes dropped.
    static func attributes(_ list: Substring) -> [Substring: Substring] {
        var quoted = false
        let pairs = list.split { character in
            if character == "\"" { quoted.toggle() }
            return character == "," && !quoted
        }
        var found: [Substring: Substring] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let value = pair[pair.index(after: equals)...]
            let wrapped = value.count >= 2 && value.first == "\"" && value.last == "\""
            found[pair[..<equals]] = wrapped ? value.dropFirst().dropLast() : value
        }
        return found
    }
}
