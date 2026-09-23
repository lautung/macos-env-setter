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
        .executable(name: "ScreenshotTool", targets: ["ScreenshotTool"]),
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
        // 只给 Scripts/make-screenshots.sh 用：离屏渲染真实视图出 README 截图。
        .executableTarget(
            name: "ScreenshotTool",
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
