// swift-tools-version: 6.2
import PackageDescription

// App-owned platform manifest around unmodified, pinned SDK sources.
let package = Package(
    name: "DeltaSwitch2Kit",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [.library(name: "Switch2Kit", targets: ["Switch2Kit"])],
    targets: [.target(name: "Switch2Kit", path: "Vendor/Switch2Kit/Sources/Switch2Kit", swiftSettings: [.swiftLanguageMode(.v6)])]
)
