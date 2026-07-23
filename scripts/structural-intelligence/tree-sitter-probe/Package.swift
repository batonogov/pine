// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PineStructuralIntelligenceProbe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/tree-sitter/swift-tree-sitter",
            revision: "0f40435cdb41673ce4194d731571cf2a2f7c3285"
        ),
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift",
            revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"
        ),
    ],
    targets: [
        .executableTarget(
            name: "StructuralIntelligenceProbe",
            dependencies: [
                .product(
                    name: "SwiftTreeSitter",
                    package: "swift-tree-sitter"
                ),
                .product(
                    name: "TreeSitterSwift",
                    package: "tree-sitter-swift"
                ),
            ]
        ),
    ]
)
