// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle — auto-update framework. Pinned to 2.6+ for stable
        // SPUStandardUpdaterController + ed25519 signature verification.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "CodeIslandCore",
            path: "Sources/CodeIslandCore"
        ),
        // The aism ⇄ Meyrin input method wire constants, shared by the app and the input method bundle.
        .target(
            name: "MeilingIPC",
            path: "Sources/MeilingIPC"
        ),
        .executableTarget(
            name: "CodeIsland",
            dependencies: [
                "CodeIslandCore",
                "MeilingIPC",
                "MeilingSoftKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/CodeIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        // 美玲输入法 (luna-work spec 2026-10-24-meiling-design §6.1): bundled by scripts/build-meiling-ime.sh.
        .executableTarget(
            name: "MeilingInputMethod",
            dependencies: ["MeilingIPC"],
            path: "Sources/MeilingInputMethod",
            exclude: ["Info.plist", "InfoPlist.strings"]
        ),
        // 美玲 without the Tab5 (docs/meiling-soft-design.md): Gemini Live, mic, virtual mic, system audio tap.
        .target(
            name: "MeilingSoftKit",
            dependencies: ["CodeIslandCore"],
            path: "Sources/MeilingSoftKit"
        ),
        .executableTarget(
            name: "meiling-soft",
            dependencies: ["CodeIslandCore", "MeilingSoftKit"],
            path: "Sources/MeilingSoftCLI"
        ),
        .executableTarget(
            name: "meiling-sim",
            dependencies: ["CodeIslandCore"],
            path: "Sources/MeilingSim"
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIslandBridge"
        ),
        // Resets the xctest runner's shared defaults domain when a test
        // bundle loads (see Tests/TestDefaultsReset/TestDefaultsReset.c).
        .target(
            name: "TestDefaultsReset",
            path: "Tests/TestDefaultsReset"
        ),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore", "TestDefaultsReset"],
            path: "Tests/CodeIslandCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CodeIslandTests",
            dependencies: [
                "CodeIsland",
                "TestDefaultsReset",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/CodeIslandTests"
        ),
    ]
)
