// Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
// Licensed under GPLv3 or a commercial license.
// See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

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
