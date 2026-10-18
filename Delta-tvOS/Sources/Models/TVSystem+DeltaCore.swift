import DeltaCore
import NESDeltaCore
import SNESDeltaCore
import N64DeltaCore
import GBCDeltaCore
import GBADeltaCore
import MGBADeltaCore
import GPGXDeltaCore
import MelonDSDeltaCore
import DolphinDeltaCore
import PlayDeltaCore

extension TVSystem {
    var stateNamespace: String? { self == .gba && core.identifier == MGBA.core.identifier ? "mgba" : nil }

    var gameType: GameType { core.gameType }

    var core: DeltaCoreProtocol {
        switch self {
        case .nes: return NES.core
        case .snes: return SNES.core
        case .n64: return N64.core
        case .gbc: return GBC.core
        case .gba: return UserDefaults.standard.string(forKey: "TVGBACore") == "vba-m" ? GBA.core : MGBA.core
        case .genesis: return GPGX.core
        case .ds: return MelonDS.core
        case .gamecube: return Dolphin.core
        case .ps2: return Play.core
        }
    }
}
