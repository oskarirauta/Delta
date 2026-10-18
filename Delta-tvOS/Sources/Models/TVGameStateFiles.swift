import Foundation

struct TVGameStateFiles {
    let romURL: URL
    var coreNamespace: String? = nil

    // Keep the ROM extension so same-named games on different systems do not
    // share automatic states. Preserve the existing manual-state path.
    var automaticURL: URL { (coreNamespace.map { romURL.appendingPathExtension($0) } ?? romURL).appendingPathExtension("autosave") }
    var manualURL: URL { (coreNamespace.map { romURL.appendingPathExtension($0) } ?? romURL.deletingPathExtension()).appendingPathExtension("savestate") }

    var resumeURL: URL? {
        [automaticURL, manualURL].first { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    func saveAutomatic(using writer: (URL) throws -> Void) throws {
        let temporary = automaticURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).autosave")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writer(temporary)
        let values = try temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Publish only a complete, nonempty state. Same-directory rename keeps
        // the previous resume point intact if writing or validation fails.
        let result = temporary.path.withCString { source in
            automaticURL.path.withCString { destination in rename(source, destination) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
