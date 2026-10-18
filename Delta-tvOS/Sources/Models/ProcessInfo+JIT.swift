import Foundation
import Darwin

private let codeSigningStatusOperation: UInt32 = 0
private let debuggedFlag: UInt32 = 0x10000000

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ operation: UInt32, _ address: UnsafeMutableRawPointer?, _ size: Int) -> Int32

extension ProcessInfo {
    static var isJITUserEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "TV_JIT_ENABLED") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "TV_JIT_ENABLED") }
    }

    /// A code-signing flag is a prerequisite hint, not proof that an emulator
    /// has entered its JIT backend. GPU family does not determine JIT support.
    var hasJITDebugFlag: Bool {
        var flags: UInt32 = 0
        let result = csops(getpid(), codeSigningStatusOperation, &flags, MemoryLayout<UInt32>.size)
        return result == 0 && flags & debuggedFlag != 0
    }

    var shouldRequestJIT: Bool { Self.isJITUserEnabled && hasJITDebugFlag }
}
