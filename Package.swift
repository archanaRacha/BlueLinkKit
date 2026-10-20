// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlueLinkKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BlueLinkKit", targets: ["BlueLinkKit"])
    ],
    targets: [
        .target(
            name: "BlueLinkKit",
            dependencies: []
        ),
        .testTarget(
            name: "BlueLinkKitTests",
            dependencies: ["BlueLinkKit"]
        )
    ]
)
