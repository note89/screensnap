// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Screensnap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Screensnap", targets: ["Screensnap"])
    ],
    targets: [
        .executableTarget(
            name: "Screensnap",
            path: "Sources/Screensnap"
        )
    ]
)
