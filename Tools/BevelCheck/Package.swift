// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "BevelCheck", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Packages/WhoopProtocol"), .package(path: "../../Packages/WhoopStore")],
    targets: [.executableTarget(name: "BevelCheck", dependencies: ["WhoopProtocol", "WhoopStore"],
                                path: ".", sources: ["main.swift"])])
