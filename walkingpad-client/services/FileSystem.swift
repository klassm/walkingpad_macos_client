import Foundation
import os

/// Storage seam for Workout, following the same test-double pattern as
/// HttpTreadmillProviding/WsCommandExecuting: tests run against an in-memory
/// store instead of the app container's Autosave Information directory.
public protocol WorkoutStoring {
    func save(filename: String, data: Data)
    func load(filename: String) -> Data?
}

extension FileSystem: WorkoutStoring {}

class FileSystem {
    private static let logger = Logger(subsystem: "klassm.walkingpad-client", category: "filesystem")

    private func getDirectory() -> URL {
        let paths = FileManager.default.urls(for: .autosavedInformationDirectory, in: .userDomainMask)
        let path = paths[0]
        try? FileManager.default.createDirectory(atPath: path.path, withIntermediateDirectories: true)
        return path
    }

    public func save(filename: String, data: Data) {
        let path = self.getDirectory().appendingPathComponent(filename)
        Self.logger.info("saving to \(path.path, privacy: .public)")
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            Self.logger.error("Failed to write to \(path.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public func load(filename: String) -> Data? {
        let path = self.getDirectory().appendingPathComponent(filename)
        Self.logger.info("loading from \(path.path, privacy: .public)")
        do {
            return try Data(contentsOf: path)
        } catch {
            Self.logger.error("Failed to load from \(path.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
