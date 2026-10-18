import Foundation

enum TVSystem: String, CaseIterable, Identifiable {
    case nes = "NES"
    case snes = "SNES"
    case n64 = "N64"
    case gbc = "GB/GBC"
    case gba = "GBA"
    case genesis = "Mega Drive"
    case ds = "DS"
    case gamecube = "GameCube"
    case ps2 = "PS2"
    
    var id: String { rawValue }
    
    var fullName: String {
        switch self {
        case .nes: return "Nintendo Entertainment System"
        case .snes: return "Super Nintendo"
        case .n64: return "Nintendo 64"
        case .gbc: return "Game Boy / Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .genesis: return "Sega Mega Drive / Genesis"
        case .ds: return "Nintendo DS"
        case .gamecube: return "Nintendo GameCube"
        case .ps2: return "Sony PlayStation 2"
        }
    }
    
    // Preserve PS2 detection and adapter sources for a future JIT solution.
    var isEnabled: Bool { self != .ps2 }
    static var enabledSystems: [TVSystem] { allCases.filter(\.isEnabled) }
    var isPlayable: Bool { isEnabled && self != .gamecube }
    static var playableSystems: [TVSystem] { enabledSystems.filter(\.isPlayable) }

    var shortName: String {
        return rawValue
    }
    

    

    static func system(forFileExtension fileExtension: String) -> TVSystem? {
        let matches = allCases.filter { $0.supportedExtensions.contains(fileExtension.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    /// ISO and ELF are shared containers. Inspect their contents before selecting a core.
    static func system(forFileURL url: URL, fileExtension: String? = nil) -> TVSystem? {
        let ext = (fileExtension ?? url.pathExtension).lowercased()
        guard ext == "iso" || ext == "elf" else { return system(forFileExtension: ext) }
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
            do { try file.seek(toOffset: offset); return Array(try file.read(upToCount: count) ?? Data()) }
            catch { return [] }
        }
        func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        let header = read(0, 64)
        if ext == "elf" {
            guard header.count >= 20, Array(header[0..<4]) == [0x7f, 0x45, 0x4c, 0x46] else { return nil }
            // PS2 ELF32 MIPS (little endian); GameCube ELF32 PowerPC (big endian).
            if header[4] == 1 && header[5] == 1 && header[18] == 8 && header[19] == 0 { return .ps2 }
            if header[4] == 1 && header[5] == 2 && header[18] == 0 && header[19] == 20 { return .gamecube }
            return nil
        }
        if header.count >= 32 && Array(header[28..<32]) == [0xc2, 0x33, 0x9f, 0x3d] { return .gamecube }
        // Wii is not a playable/catalogued system yet; do not mistake it for PS2.
        if header.count >= 28 && Array(header[24..<28]) == [0x5d, 0x1c, 0x9e, 0xa3] { return nil }
        let descriptor = read(16 * 2048, 2048)
        guard descriptor.count == 2048, descriptor[0] == 1,
              Array(descriptor[1..<6]) == Array("CD001".utf8) else { return nil }
        let rootBlock = little32(descriptor, 158)
        let rootSize = little32(descriptor, 166)
        guard rootSize > 0, rootSize <= 1024 * 1024 else { return nil }
        let directory = read(UInt64(rootBlock) * 2048, Int(rootSize))
        var offset = 0
        while offset + 33 <= directory.count {
            let length = Int(directory[offset])
            if length == 0 { offset = (offset / 2048 + 1) * 2048; continue }
            guard length >= 33, offset + length <= directory.count else { break }
            let nameLength = Int(directory[offset + 32])
            guard nameLength <= length - 33 else { break }
            let name = String(bytes: directory[(offset + 33)..<(offset + 33 + nameLength)], encoding: .ascii)?.uppercased()
            if name == "SYSTEM.CNF;1" || name == "SYSTEM.CNF" {
                let block = little32(directory, offset + 2)
                let size = little32(directory, offset + 10)
                guard size > 0, size <= 65536 else { return nil }
                let config = String(bytes: read(UInt64(block) * 2048, Int(size)), encoding: .ascii) ?? ""
                return config.split(whereSeparator: \.isNewline).contains { line in
                    line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).uppercased() == "BOOT2"
                } ? .ps2 : nil
            }
            offset += length
        }
        return nil
    }

    static var uploadExtensions: [String] {
        Array(Set(enabledSystems.flatMap(\.supportedExtensions) + ["zip", "png", "jpg", "jpeg"])).sorted()
    }

    var supportedExtensions: [String] {
        switch self {
        case .nes: return ["nes"]
        case .snes: return ["smc", "sfc", "fig"]
        case .n64: return ["n64", "z64", "v64"]
        case .gbc: return ["gb", "gbc"]
        case .gba: return ["gba"]
        case .genesis: return ["gen", "md", "smd", "bin"]
        case .ds: return ["ds", "nds"]
        case .gamecube: return ["iso", "gcm", "ciso", "rvz", "dol", "elf"]
        case .ps2: return ["iso", "chd", "cso", "isz", "elf"]
        }
    }
    
    var systemIconName: String {
        switch self {
        case .nes: return "dpad"
        case .snes: return "gamecontroller"
        case .n64: return "arcade.stick.console"
        case .gbc, .gba: return "gamecontroller"
        case .genesis: return "dpad"
        case .ds: return "rectangle.split.1x2"
        case .gamecube: return "cube.fill"
        case .ps2: return "opticaldisc"
        }
    }
}
