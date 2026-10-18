import XCTest
@testable import DeltaTVCatalog

final class ROMCatalogTests: XCTestCase {
    func testAllExistingDeltaSystemsAreAvailable() {
        XCTAssertEqual(Set(TVSystem.allCases), [.nes, .snes, .n64, .gbc, .gba, .genesis, .ds, .gamecube, .ps2])
    }

    func testUnfinishedDolphinCannotBeLaunchedButImportMetadataIsPreserved() {
        XCTAssertFalse(TVSystem.gamecube.isPlayable)
        XCTAssertFalse(TVSystem.playableSystems.contains(.gamecube))
        XCTAssertNil(TVSystem.system(forFileExtension: "iso"))
        XCTAssertEqual(Set(TVSystem.playableSystems), [.nes, .snes, .n64, .gbc, .gba, .genesis, .ds])
    }

    func testPS2IsDisabledAndNotAdvertisedForUpload() {
        XCTAssertFalse(TVSystem.ps2.isEnabled)
        XCTAssertFalse(TVSystem.ps2.isPlayable)
        XCTAssertFalse(TVSystem.enabledSystems.contains(.ps2))
        XCTAssertTrue(Set(["chd", "cso", "isz"]).isDisjoint(with: TVSystem.uploadExtensions))
        // Shared GameCube extensions remain accepted and content-detected.
        XCTAssertTrue(TVSystem.uploadExtensions.contains("iso"))
        XCTAssertTrue(TVSystem.uploadExtensions.contains("elf"))
    }

    func testROMExtensionsAndCaseInsensitiveDetection() {
        let fixtures: [TVSystem: [String]] = [
            .nes: ["nes"], .snes: ["smc", "sfc", "fig"], .n64: ["n64", "z64", "v64"],
            .gbc: ["gb", "gbc"], .gba: ["gba"], .genesis: ["gen", "md", "smd", "bin"], .ds: ["ds", "nds"], .gamecube: ["gcm", "ciso", "rvz", "dol"], .ps2: ["chd", "cso", "isz"]
        ]
        for (system, extensions) in fixtures {
            for fileExtension in extensions {
                XCTAssertEqual(TVSystem.system(forFileExtension: fileExtension), system)
                XCTAssertEqual(TVSystem.system(forFileExtension: fileExtension.uppercased()), system)
            }
        }
    }

    func testWebUploadsAcceptEveryLibraryROMExtension() {
        let uploads = Set(TVSystem.uploadExtensions)
        for system in TVSystem.enabledSystems {
            XCTAssertTrue(Set(system.supportedExtensions).isSubset(of: uploads))
        }
        XCTAssertTrue(Set(["zip", "png", "jpg", "jpeg"]).isSubset(of: uploads))
        XCTAssertEqual(uploads.count, TVSystem.uploadExtensions.count)
    }

    func testSavesArtworkAndArchivesAreNotListedAsGames() {
        for fileExtension in ["sav", "dsv", "savestate", "png", "jpg", "zip", "exe", ""] {
            XCTAssertNil(TVSystem.system(forFileExtension: fileExtension))
        }
    }

    func testSharedContainersRequireContentDetection() {
        for ext in ["iso", "ISO", "elf", "ELF"] { XCTAssertNil(TVSystem.system(forFileExtension: ext)) }
        XCTAssertTrue(TVSystem.uploadExtensions.contains("iso"))
        XCTAssertFalse(TVSystem.uploadExtensions.contains("chd"))
        XCTAssertTrue(TVSystem.uploadExtensions.contains("elf"))
    }

    func testDiscHeadersDistinguishPS2GameCubeAndUnsupportedDiscs() throws {
        func detect(_ data: Data, ext: String = "iso") throws -> TVSystem? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return TVSystem.system(forFileURL: url)
        }
        var gc = Data(repeating: 0, count: 64)
        gc.replaceSubrange(28..<32, with: [0xc2,0x33,0x9f,0x3d])
        XCTAssertEqual(try detect(gc), .gamecube)
        var wii = Data(repeating: 0, count: 64)
        wii.replaceSubrange(24..<28, with: [0x5d,0x1c,0x9e,0xa3])
        XCTAssertNil(try detect(wii))
        XCTAssertNil(try detect(Data()))
        var iso = Data(repeating: 0, count: 22 * 2048)
        let pvd = 16 * 2048
        iso[pvd] = 1
        iso.replaceSubrange((pvd+1)..<(pvd+6), with: "CD001".utf8)
        iso[pvd+158] = 20 // root directory extent
        iso[pvd+167] = 8 // 2048-byte directory
        let root = 20 * 2048
        let name = Array("SYSTEM.CNF;1".utf8)
        iso[root] = UInt8(33 + name.count)
        iso[root+2] = 21
        let config = Array("BOOT2 = cdrom0:\\SLUS_208.73;1\n".utf8)
        iso[root+10] = UInt8(config.count)
        iso[root+32] = UInt8(name.count)
        iso.replaceSubrange((root+33)..<(root+33+name.count), with: name)
        iso.replaceSubrange((21*2048)..<(21*2048+config.count), with: config)
        XCTAssertEqual(try detect(iso, ext: "ISO"), .ps2)
        iso[21*2048+4] = 32 // PS1-style BOOT is not PS2
        XCTAssertNil(try detect(iso))
        iso[pvd+169] = 0xff // oversized directory must not be allocated/read
        XCTAssertNil(try detect(iso))
    }

    func testELFArchitectureDistinguishesPS2AndGameCube() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ELF")
        defer { try? FileManager.default.removeItem(at: url) }
        var elf = Data(repeating: 0, count: 64)
        elf.replaceSubrange(0..<6, with: [0x7f,0x45,0x4c,0x46,1,1])
        elf[18] = 8
        try elf.write(to: url)
        XCTAssertEqual(TVSystem.system(forFileURL: url), .ps2)
        elf[5] = 2; elf[18] = 0; elf[19] = 20
        try elf.write(to: url)
        XCTAssertEqual(TVSystem.system(forFileURL: url), .gamecube)
        elf[19] = 62
        try elf.write(to: url)
        XCTAssertNil(TVSystem.system(forFileURL: url))
    }
}
