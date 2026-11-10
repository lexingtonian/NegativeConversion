// swift-tools-version:5.9
import PackageDescription

// NegativeCore is plain Swift (no Apple frameworks) and holds all of the
// negative-to-positive maths. NegativeConverter is the macOS SwiftUI app.

var products: [Product] = [
    .library(name: "NegativeCore", targets: ["NegativeCore"]),
]

var targets: [Target] = [
    .target(name: "NegativeCore"),
    .testTarget(name: "NegativeCoreTests", dependencies: ["NegativeCore"]),
]

#if os(macOS)
products.append(.executable(name: "NegativeConverter", targets: ["NegativeConverter"]))
// HEADLESS turns on the command-line test modes (Headless.swift). The Xcode
// project, which builds the App Store app, does not define it.
targets.append(.executableTarget(name: "NegativeConverter", dependencies: ["NegativeCore"],
                                 swiftSettings: [.define("HEADLESS")]))
#endif

let package = Package(
    name: "NegativeConverter",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
