// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "iphone-mirror-mcp",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "iphone-mirror", targets: ["iphone-mirror"]),
  ],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
  ],
  targets: [
    .target(name: "IPhoneMirrorCore"),
    .executableTarget(
      name: "iphone-mirror",
      dependencies: [
        "IPhoneMirrorCore",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(name: "IPhoneMirrorCoreTests", dependencies: ["IPhoneMirrorCore"]),
  ]
)
