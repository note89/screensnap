// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GifRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GifRecorder", targets: ["GifRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "GifRecorder",
            path: "Sources/GifRecorder"
        )
    ]
)
