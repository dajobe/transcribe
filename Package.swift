// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "transcribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly: the speaker embedder shipped by this SDK defines the
        // vectors stored in canonical transcripts and speaker profiles, and a
        // retrained embedder is not necessarily announced by a new model
        // version string. Bumping this pin means deciding whether the embedder
        // changed and updating CanonicalTranscript.speakerKitVersion (and the
        // embedder components of speakerEmbeddingModelID) when it did;
        // verifySpeakerEmbeddingModelID() catches the cases the SDK does
        // announce.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
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
