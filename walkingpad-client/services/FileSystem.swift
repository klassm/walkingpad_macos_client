import Foundation

class FileSystem {
    private func getDirectory() -> URL {
        let paths = FileManager.default.urls(for: .autosavedInformationDirectory, in: .userDomainMask)
        let path = paths[0]
        try? FileManager.default.createDirectory(atPath: path.path, withIntermediateDirectories: true)
        return path
    }
    
    public func save(filename: String, data: Data) {
        let path = self.getDirectory().appendingPathComponent(filename)
        print("saving to \(path)")
        do {
            try data.write(to: path)
        } catch {
            print("Failed to write to \(path): \(error)")
        }
    }
    
    public func load(filename: String) -> Data? {
        let path = self.getDirectory().appendingPathComponent(filename)
        print("loading from \(path)")
        do {
            return try Data(contentsOf: path)
        } catch {
            print("Failed to load from \(path): \(error)")
            return nil
        }
    }
    
}
