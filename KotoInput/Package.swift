// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KotoInput",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KotoCore", targets: ["KotoCore"]),
        .library(
            name: "AppleFoundationModelsProvider",
            targets: ["AppleFoundationModelsProvider"]
        ),
        .executable(name: "KotoInputMethod", targets: ["KotoInputMethod"]),
    ],
    targets: [
        .target(
            name: "KotoCore",
            path: "Packages/KotoCore/Sources"
        ),
        .target(
            name: "AppleFoundationModelsProvider",
            dependencies: ["KotoCore"],
            path: "Packages/AppleFoundationModelsProvider/Sources"
        ),
        .executableTarget(
            name: "KotoInputMethod",
            dependencies: ["KotoCore", "AppleFoundationModelsProvider"],
            path: "Apps/KotoInputMethod/Sources",
            // InputMethodKit の API は nonisolated な Objective-C 由来で、
            // Swift 6 の strict concurrency とは MainActor.assumeIsolated でも
            // 噛み合わせが粗いため、このターゲットのみ Swift 5 言語モード (ADR-0003)。
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KotoCoreTests",
            dependencies: ["KotoCore"],
            path: "Tests/KotoCoreTests",
            resources: [
                // 多言語品質フィクスチャ（Issue 36）。ディレクトリ構造ごと
                // バンドルへコピーし、Bundle.module から読む。
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "AppleFoundationModelsProviderTests",
            dependencies: ["AppleFoundationModelsProvider", "KotoCore"],
            path: "Tests/AppleFoundationModelsProviderTests"
        ),
    ]
)
