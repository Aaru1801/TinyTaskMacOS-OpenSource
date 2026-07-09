// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TinyRecorder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyRecorder", targets: ["TinyRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "TinyRecorder",
            path: "Sources/TinyRecorder"
        )
    ]
)
