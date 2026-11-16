import Foundation
import Testing
@testable import YTMAudio

struct AudioCacheTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func store(_ key: String, bytes: Int, age: TimeInterval, in cache: AudioCache) throws {
        let part = try cache.makePart(for: key)
        try Data(count: bytes).write(to: part)
        cache.commit(part, as: key)
        let file = try #require(cache.completeFile(for: key, length: Int64(bytes)))
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    @Test func evictsTheLeastRecentlyPlayedPastItsCap() throws {
        let cache = AudioCache(.init(directory: directory, limit: 25))
        try store("old", bytes: 10, age: 300, in: cache)
        try store("older", bytes: 10, age: 600, in: cache)
        // Playing it marks it as just used, so the other goes first.
        #expect(cache.completeFile(for: "older", length: 10) != nil)
        try store("new", bytes: 10, age: 0, in: cache)
        #expect(cache.completeFile(for: "old", length: 10) == nil)
        #expect(cache.completeFile(for: "older", length: 10) != nil)
        #expect(cache.size() == 20)
    }

    @Test func takesOnlyCompleteFilesOfTheRightLength() throws {
        let cache = AudioCache(.init(directory: directory, limit: 1 << 20))
        let part = try cache.makePart(for: "song-251")
        try Data(count: 64).write(to: part)
        #expect(cache.size() == 0, "a part is not in the cache yet")
        #expect(cache.completeFile(for: "song-251", length: 64) == nil)
        cache.commit(part, as: "song-251")
        #expect(cache.completeFile(for: "song-251", length: 64) != nil)
        #expect(cache.completeFile(for: "song-251", length: 65) == nil, "another encode")
        #expect(cache.completeFile(for: "song-251", length: 0) != nil, "a length the server did not give")
        cache.clear()
        #expect(cache.size() == 0)
    }

    @Test func removesPartsLeftByAnEarlierRun() throws {
        let part = try AudioCache(.init(directory: directory, limit: 1 << 20)).makePart(for: "cut-short")
        _ = AudioCache(.init(directory: directory, limit: 1 << 20))
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func trimsToASmallerCapAtLaunch() throws {
        let cache = AudioCache(.init(directory: directory, limit: 1 << 20))
        try store("old", bytes: 10, age: 300, in: cache)
        try store("new", bytes: 10, age: 0, in: cache)
        let smaller = AudioCache(.init(directory: directory, limit: 15))
        #expect(smaller.completeFile(for: "old", length: 10) == nil)
        #expect(smaller.completeFile(for: "new", length: 10) != nil)
    }

    @Test func namesFilesSafely() throws {
        let cache = AudioCache(.init(directory: directory, limit: 1 << 20))
        let part = try cache.makePart(for: "../escape")
        #expect(part.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }
}
