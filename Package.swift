// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Nook", targets: ["Nook"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1")
    ],
    targets: [
        .executableTarget(name: "Nook", dependencies: ["SwiftTerm"]),
        .testTarget(name: "NookTests", dependencies: ["Nook"])
    ],
    swiftLanguageModes: [.v5]
)
