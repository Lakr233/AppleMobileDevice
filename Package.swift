// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "AppleMobileDevice",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "AppleMobileDevice",
            targets: ["AppleMobileDevice"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/AppleMobileDeviceLibrary.git", branch: "main")
    ],
    targets: [
        .target(name: "AppleMobileDevice", dependencies: [
            "AnyCodable",
            "AppleMobileDeviceLibrary",
            "AppleMobileDeviceLibraryBackup",
        ]),
        .target(name: "AnyCodable"),
        .target(name: "AppleMobileDeviceLibraryBackup", dependencies: ["AppleMobileDeviceLibrary"]),
    ]
)
