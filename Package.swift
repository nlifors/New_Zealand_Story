// swift-tools-version: 6.0
import PackageDescription

let testingFlags: [SwiftSetting] = [
    .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
]

let package = Package(
    name: "NewZealandStory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "nzs-dump", targets: ["nzs-dump"]),
        .executable(name: "NewZealandStory", targets: ["NewZealandStory"]),
    ],
    targets: [
        .target(name: "M68K", swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .executableTarget(name: "m68k-sst", dependencies: ["M68K"], swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .target(name: "AmigaEmu", dependencies: ["M68K"], swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .target(name: "NZSCore"),
        .target(name: "NZSRecomp", dependencies: ["M68K"]),
        .executableTarget(name: "NewZealandStory", dependencies: ["NZSGame", "NZSCore", "AmigaEmu"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NZSGame", dependencies: ["M68K", "AmigaEmu", "NZSCore"], swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .executableTarget(name: "nzs-recomp", dependencies: ["NZSRecomp", "NZSCore"]),
        .executableTarget(name: "nzs-lockstep", dependencies: ["NZSGame", "NZSReference", "NZSCore", "AmigaEmu"]),
        .target(name: "NZSReference", dependencies: ["AmigaEmu", "NZSCore"]),
        .executableTarget(name: "nzs-ref", dependencies: ["NZSReference"]),
        .executableTarget(name: "nzs-dump", dependencies: ["NZSCore"]),
        .testTarget(name: "NZSCoreTests", dependencies: ["NZSCore"], swiftSettings: testingFlags),
        .testTarget(name: "ReferenceTests", dependencies: ["NZSReference", "NZSCore", "AmigaEmu", "NZSGame", "M68K"], swiftSettings: testingFlags),
    ]
)
