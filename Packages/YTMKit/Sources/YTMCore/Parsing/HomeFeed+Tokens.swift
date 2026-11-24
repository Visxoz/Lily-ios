import Foundation
import os

extension HomeFeed {
    private static let log = Logger(subsystem: "Lily", category: "Home")
    /// Pages after the first asked for together, the feed's usual rest.
    static let atOnce = 4
    /// Low, as a batch waits for its slowest page; a failed one is read again later.
    static let madePageAttempts = 2

    /// `atOnce` continuation tokens, the first page's own then the next ones. YouTube keeps the feed as a snapshot, so
    /// they differ only in the starting shelf: field 1 of the base64 in field 3 of field 80226972, and that plus one in
    /// field 318126543 of the base64 in field 15.
    static func laterTokens(_ token: String) -> [String]? {
        guard let (outer, outerSpelling) = Base64Spelling.decode(token.replacingOccurrences(of: "%3D", with: "=").utf8),
              let browse = Protobuf.range(of: 80_226_972, in: outer[...]),
              let text = Protobuf.range(of: 3, in: outer[browse]),
              let (inner, innerSpelling) = Base64Spelling.decode(outer[text]),
              let first = Protobuf.range(of: 1, in: inner[...]),
              let nestedText = Protobuf.range(of: 15, in: inner[...]),
              let (nested, nestedSpelling) = Base64Spelling.decode(inner[nestedText]),
              let next = Protobuf.range(of: 318_126_543, in: nested[...]),
              let value = Protobuf.range(of: 1, in: nested[next]),
              first.count == 1, value.count == 1
        else { return nil }
        // The first page's length, so where the second starts.
        let step = inner[first.lowerBound]
        // Bounded first, so every shelf stays one byte.
        guard step > 0, Int(step) * atOnce + 1 < 0x80, nested[value.lowerBound] == step + 1 else { return nil }
        let tokens = (1...UInt8(atOnce)).map { page in
            let shelf = step * page
            var (outer, inner, nested) = (outer, inner, nested)
            nested[value.lowerBound] = shelf + 1
            inner[first.lowerBound] = shelf
            // Same byte count, same spelling: each layer keeps its length.
            inner.replaceSubrange(nestedText, with: nestedSpelling.encode(nested).utf8)
            outer.replaceSubrange(text, with: innerSpelling.encode(inner).utf8)
            return outerSpelling.encode(outer).replacingOccurrences(of: "=", with: "%3D")
        }
        return tokens.first == token ? tokens : nil
    }

    /// A batch's pages in order, up to one that failed or led elsewhere. Throws only if the first failed.
    static func batch(_ tokens: [String], _ answers: [Result<Shelves, any Error>]) throws -> Pages {
        var sections: [Section] = []
        var next: String?
        for (index, answer) in answers.enumerated() {
            let page: Shelves
            do {
                page = try answer.get()
            } catch {
                guard index > 0 else { throw error }
                return (sections, next, index)
            }
            sections += page.sections
            next = page.next
            if !leadsOn(page, at: index, tokens) {
                // Leading nowhere ends the feed; elsewhere, the tokens were wrong.
                if page.next != nil { log.debug("Home's tokens no longer match the pages made") }
                return (sections, next, index + 1)
            }
        }
        return (sections, next, answers.count)
    }

    /// Whether a page in order, answers still to come aside, failed or led elsewhere, so those after it are wasted.
    static func isCutShort(_ tokens: [String], _ answers: [Result<Shelves, any Error>?]) -> Bool {
        for (index, answer) in answers.enumerated() {
            guard let answer else { return false }
            guard case .success(let page) = answer, leadsOn(page, at: index, tokens) else { return true }
        }
        return false
    }

    /// Whether the page at `index` leads to the next token made, the last always.
    private static func leadsOn(_ page: Shelves, at index: Int, _ tokens: [String]) -> Bool {
        index + 1 >= tokens.count || page.next == tokens[index + 1]
    }
}

/// One of base64's four spellings: the one that spells the decoded bytes back exactly.
private struct Base64Spelling {
    let urlSafe: Bool
    let padded: Bool

    static func decode(_ bytes: some Collection<UInt8>) -> ([UInt8], Self)? {
        let text = String(decoding: bytes, as: UTF8.self)
        for spelling in [(false, true), (false, false), (true, true), (true, false)].map(Self.init) {
            var standard = text
            if spelling.urlSafe {
                standard = standard.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            }
            if !spelling.padded { standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4) }
            guard let data = Data(base64Encoded: standard) else { continue }
            let decoded = [UInt8](data)
            if spelling.encode(decoded) == text { return (decoded, spelling) }
        }
        return nil
    }

    func encode(_ bytes: [UInt8]) -> String {
        var text = Data(bytes).base64EncodedString()
        if urlSafe { text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if !padded { text = text.replacingOccurrences(of: "=", with: "") }
        return text
    }
}
