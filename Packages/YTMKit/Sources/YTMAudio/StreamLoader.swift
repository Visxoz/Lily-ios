import Foundation
import os

/// Asks in ranges, as googlevideo throttles large ones, and on a refusal carries on from
/// the same byte at a fresh URL for the same file.
final class StreamLoader {
    static let rangeLength: Int64 = 1 << 20
    private static let maxRetries = 4
    private static let retryDelay = Duration.milliseconds(500)
    /// Fresh URLs asked for in a row without a whole range arriving from them.
    private static let maxRefreshes = 2
    private static let replayLength: Int64 = 256 << 10
    static let warmLength: Int64 = 64 << 10

    /// Its descriptor follows the file as a finished part becomes the cached file.
    let reader: FileHandle
    /// The file's length, or 0 until a download of unknown length ends.
    private(set) var total: Int64
    /// Bytes on disk from the start of the file.
    private(set) var available: Int64
    private(set) var isComplete: Bool
    private let item: AudioItem
    private let cache: AudioCache
    private var url: URL
    /// The headers of the client that gave `url`, as googlevideo checks them.
    private var headers: [String: String]
    private var writer: FileHandle?
    private var part: URL?

    init(item: AudioItem, cache: AudioCache) throws(AudioFailure) {
        self.item = item
        self.cache = cache
        url = item.url
        headers = item.headers
        do {
            // A downloaded song plays from its own file, which the cache never holds.
            if let file = item.url.isFileURL ? item.url : cache.completeFile(for: item.cacheKey, length: item.contentLength) {
                reader = try FileHandle(forReadingFrom: file)
                total = try Int64(reader.seekToEnd())
                try reader.seek(toOffset: 0)
                available = total
                isComplete = true
            } else {
                let part = try cache.makePart(for: item.cacheKey)
                self.part = part
                writer = try FileHandle(forWritingTo: part)
                reader = try FileHandle(forReadingFrom: part)
                total = max(item.contentLength, 0)
                available = 0
                isComplete = false
            }
        } catch {
            throw .storage
        }
    }

    deinit {
        if let part, !isComplete {
            cache.discard(part)
        }
    }

    /// Returns why it failed, or nil once complete or cancelled.
    func run(
        isolation: isolated (any Actor)? = #isolation,
        source: any ByteSource,
        onBytes: (Data) -> Void
    ) async -> AudioFailure? {
        if isComplete {
            return await replay(upTo: total, onBytes)
        }
        // The start `warm` fetched is on disk already.
        if available > 0, let failure = await replay(upTo: available, onBytes) {
            return failure
        }
        var retries = 0
        var refreshes = 0
        // The range after the one arriving, asked for already so it follows with no round trip.
        var ahead: (start: Int64, bytes: AsyncThrowingStream<Data, any Error>)?
        while total <= 0 || available < total {
            guard !Task.isCancelled else { return nil }
            let start = available
            let end = total > 0 ? min(start + Self.rangeLength, total) : .max
            let bytes = if let ahead, ahead.start == start {
                ahead.bytes
            } else {
                source.bytes(of: url, headers: headers, range: start..<end)
            }
            ahead = end < total
                ? (end, source.bytes(of: url, headers: headers, range: end..<min(end + Self.rangeLength, total)))
                : nil
            do {
                for try await data in bytes {
                    guard !Task.isCancelled else { return nil }
                    try append(data)
                    onBytes(data)
                }
                guard !Task.isCancelled else { return nil }
                guard available > start else { throw ByteSourceError.empty }
                if end == .max {
                    total = available
                }
                retries = 0
                refreshes = 0
            } catch {
                ahead = nil
                guard !Task.isCancelled else { return nil }
                if let failure = error as? AudioFailure {
                    return failure
                }
                // A range that broke off after some bytes still got somewhere,
                // so only failures in a row that bring nothing give up.
                if available > start {
                    retries = 0
                }
                if error as? ByteSourceError == .refused {
                    guard refreshes < Self.maxRefreshes, let fresh = await refreshed() else { return .refused }
                    refreshes += 1
                    url = fresh.url
                    headers = fresh.headers
                    continue
                }
                guard retries < Self.maxRetries else {
                    Logger.audio.warning("A download failed after \(Self.maxRetries) retries: \(Self.reason(error), privacy: .public)")
                    return .download
                }
                retries += 1
                Logger.audio.debug("Download range failed, retry \(retries): \(Self.reason(error), privacy: .public)")
                try? await Task.sleep(for: Self.retryDelay * retries)
            }
        }
        try? writer?.close()
        writer = nil
        if let part {
            cache.commit(part, as: item.cacheKey)
        }
        isComplete = true
        return nil
    }

    /// Only a head start for `run`, so it never retries.
    func warm(isolation: isolated (any Actor)? = #isolation, source: any ByteSource) async {
        guard available == 0, total > 0 else { return }
        do {
            for try await data in source.bytes(of: url, headers: headers, range: 0..<min(Self.warmLength, total)) {
                guard !Task.isCancelled else { return }
                try append(data)
            }
        } catch {
            Logger.audio.debug("Could not warm a stream")
        }
    }

    private func append(_ data: Data) throws(AudioFailure) {
        guard let writer else { return }
        do {
            try writer.write(contentsOf: data)
        } catch {
            // Cut back to the bytes counted, so a later write follows them.
            try? writer.truncate(atOffset: UInt64(available))
            throw .storage
        }
        available += Int64(data.count)
    }

    /// Yields between pieces so commands can run.
    private func replay(isolation: isolated (any Actor)? = #isolation, upTo end: Int64, _ onBytes: (Data) -> Void) async -> AudioFailure? {
        // A loader kept from a download cut short left its reader where that
        // replay stopped: the decoder reads with pread, which never moves it.
        guard (try? reader.seek(toOffset: 0)) != nil else { return .damaged }
        var offset: Int64 = 0
        while offset < end {
            guard !Task.isCancelled else { return nil }
            guard let data = try? reader.read(upToCount: Int(min(Self.replayLength, end - offset))), !data.isEmpty else {
                return .damaged
            }
            onBytes(data)
            offset += Int64(data.count)
            await Task.yield()
        }
        return nil
    }

    /// Taken only if it serves the same encode, as the bytes already held must line up.
    private func refreshed(isolation: isolated (any Actor)? = #isolation) async -> (url: URL, headers: [String: String])? {
        do {
            let fresh = try await item.refresh()
            guard Self.sameFile(url, fresh.url) else {
                Logger.audio.warning("A refreshed stream URL serves a different file")
                return nil
            }
            return fresh
        } catch {
            Logger.audio.warning("No fresh URL for a refused download")
            return nil
        }
    }

    /// The same format, of the same length, from the same encode.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let first = parameters(a)
        let second = parameters(b)
        return first["itag"] != nil && ["itag", "clen", "lmt"].allSatisfy { first[$0] == second[$0] }
    }

    /// Why a range failed, without the error itself: a URLError's
    /// description carries the stream URL.
    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as ByteSourceError: String(describing: error)
        case let error as URLError: "URLError \(error.code.rawValue)"
        default: "other"
        }
    }

    private static func parameters(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

extension Logger {
    static let audio = Logger(subsystem: "Lily", category: "audio")
}
