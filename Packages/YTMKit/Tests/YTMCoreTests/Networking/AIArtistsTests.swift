import Foundation
import Testing
@testable import YTMCore

@Suite struct AIArtistsTests {
    private static let long = "artist,id\n" + (0..<AIArtists.minNames).map { "Artist \($0),\($0)\n" }.joined()

    @Test func readsNamesButNeverAShortList() {
        let csv = "artist,id\n Aria Vale\u{3000},1a\nSmith, Jones,2b\n,3c\nno id\r\nLast,4d\n"
        #expect(Array(AIArtists.names(csv)) == ["Aria Vale", "Smith, Jones", "Last"])
        #expect(Array(AIArtists.names("artist,id\r\nAria Vale,1a\r\n")) == ["Aria Vale"], "CRLF throughout")
        #expect(AIArtists.parse(Data(csv.utf8)) == nil, "too few to trust")
        #expect(AIArtists.parse(Data(Self.long.utf8))?.count == AIArtists.minNames)
    }

    @Test func aKeptCopyIsDueWithinAMinuteOfLapsing() {
        #expect(AIArtists.dueAfter(.seconds(3_600)) == .seconds(3_600))
        #expect(AIArtists.dueAfter(.seconds(30)) == nil)
        #expect(AIArtists.dueAfter(.zero) == nil, "lapsed or missing")
    }

    /// Only cases that never fetch, as a fetch would reach GitHub.
    @Test func aKeptCopyIsUsedWhileFreshAndWhenStaleWithNoneHeld() async throws {
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-ai-\(UUID().uuidString)"))
        let file = store.aiArtists
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(Self.long.utf8).write(to: file)
        let fresh = try await AIArtists.load(held: true, store: store) { Issue.record("fetched a fresh copy") }
        #expect(fresh.listed.count == AIArtists.minNames && fresh.due > .zero)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: file.path)
        let stale = try await AIArtists.load(held: false, store: store) { Issue.record("fetched with a copy kept") }
        #expect(stale.listed.count == AIArtists.minNames && stale.due == .zero)
    }
}
