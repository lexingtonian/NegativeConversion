// swift-tools-version:5.9
import PackageDescription

// Command-line harness for the conversion core. Not part of the app.
let package = Package(
    name: "negcli",
    dependencies: [.package(name: "NegativeConverter", path: "../..")],
    targets: [
        .executableTarget(name: "negcli",
                          dependencies: [.product(name: "NegativeCore", package: "NegativeConverter")]),
    ]
)
