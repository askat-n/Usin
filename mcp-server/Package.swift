// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "byeknow-mcp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "byeknow-mcp", path: "Sources/byeknow-mcp")
    ]
)
