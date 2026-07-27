// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixShell",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "PixShell",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/PixShell",
            resources: [
                .process("Resources")
            ]
        ),
    ],
    // 顶层 NSApplication 全局用 Swift 5 语义，避开 Swift 6 严格并发误报
    swiftLanguageModes: [.v5]
)
