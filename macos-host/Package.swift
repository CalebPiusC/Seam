// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SeamHost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "seam-host", targets: ["SeamHost"])
    ],
    targets: [
        .executableTarget(
            name: "SeamHost",
            path: "Sources/SeamHost"
        )
    ]
)
