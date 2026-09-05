// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoverFocus",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HoverFocusCore", targets: ["HoverFocusCore"]),
        .executable(name: "HoverFocus", targets: ["HoverFocus"])
    ],
    targets: [
        .target(
            name: "HoverFocusCore",
            path: "HoverFocusCore"
        ),
        .executableTarget(
            name: "HoverFocus",
            dependencies: ["HoverFocusCore"],
            path: "HoverFocusApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "HoverFocusTests",
            dependencies: ["HoverFocusCore"],
            path: "HoverFocusTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
