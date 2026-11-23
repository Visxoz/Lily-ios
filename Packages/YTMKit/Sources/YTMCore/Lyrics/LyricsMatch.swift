import Foundation

/// How another site's song and lyrics are known to be the ones YouTube is playing.
enum LyricsMatch {
    /// The title as a lyrics site files it: without credits or upload labels, but keeping a version such as
    /// "(Live)", lest another recording's lyrics be taken.
    static func title(_ title: String) -> String {
        var kept = "", credited = false
        scan(title[...]) { part, bracketed in
            if bracketed {
                if !(isCredit(part) || isPackaging(part)) { kept += part }
            } else if !credited {
                // A bare credit runs to the next bracket. The title's first word is a name, as in "Ft. Lauderdale".
                let words = part.split(whereSeparator: \.isWhitespace)
                let credit = words.dropFirst(kept.allSatisfy(\.isWhitespace) ? 1 : 0)
                    .firstIndex { bareCredits.contains($0.lowercased()) }
                kept += credit.map { part[..<words[$0].startIndex] } ?? part
                credited = credit != nil
            }
        }
        var name = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = name.last, last.isWhitespace || ",-–—".contains(last) { name.removeLast() }
        return name.isEmpty ? title : name
    }

    static func artist(_ track: Track) -> String? {
        guard let first = track.artists.first else { return nil }
        let name = withoutTopic(first.name)
        return name.isEmpty ? nil : name
    }

    /// The same name, the same version, a shared artist and within 3 s. Remasters count as the same, as their
    /// words and timing are.
    static func sameSong(_ track: Track, title: String, artist: String, duration: Double?) -> Bool {
        guard let length = track.duration, let duration, abs(Double(length) - duration) <= 3,
              parts(track.title) == parts(title)
        else { return false }
        let theirs = Set(credits(artist))
        return track.artists.contains { credits($0.name).contains(where: theirs.contains) }
    }

