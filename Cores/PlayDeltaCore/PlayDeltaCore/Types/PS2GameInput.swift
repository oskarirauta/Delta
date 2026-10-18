import DeltaCore

@objc public enum PS2GameInput: Int, Input {
    case up = 0
    case down = 1
    case left = 2
    case right = 3
    case cross = 4
    case circle = 5
    case square = 6
    case triangle = 7
    case l1 = 8
    case l2 = 9
    case l3 = 10
    case r1 = 11
    case r2 = 12
    case r3 = 13
    case start = 14
    case select = 15
    case leftStickUp = 16
    case leftStickDown = 17
    case leftStickLeft = 18
    case leftStickRight = 19
    case rightStickUp = 20
    case rightStickDown = 21
    case rightStickLeft = 22
    case rightStickRight = 23
    public var type: InputType { .game(.ps2) }
    public var isContinuous: Bool { rawValue >= 16 }
}
