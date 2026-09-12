// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EnvSetter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "EnvSetterCore", targets: ["EnvSetterCore"]),
        .executable(name: "envsetter", targets: ["envsetter"]),
    ],
    targets: [
        .target(name: "EnvSetterCore"),
        .executableTarget(
            name: "envsetter",
            dependencies: ["EnvSetterCore"]
        ),
        .testTarget(
            name: "EnvSetterCoreTests",
            dependencies: ["EnvSetterCore"]
        ),
    ]
)
