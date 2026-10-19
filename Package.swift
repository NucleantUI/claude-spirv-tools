// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "claude-spirv-tools",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ShaderDebug",
            targets: ["ShaderDebug"]
        ),
        // The MCP server the plugin's .mcp.json starts.
        .executable(
            name: "spirv-mcp",
            targets: ["spirv-mcp"]
        ),
        // Compile + validate one file; the plugin's PostToolUse hook runs it.
        .executable(
            name: "spirv-check",
            targets: ["spirv-check"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/NucleantUI/PyShader.git", .upToNextMinor(from: "0.0.2")),
        .package(url: "https://github.com/NucleantUI/SpirvCore.git", .upToNextMinor(from: "0.0.1")),
        // SPIRV-Tools in Swift: validate, disassemble, assemble, optimize.
        .package(url: "https://github.com/NucleantUI/SpirvTools.git", .upToNextMinor(from: "0.0.1")),
    ],
    targets: [
        // A shader as a debugger sees it: compiled from PyShader or read from
        // a .spv, its instructions tied back to the Python lines.
        .target(
            name: "ShaderDebug",
            dependencies: [
                .product(name: "SpirvTools", package: "SpirvTools"),
                .product(name: "PyShader", package: "PyShader"),
                .product(name: "SpirvCore", package: "SpirvCore"),
            ]
        ),
        // The MCP protocol and the tools it serves, apart from stdio so tests
        // can drive it.
        .target(
            name: "SpirvMCP",
            dependencies: [
                "ShaderDebug",
                .product(name: "SpirvTools", package: "SpirvTools"),
            ]
        ),
        .executableTarget(
            name: "spirv-mcp",
            dependencies: ["SpirvMCP", "ShaderDebug"]
        ),
        .executableTarget(
            name: "spirv-check",
            dependencies: ["ShaderDebug"]
        ),
        .testTarget(
            name: "ShaderDebugTests",
            dependencies: ["ShaderDebug", "SpirvMCP"]
        ),
    ]
)
