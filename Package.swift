// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EnvSetter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "EnvSetterCore", targets: ["EnvSetterCore"]),
        .library(name: "EnvSetterUI", targets: ["EnvSetterUI"]),
        .executable(name: "envsetter", targets: ["envsetter"]),
        .executable(name: "EnvSetterApp", targets: ["EnvSetterApp"]),
    ],
    targets: [
        .target(name: "EnvSetterCore"),
        .target(
            name: "EnvSetterUI",
            dependencies: ["EnvSetterCore"]
        ),
        .executableTarget(
            name: "envsetter",
            dependencies: ["EnvSetterCore"]
        ),
        .executableTarget(
            name: "EnvSetterApp",
            dependencies: ["EnvSetterCore", "EnvSetterUI"]
        ),
        .testTarget(
            name: "EnvSetterCoreTests",
            dependencies: ["EnvSetterCore"]
        ),
        .testTarget(
            name: "EnvSetterUITests",
            dependencies: ["EnvSetterCore", "EnvSetterUI"]
        ),
    ]
)
