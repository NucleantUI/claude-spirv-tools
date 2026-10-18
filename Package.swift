// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "claude-spirv-tools",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SpirvTools",
            targets: ["SpirvTools"]
        ),
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
    ],
    targets: [
        // SPIRV-Tools built from source by scripts/build_spirv_tools.py:
        // static libraries and the C API (spirv-tools/libspirv.h).
        .binaryTarget(
            name: "CSpirvTools",
            path: "Dependencies/CSpirvTools.xcframework"
        ),
        // Swift over the C API: validate, disassemble, assemble, optimize.
        .target(
            name: "SpirvTools",
            dependencies: ["CSpirvTools"]
        ),
        // A shader as a debugger sees it: compiled from PyShader or read from
        // a .spv, its instructions tied back to the Python lines.
        .target(
            name: "ShaderDebug",
            dependencies: [
                "SpirvTools",
                .product(name: "PyShader", package: "PyShader"),
                .product(name: "SpirvCore", package: "SpirvCore"),
            ]
        ),
        // The MCP protocol and the tools it serves, apart from stdio so tests
        // can drive it.
        .target(
            name: "SpirvMCP",
            dependencies: ["ShaderDebug", "SpirvTools"]
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
            name: "SpirvToolsTests",
            dependencies: ["SpirvTools"]
        ),
        .testTarget(
            name: "ShaderDebugTests",
            dependencies: ["ShaderDebug", "SpirvMCP"]
        ),
    ]
)
