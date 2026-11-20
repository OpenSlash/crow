// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowStatusNative",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CrowStatusNative",
            path: "Sources/CrowStatusNative",
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

