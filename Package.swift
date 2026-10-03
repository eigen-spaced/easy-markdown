// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EasyMarkdown",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EasyMarkdown",
            path: "Sources/EasyMarkdown"
        )
    ]
)
