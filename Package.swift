// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NUKE",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NUKE", targets: ["NUKE"])],
    targets: [
        .executableTarget(
            name: "NUKE",
            path: "Sources/NUKE",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
