// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "envsetter-ui-prototype",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EnvSetterPrototype",
            path: "Sources/EnvSetterPrototype"
        )
    ]
)
