// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacLink",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacLink", targets: ["MacLink"])],
    dependencies: [.package(url: "https://github.com/home-assistant/HAKit.git", exact: "0.4.18")],
    targets: [
        .target(name: "MacLinkCore"),
        .executableTarget(name: "MacLink", dependencies: ["MacLinkCore", .product(name: "HAKit", package: "HAKit")], resources:[.copy("Resources/Fonts")]),
        .testTarget(name: "MacLinkCoreTests", dependencies: ["MacLinkCore"])
    ],
    swiftLanguageModes: [.v5]
)
