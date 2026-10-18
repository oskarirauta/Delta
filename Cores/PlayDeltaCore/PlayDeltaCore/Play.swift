import Foundation
import AVFoundation
import DeltaCore

public struct Play: DeltaCoreProtocol {
    public static let core = Play()
    public var name: String { "Play!" }
    public var identifier: String { "com.delta.PlayDeltaCore" }
    public var gameType: GameType { .ps2 }
    public var gameInputType: Input.Type { PS2GameInput.self }
    public var gameSaveFileExtension: String { "ps2save" }
    public var audioFormat: AVAudioFormat { PlayEmulatorBridge.shared.preferredAudioFormat }
    public var videoFormat: VideoFormat { VideoFormat(format: .openGLES3, dimensions: CGSize(width: 640, height: 448)) }
    public var supportedCheatFormats: Set<CheatFormat> { [] }
    public var emulatorBridge: EmulatorBridging { PlayEmulatorBridge.shared }
    private init() {}
}
