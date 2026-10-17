import Foundation
import UIKit
import Metal

private let CS_OPS_STATUS: UInt32 = 0 /* OK */
private let CS_DEBUGGED: UInt32   = 0x10000000  /* Process is attached to debugger or AltJIT/JIT-enabled */

@_silgen_name("csops")
func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int

extension ProcessInfo {
    /// User setting toggle for JIT
    public static var isJITUserEnabled: Bool {
        get {
            // Default to true; if available, user gets full performance unless turned off
            if UserDefaults.standard.object(forKey: "TV_JIT_ENABLED") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "TV_JIT_ENABLED")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "TV_JIT_ENABLED")
        }
    }
    
    /// Hardware supports JIT (Apple TV 4K 1st gen+ or A12+ / Metal family apple3+)
    public var supportsJIT: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        if #available(tvOS 13.0, *) {
            return device.supportsFamily(.apple4) || device.supportsFamily(.apple3) || device.supportsFamily(.apple5) || device.supportsFamily(.apple6) || device.supportsFamily(.apple7) || device.supportsFamily(.apple8)
        }
        return true
    }
    
    /// True if debugged/debugger attached, meaning memory pages can be mapped executable
    public var isDebugging: Bool {
        var flags: UInt32 = 0
        let result = csops(getpid(), CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size)
        return result == 0 && (flags & CS_DEBUGGED == CS_DEBUGGED)
    }
    
    /// System & debugger state allow JIT
    public var isJITAvailable: Bool {
        guard self.supportsJIT else { return false }
        return self.isDebugging
    }
    
    /// Effective state: hardware supported + debugger attached + user enabled
    public var isJITActive: Bool {
        return self.isJITAvailable && ProcessInfo.isJITUserEnabled
    }
}
