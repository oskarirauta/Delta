import Foundation
import AVFoundation
import DeltaCore
import GBADeltaCore

public struct MGBA: DeltaCoreProtocol {
    public static let core = MGBA()
    public var name: String { "MGBADeltaCore" }
    public var identifier: String { "com.delta.MGBADeltaCore" }
    public var version: String? { "0.10.5" }
    public var gameType: GameType { .gba }
    public var gameInputType: Input.Type { GBAGameInput.self }
    public var gameSaveFileExtension: String { "mgba.sav" }
    public var audioFormat: AVAudioFormat { GBA.core.audioFormat }
    public var videoFormat: VideoFormat { VideoFormat(format: .bitmap(.rgba8), dimensions: CGSize(width: 240, height: 160)) }
    public var resourceBundle: Bundle { GBA.core.resourceBundle }
    public var supportedCheatFormats: Set<CheatFormat> { GBA.core.supportedCheatFormats }
    public var emulatorBridge: EmulatorBridging { MGBAEmulatorBridge.shared }
    private init() {}
}
