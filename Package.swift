// swift-tools-version: 6.0


import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "BuildableKit",
    platforms: [
        .iOS(.v15), .macOS(.v13)
    ],
    products: [
        .library(name: "Buildable", targets: ["Buildable"]),
        .library(name: "BuildableMacros", targets: ["BuildableMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.2")
    ],
    targets: [
        // MARK: Runtime module
        .target(
            name: "Buildable",
            dependencies: ["BuildableMacros"]
        ),

        // MARK: Macro plugin
        .macro(
            name: "BuildableMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),

        // MARK: Tests
        .testTarget(
            name: "BuildableTests",
            dependencies: ["Buildable"]
        )
    ]
)
