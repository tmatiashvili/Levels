import Foundation

/// Reads and writes `snapshot.json` in the App Group container (ADR-0009, SYNC-002 R11–R13).
///
/// Holds only a URL. `update` and `reset` block on `NSFileCoordinator`, so call them
/// off the main actor. `read` never coordinates; atomic replacement makes it safe.
public struct SnapshotCache: Sendable {
    /// `<container>/Levels/snapshot.json`.
    public let fileURL: URL

    /// Opens the cache in the App Group container. Returns `nil` when the container is
    /// missing or its `Levels` directory can't be created or written (on macOS
    /// `containerURL` always returns a URL, so the directory is checked).
    public init?(appGroupID: String) {
        self.init(appGroupID: appGroupID) { id in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        }
    }

    /// Testable form of ``init(appGroupID:)``: `containerURL` stands in for the App Group lookup.
    init?(appGroupID: String, containerURL: (String) -> URL?) {
        guard let container = containerURL(appGroupID) else { return nil }
        let cache = SnapshotCache(directory: container)
        let directory = cache.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else { return nil }
        self = cache
    }

    /// Uses `directory` in place of the App Group container root (tests, previews).
    /// The file is `directory/Levels/snapshot.json`.
    public init(directory: URL) {
        fileURL = directory
            .appendingPathComponent("Levels", isDirectory: true)
            .appendingPathComponent("snapshot.json", isDirectory: false)
    }

    /// The cached snapshot, or `nil` if the file is missing, unreadable, not valid JSON,
    /// or has an unknown `formatVersion` (SYNC-002 R12). Never throws.
    public func read() -> SnapshotFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return Self.decode(data)
    }

    /// Read, transform and write inside one coordinated write, replacing the file
    /// atomically (SYNC-002 R13). A missing or unreadable file starts from an empty
    /// ``SnapshotFile``. Nothing is written when `body` leaves the snapshot unchanged.
    /// Returns what `body` returns.
    @discardableResult
    public func update<T>(_ body: (inout SnapshotFile) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<T, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: .forMerging, error: &coordinationError
        ) { url in
            result = Result {
                let existing = (try? Data(contentsOf: url)).flatMap(Self.decode)
                var file = existing ?? SnapshotFile()
                let value = try body(&file)
                file.formatVersion = SnapshotFile.currentFormatVersion
                if file != existing {
                    try Self.encode(file).write(to: url, options: .atomic)
                }
                return value
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    /// Deletes the file (account change, ADR-0009).
    public func reset() throws {
        var outcome: Result<Void, any Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: .forDeleting, error: &coordinationError
        ) { url in
            outcome = Result {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try outcome.get()
    }

    // MARK: Encoding (SYNC-002 R11)

    private struct Header: Decodable { var formatVersion: Int }

    static func decode(_ data: Data) -> SnapshotFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let header = try? decoder.decode(Header.self, from: data),
              header.formatVersion == SnapshotFile.currentFormatVersion
        else { return nil }
        return try? decoder.decode(SnapshotFile.self, from: data)
    }

    static func encode(_ file: SnapshotFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }
}