    /// Whether the candidate has mostly the reference's words in their order and, when both are timed, starts
    /// its lines with the reference's: a live take has the words but not the timing.
    static func agrees(_ reference: Lyrics, _ candidate: Lyrics) -> Bool {
        let ours = tokens(reference), theirs = tokens(candidate)
        guard !ours.isEmpty else { return false }
        let needed = 0.6 * Double(ours.count)
        // Counting the words in common bounds the match and spares diffing another song.
        var counts: [Substring: Int] = [:]
        for token in theirs { counts[token.text, default: 0] += 1 }
        var shared = 0
        for token in ours where counts[token.text, default: 0] > 0 {
            counts[token.text, default: 0] -= 1
            shared += 1
        }
        guard Double(shared) >= needed else { return false }
        let difference = theirs.difference(from: ours) { $0.text == $1.text }
        guard Double(ours.count - difference.removals.count) >= needed else { return false }
        var removed = [Bool](repeating: false, count: ours.count), inserted = [Bool](repeating: false, count: theirs.count)
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }
        // How much later the candidate starts each line that both start with the same word.
        var gaps: [Double] = []
        var i = 0, j = 0
        while i < ours.count, j < theirs.count {
            if removed[i] {
                i += 1
            } else if inserted[j] {
                j += 1
            } else {
                if let ourStart = ours[i].start, let theirStart = theirs[j].start { gaps.append(theirStart - ourStart) }
                i += 1; j += 1
            }
        }
        guard !gaps.isEmpty else { return true }
        gaps.sort()
        let middle = gaps.count / 2
        let median = gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
        return abs(median) <= 1.5
    }

    // MARK: - Titles

    private static let bareCredits: Set<String> = ["feat", "feat.", "ft", "ft.", "featuring"]
    private static let packaging: Set<Substring> = [
        "", "video", "audio", "lyric", "lyrics", "lyricvideo", "lyricsvideo", "visualiser", "visualizer", "mv", "hd", "hq",
        "4k", "fullsong",
    ]
    private static let versionWords: Set<Substring> = [
        "live", "remix", "mix", "acoustic", "sped", "slowed", "nightcore", "instrumental", "karaoke", "demo", "edit",
        "extended", "drumless", "reprise", "unplugged", "version", "cover", "orchestral", "rework",
    ]

    /// Calls `body` with each stretch outside brackets and each bracketed group, brackets included, in order.
    private static func scan(_ text: Substring, _ body: (Substring, _ bracketed: Bool) -> Void) {
        var rest = text
        while let open = rest.firstIndex(where: { $0 == "(" || $0 == "[" }),
              let close = rest[open...].dropFirst().firstIndex(where: { $0 == ")" || $0 == "]" }) {
            body(rest[..<open], false)
            body(rest[open...close], true)
            rest = rest[rest.index(after: close)...]
        }
        body(rest, false)
    }

    /// "(feat. X)", "[ft. X]" or "(with X)".
    private static func isCredit(_ group: Substring) -> Bool {
        let first = group.dropFirst().drop(while: \.isWhitespace).prefix(while: \.isLetter).lowercased()
        return first == "with" || bareCredits.contains(first)
    }

    /// "(Official Music Video)", "[Lyrics]" and the like.
    private static func isPackaging(_ group: Substring) -> Bool {
        var label = key(group)[...]
        for prefix in ["official", "music"] where label.hasPrefix(prefix) { label = label.dropFirst(prefix.count) }
        return packaging.contains(label)
    }

    /// The name outside brackets and before any " - " suffix, and the version words in the rest.
    private static func parts(_ title: String) -> (name: String, versions: Set<Substring>) {
        var outside = "", rest = ""
        scan(Self.title(title)[...]) { part, bracketed in
            if bracketed { outside += " "; rest += part } else { outside += part }
        }
        if let dash = outside.range(of: " - ") {
            rest += outside[dash.upperBound...]
            outside.removeSubrange(dash.lowerBound...)
        }
        let name = key(outside)
        return (name.isEmpty ? key(title) : name, Set(words(rest).filter(versionWords.contains)))
    }

    // MARK: - Artists

    private static func withoutTopic(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.hasSuffix(" - Topic") ? String(name.dropLast(8)) : name
    }

    /// Each name a credit joins, as "A feat. B & C" is A, B and C.
    private static func credits(_ credit: String) -> [String] {
        var credit = folded(withoutTopic(credit))
        for separator in [" and ", " x ", " with ", " feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            credit = credit.replacingOccurrences(of: separator, with: ",")
        }
        return credit.split { ",&;/".contains($0) }.map { key($0) }.filter { !$0.isEmpty }
    }

    // MARK: - Words

    /// One word, or one character of the scripts written without spaces, and the line's start on a line's first.
    private struct Token {
        var text: Substring
        var start: Double?
    }

    private static func tokens(_ lyrics: Lyrics) -> [Token] {
        var tokens: [Token] = []
        for (line, text) in lyrics.lines.enumerated() {
            let first = tokens.count
            for word in words(text) {
                var rest = word
                while let alone = rest.firstIndex(where: standsAlone) {
                    let next = rest.index(after: alone)
                    if alone > rest.startIndex { tokens.append(Token(text: rest[..<alone])) }
                    tokens.append(Token(text: rest[alone..<next]))
                    rest = rest[next...]
                }
                if !rest.isEmpty { tokens.append(Token(text: rest)) }
            }
            if lyrics.isSynced, first < tokens.count { tokens[first].start = lyrics.starts[line] }
        }
        return tokens
    }

    /// Han, kana and hangul.
    private static func standsAlone(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x1100..<0x1200).contains(scalar) || (0x2E80..<0xA000).contains(scalar) || (0xAC00..<0xD7B0).contains(scalar)
            || (0xF900..<0xFB00).contains(scalar) || scalar >= 0x20000
    }

    /// Lower case, without accents and with full-width forms made plain, as "ROSÉ" is "rose".
    private static func folded(_ text: some StringProtocol) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The folded runs of letters and digits.
    private static func words(_ text: some StringProtocol) -> [Substring] {
        folded(text).split { !$0.isLetter && !$0.isNumber }
    }

    private static func key(_ text: some StringProtocol) -> String {
        folded(text).filter { $0.isLetter || $0.isNumber }
    }
}
