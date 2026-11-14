import Foundation
import Testing
@testable import YTMAudio

struct StreamLoaderTests {
    private let file = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let cache = AudioCache(.init(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 1 << 20))

    private func load(_ item: AudioItem, from source: any ByteSource) async throws -> (StreamLoader, Data, AudioFailure?) {
        let loader = try StreamLoader(item: item, cache: cache)
        var received = Data()
        let failure = await loader.run(source: source) { received.append($0) }
        return (loader, received, failure)
    }

    @Test func resumesOnlyOnTheSameFile() throws {
        let url = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?expire=1&itag=251&clen=4171552&lmt=1700000000000000&n=a"))
        let fresh = "https://rr4.googlevideo.com/videoplayback?itag=251&n=b&lmt=1700000000000000&clen=4171552"
        func same(_ other: String) throws -> Bool { StreamLoader.sameFile(url, try #require(URL(string: other))) }
        #expect(try same(fresh), "another host and order, same file")
        #expect(try !same(fresh.replacingOccurrences(of: "itag=251", with: "itag=250")))
        #expect(try !same(fresh.replacingOccurrences(of: "clen=4171552", with: "clen=4171553")))
        #expect(try !same(fresh.replacingOccurrences(of: "lmt=1700000000000000", with: "lmt=1")), "re-encoded")
        let bare = try #require(URL(string: "https://a/251"))
        #expect(!StreamLoader.sameFile(bare, bare), "no format to go by")
    }

    @Test func carriesOnFromTheSameByteAtAFreshURL() async throws {
        let item = try AudioItem.fixture("song", length: file.count)
        let (loader, received, failure) = try await load(item, from: RefusingPartWay(files: ["song": file], after: 3_000))
        #expect(failure == nil && received == file && loader.isComplete)
        let cached = try #require(cache.completeFile(for: item.cacheKey, length: Int64(file.count)))
        #expect(try Data(contentsOf: cached) == file)
    }

    @Test func givesUpWhenEveryURLIsRefused() async throws {
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=1"))
        let item = AudioItem(id: "x", url: stale, headers: [:], contentLength: 10_000, cacheKey: "x-\(UUID())", loudnessDB: 0) { stale }
        let (loader, received, failure) = try await load(item, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == .refused && received.isEmpty && !loader.isComplete)
    }

    @Test func refusesAFreshURLForAnotherFile() async throws {
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=1"))
        let other = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=2&n=fresh"))
        let item = AudioItem(id: "x", url: stale, headers: [:], contentLength: 10_000, cacheKey: "x-\(UUID())", loudnessDB: 0) { other }
        let (_, _, failure) = try await load(item, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == .refused)
    }

    @Test func playsACachedFileWithNoNetwork() async throws {
        let item = try AudioItem.fixture("song", length: file.count)
        _ = try await load(item, from: MemoryByteSource(files: ["song": file]))
        let again = AudioItem(id: "again", url: item.url, headers: [:], contentLength: item.contentLength,
                              cacheKey: item.cacheKey, loudnessDB: 0, refresh: item.refresh)
        let (loader, received, failure) = try await load(again, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == nil && received == file && loader.isComplete && loader.available == Int64(file.count))
    }
}

/// Refuses a stale URL part way through a range, as googlevideo sometimes
/// does once the first megabyte or so has come; a fresh URL serves it all.
private struct RefusingPartWay: ByteSource {
    let files: [String: Data]
    let after: Int64

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        let served = MemoryByteSource(files: files, piece: 1_000).bytes(of: url, headers: headers, range: range)
        guard !url.absoluteString.contains("fresh") else { return served }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var offset = range.lowerBound
                do {
                    for try await data in served {
                        guard offset + Int64(data.count) <= after else { throw ByteSourceError.refused }
                        continuation.yield(data)
                        offset += Int64(data.count)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
