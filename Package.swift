// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZnKeyboardCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "PinyinCore", targets: ["PinyinCore"])],
    targets: [
        .target(name: "PinyinCore", exclude: ["Resources"]),
        .executableTarget(name: "footprint", dependencies: ["PinyinCore"]),
        .executableTarget(name: "checks", dependencies: ["PinyinCore"]),
    ]
)
