import Foundation

/// Bounded-memory upload, published only after the entire declared body arrives.
final class TVROMUpload {
    enum UploadError: LocalizedError {
        case disabledSystem(String)
        var errorDescription: String? {
            switch self { case .disabledSystem(let name): return "\(name) support is disabled in this build." }
        }
    }

    let destination: URL
    let expectedBytes: Int
    private(set) var receivedBytes = 0
    private let temporary: URL
    private var file: FileHandle?

    init(directory: URL, filename: String, expectedBytes: Int) throws {
        guard expectedBytes > 0, !filename.isEmpty, !filename.hasPrefix("."),
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0"),
              TVSystem.uploadExtensions.contains((filename as NSString).pathExtension.lowercased()) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.expectedBytes = expectedBytes
        destination = directory.appendingPathComponent(filename)
        temporary = directory.appendingPathComponent(".\(UUID().uuidString).upload")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: temporary)
    }

    deinit { try? file?.close(); try? FileManager.default.removeItem(at: temporary) }

    func append(_ data: Data) throws {
        guard data.count <= expectedBytes - receivedBytes, let file else { throw CocoaError(.fileWriteOutOfSpace) }
        try file.write(contentsOf: data)
        receivedBytes += data.count
    }

    func finish() throws {
        guard receivedBytes == expectedBytes, let file else { throw CocoaError(.fileReadCorruptFile) }
        try file.close()
        self.file = nil
        if let system = TVSystem.system(forFileURL: temporary, fileExtension: destination.pathExtension), !system.isEnabled {
            throw UploadError.disabledSystem(system.shortName)
        }
        // rename(2) atomically replaces an existing file on the same filesystem.
        let result = temporary.path.withCString { source in destination.path.withCString { target in rename(source, target) } }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
