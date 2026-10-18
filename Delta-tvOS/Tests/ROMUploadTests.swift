import XCTest
@testable import DeltaTVCatalog

final class ROMUploadTests: XCTestCase {
    func testChunkedUploadPublishesOnlyCompleteFileAndReplacesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("disc.ISO")
        try Data([9]).write(to: target)
        let upload = try TVROMUpload(directory: directory, filename: "disc.ISO", expectedBytes: 5)
        try upload.append(Data([1,2]))
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
        XCTAssertThrowsError(try upload.finish())
        try upload.append(Data([3,4,5]))
        try upload.finish()
        XCTAssertEqual(try Data(contentsOf: target), Data([1,2,3,4,5]))
    }

    func testInterruptedUploadCleansTemporaryFileAndRejectsOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var upload: TVROMUpload? = try TVROMUpload(directory: directory, filename: "disc.gcm", expectedBytes: 2)
        XCTAssertThrowsError(try upload?.append(Data([1,2,3])))
        try upload?.append(Data([1]))
        upload = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDisabledPS2ELFDoesNotReplaceExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("test.elf")
        try Data([42]).write(to: destination)
        var elf = Data(repeating: 0, count: 64)
        elf.replaceSubrange(0..<6, with: [0x7f, 0x45, 0x4c, 0x46, 1, 1])
        elf[18] = 8
        let upload = try TVROMUpload(directory: directory, filename: "test.elf", expectedBytes: elf.count)
        try upload.append(elf)
        XCTAssertThrowsError(try upload.finish())
        XCTAssertEqual(try Data(contentsOf: destination), Data([42]))
    }

    func testRejectsPathsAndUnsupportedFiles() {
        for name in ["../disc.iso", "/disc.iso", "a\\disc.iso", ".disc.iso", "disc.exe", "disc.chd", "disc.cso", "disc.isz", "disc.iso\0"] {
            XCTAssertThrowsError(try TVROMUpload(directory: .temporaryDirectory, filename: name, expectedBytes: 1))
        }
    }
}
