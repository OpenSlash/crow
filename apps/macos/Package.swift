// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("rnnoise"),
                .define("HAVE_CONFIG_H"),
                .define("FLOATING_POINT"),
                .define("CROW_RNNOISE_SCALAR"),
                .define("OPUS_BUILD")
            ]
        ),
        .executableTarget(
            name: "CrowMac",
            dependencies: ["CRNNoise"],
            path: "Sources/CrowMac",
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend", "-strict-concurrency=minimal",
                    "-Xfrontend", "-disable-actor-data-race-checks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
