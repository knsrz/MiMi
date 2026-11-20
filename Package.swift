// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Inkfolio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Inkfolio", targets: ["Inkfolio"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [.executableTarget(name: "Inkfolio", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/KaTeX")])]
)
