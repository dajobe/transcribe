// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "transcribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcribe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "transcribeTests",
            dependencies: [
                "transcribe",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
