import Foundation

/// Apple Music's TTML, as lrc.red serves it, word timed or line timed.
enum TTML {
    static func lyrics(_ data: Data, source: String) -> Lyrics? {
        let reader = Reader()
        // External entities stay unresolved by default, so a document can't reach outside itself.
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), !reader.lines.isEmpty else { return nil }
        return Lyrics(
            lines: reader.lines,
            starts: reader.timed ? reader.starts : [],
            words: orEmpty(reader.words),
            translations: orEmpty(reader.extras[Extra.translation.rawValue]),
            romanised: orEmpty(reader.extras[Extra.romanised.rawValue]),
            source: source
        )
    }

    /// What a line may carry besides its words; the raw value indexes the reader's lists.
    private enum Extra: Int, CaseIterable {
        case translation, romanised

        /// A list with `value` for each extra.
        static func each<T>(_ value: T) -> [T] {
            Array(repeating: value, count: allCases.count)
        }
    }

    /// Empty unless some line has one.
    private static func orEmpty<T: Collection>(_ lines: [T]) -> [T] {
        lines.allSatisfy(\.isEmpty) ? [] : lines
    }

    /// A clock value in seconds: "27.395", "1:05.20", "1:02:03.4", "12.3s" or "500ms".
    static func seconds(_ clock: String) -> Double? {
        var value = 0.0
        if clock.hasSuffix("ms") {
            guard let ms = Double(clock.dropLast(2)) else { return nil }
            value = ms / 1000
        } else if clock.hasSuffix("s") {
            guard let s = Double(clock.dropLast()) else { return nil }
            value = s
        } else {
            let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 3 else { return nil }
            for part in parts {
                guard let n = Double(part) else { return nil }
                value = value * 60 + n
            }
        }
        return value.isFinite && value >= 0 ? value : nil
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private struct Span {
            let begin: Double?
            let end: Double?
            var hasChild = false
        }

        /// An extra being read: a head line's, by its key, or the line's own.
        private struct Capture {
            let kind: Extra
            let key: String?
            var depth = 1
        }

        var lines: [String] = []
        var starts: [Double] = []
        var words: [[Lyrics.Word]] = []
        /// Each line's translation and romanisation, by `Extra`.
        var extras: [[String]] = Extra.each([])
        var timed = false

        // Only <body>'s <p> is sung; <head> holds the extras by line key.
        private var inBody = false
        private var inLine = false
        private var begin: Double?
        private var key: String?
        private var lineWords: [Lyrics.Word] = []
        /// Text since the last span boundary, its whitespace collapsed.
        private var pending = ""
        private var spans: [Span] = []
        /// The head's first translation and romanisation, by line key.
        private var byKey: [[String: String]] = Extra.each([:])
        /// The head's translation or romanisation being read.
        private var section: Extra?
        /// The line's own translation and romanisation spans.
        private var inline = Extra.each("")
        private var capture: Capture?
        private var captured = ""
        /// Depth inside what isn't read: another language's extras, or a second of the line's own.
        private var skipped = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            if skipped > 0 {
                skipped += 1
                return
            }
            if capture != nil {
                capture?.depth += 1
                return
            }
            switch Self.local(elementName) {
            case "body":
                inBody = true
            case "translation" where !inBody:
                open(.translation)
            case "transliteration" where !inBody:
                open(.romanised)
            case "text" where section != nil:
                if let section, let key = Self.attribute("for", in: attributes) {
                    capture = Capture(kind: section, key: key)
                } else {
                    skipped = 1
                }
            case "p" where inBody:
                inLine = true
                begin = Self.time("begin", in: attributes)
                key = Self.attribute("key", in: attributes)
            case "span" where inLine:
                let kind: Extra? = switch Self.attribute("role", in: attributes) {
                case "x-translation": .translation
                case "x-roman": .romanised
                default: nil
                }
                if let kind {
                    if inline[kind.rawValue].isEmpty { capture = Capture(kind: kind, key: nil) } else { skipped = 1 }
                    return
                }
                flush()
                if !spans.isEmpty { spans[spans.count - 1].hasChild = true }
                spans.append(Span(begin: Self.time("begin", in: attributes), end: Self.time("end", in: attributes)))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if skipped > 0 {
                skipped -= 1
                return
            }
            if let reading = capture {
                if reading.depth > 1 {
                    capture?.depth -= 1
                } else {
                    endCapture(reading)
                }
                return
            }
            switch Self.local(elementName) {
            case "body": inBody = false
            case "translation", "transliteration": section = nil
            case "p" where inLine: endLine()
            case "span" where inLine: endSpan()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipped == 0 else { return }
            if capture != nil {
                Self.append(string, to: &captured)
            } else if inLine {
                Self.append(string, to: &pending)
            }
        }

        /// Only the first language's extras are read; the rest are skipped unread.
        private func open(_ kind: Extra) {
            if byKey[kind.rawValue].isEmpty { section = kind } else { skipped = 1 }
        }

        private func endCapture(_ read: Capture) {
            // `append` leaves at most one space at either end.
            let text = captured.trimmingCharacters(in: .whitespaces)
            captured = ""
            capture = nil
            let kind = read.kind.rawValue
            if let key = read.key {
                if byKey[kind][key] == nil { byKey[kind][key] = text }
            } else {
                inline[kind] = text
            }
        }

        /// The innermost timed spans are the words; any other span's text is untimed.
        private func endSpan() {
            guard let span = spans.popLast(), !span.hasChild, let start = span.begin, let end = span.end else {
                flush()
                return
            }
            // A leading space belongs after the word before, or nowhere on the first.
            if pending.first == " " {
                pending.removeFirst()
                if let last = lineWords.indices.last { Self.append(" ", to: &lineWords[last].text) }
            }
            let text = pending
            pending = ""
            if !text.isEmpty { lineWords.append(Lyrics.Word(text: text, start: start, end: end)) }
        }

        private func endLine() {
            flush()
            if let last = lineWords.indices.last, lineWords[last].text.hasSuffix(" ") { lineWords[last].text.removeLast() }
            let text = lineWords.isEmpty ? pending.trimmingCharacters(in: .whitespaces) : lineWords.map(\.text).joined()
            if !text.isEmpty {
                let start = min(begin ?? .infinity, lineWords.first?.start ?? .infinity)
                timed = timed || start.isFinite
                for kind in Extra.allCases {
                    let i = kind.rawValue
                    var extra = inline[i]
                    if extra.isEmpty, let key { extra = byKey[i].removeValue(forKey: key) ?? "" }
                    // A copy of the line adds nothing.
                    extras[i].append(extra == text ? "" : extra)
                }
                lines.append(text)
                starts.append(start.isFinite ? start : starts.last ?? 0)
                words.append(lineWords)
            }
            inLine = false
            key = nil
            inline = Extra.each("")
            lineWords = []
            pending = ""
            spans = []
        }

        /// Untimed text, such as a space or comma, joins the word before it; before the first word it waits for that
        /// word, or is the whole line if none comes.
        private func flush() {
            guard let last = lineWords.indices.last, !pending.isEmpty else { return }
            Self.append(pending, to: &lineWords[last].text)
            pending = ""
        }

        /// Collapses each whitespace run, pretty-printed newlines included, to one space.
        private static func append(_ string: String, to text: inout String) {
            for character in string {
                if !character.isWhitespace {
                    text.append(character)
                } else if text.last != " " {
                    text.append(" ")
                }
            }
        }

        /// Prefixes differ by host (tt:, itunes:, lrc:), so names are matched without them.
        private static func local(_ name: String) -> Substring {
            name.lastIndex(of: ":").map { name[name.index(after: $0)...] } ?? name[...]
        }

        private static func attribute(_ name: String, in attributes: [String: String]) -> String? {
            attributes.first { local($0.key) == name }?.value
        }

        private static func time(_ name: String, in attributes: [String: String]) -> Double? {
            attribute(name, in: attributes).flatMap(TTML.seconds)
        }
    }
}
