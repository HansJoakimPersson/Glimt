// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InspectorCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "InspectorCore", targets: ["InspectorCore"]),
        .library(name: "GitInspection", targets: ["GitInspection"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/2389-research/MermaidKit.git", exact: "2.10.2")
    ],
    targets: [
        .target(name: "InspectorCore", dependencies: [
            .product(name: "Yams", package: "Yams"),
            .product(name: "MermaidLayout", package: "MermaidKit"),
            "CSQLite",
            "CZlib",
            "CZlibRuntime"
        ], resources: [.process("Resources")]),
        .target(name: "GitInspection", dependencies: ["InspectorCore", "CZlib"]),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "CZlibRuntime", dependencies: ["CZlib"], path: "Sources/CZlibRuntime"),
        .testTarget(
            name: "InspectorCoreTests",
            dependencies: ["InspectorCore", "CSQLite"],
            path: "Tests",
            exclude: ["GitInspectionTests"],
            sources: ["InspectorCoreTests"]
        ),
        .testTarget(
            name: "GitInspectionTests",
            dependencies: ["GitInspection", "InspectorCore"],
            path: "Tests/GitInspectionTests"
        )
    ]
)
