// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SVNDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SVNDesk", targets: ["SVNDesk"]), .library(name: "SVNCore", targets: ["SVNCore"])],
    targets: [
        .target(name: "SVNCore"),
        .executableTarget(name: "SVNDesk", dependencies: ["SVNCore"]),
        .testTarget(name: "SVNCoreTests", dependencies: ["SVNCore"])
    ]
)
