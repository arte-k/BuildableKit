// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

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
        .target(name: "Buildable"),
        .macro(
            name: "BuildableMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),

        // Tests (optional but recommended)
//        .testTarget(
//            name: "BuildableTests",
//            dependencies: ["Buildable", "BuildableMacros"]
//        ),
//        .testTarget(
//            name: "BuildableMacrosTests",
//            dependencies: [
//                "BuildableMacros",
//                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
//            ]
//        )
    ]
)
