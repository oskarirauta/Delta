/// Backend support, process prerequisites, preference, and actual execution are
/// distinct facts. A saved switch must never be presented as an active compiler.
enum TVJITStatus: Equatable {
    case unsupported
    case active
    case disabled
    case permissionRequired
    case nextSession

    init(backendSupported: Bool, debugFlag: Bool, requested: Bool, active: Bool) {
        if !backendSupported { self = .unsupported }
        else if active { self = .active }
        else if !requested { self = .disabled }
        else if !debugFlag { self = .permissionRequired }
        else { self = .nextSession }
    }

    var title: String {
        switch self {
        case .unsupported: return "JIT: Not Supported by This Core Build"
        case .active: return "JIT: Active"
        case .disabled: return "JIT: Disabled"
        case .permissionRequired: return "JIT: Process Permission Required"
        case .nextSession: return "JIT: Requested for Next Session"
        }
    }
}
