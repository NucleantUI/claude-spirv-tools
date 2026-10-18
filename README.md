# claude-spirv-tools

A Claude Code plugin for working with SPIR-V and PyShader. Its tools run
[SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) in process, and they
read PyShader's `OpLine`s, so errors and disassembly point at Python source.

The plugin has three parts:

- **The MCP server** `spirv` (`bin/spirv-mcp`), with the tools below.
- **A PostToolUse hook.** After every Edit or Write to a PyShader shader, it
  compiles the shader and validates the SPIR-V. Errors go back to Claude at
  their Python lines.
- **The skill** `spirv-debugging`, which covers when to use the tools and how to
  read PyShader's SPIR-V.

The server stops itself at 2 GB of memory. The hook stops at 1 GB or 20
seconds, and when it does, it lets the edit through.

## Install

The binaries aren't released yet, so build them in your clone first (see
[Building](#building)), then add the clone as a marketplace:

```sh
git clone https://github.com/NucleantUI/claude-spirv-tools
cd claude-spirv-tools
uv run scripts/build_spirv_tools.py && swift build -c release
```

```
/plugin marketplace add /path/to/claude-spirv-tools
/plugin install spirv-tools@nucleantui-spirv
```

Claude Code runs an installed plugin from a copy under `~/.claude/plugins/cache`.
That copy may lack the clone's `.build`, so point the launchers at the clone's
build in `~/.claude/settings.json`:

```json
{ "env": { "SPIRV_TOOLS_BUILD": "/path/to/claude-spirv-tools/.build/release" } }
```

`bin/spirv-mcp` and `bin/spirv-check` look in `$SPIRV_TOOLS_BUILD` first, then in
the plugin's own `.build/release`. If neither has a build, the server prints the
build command and exits, and the hook does nothing.

## Tools

The MCP server (`spirv-mcp`) offers these tools. Each one takes a `file`: either
a PyShader `.py`, compiled with its Python lines kept, or a `.spv`.

| Tool | What it does |
|---|---|
| `check` | Compile and validate. Reports a compile error or the first validation error at its Python `file:line`, or else a summary of the module. Can write the `.spv`. |
| `functions` | The module's functions: name, instruction count, and the Python line each one starts at. |
| `disassemble` | The module, or one function, with each `OpLine` replaced by the Python line it marks. |
| `interface` | Entry points and execution modes, inputs and outputs, descriptor bindings, and push constant and buffer block members by offset. |
| `optimize` | Runs `spirv-opt` passes (default `-O`), then shows the sizes before and after, whether the result still validates, and the result's disassembly. |
| `assemble` | Assembles SPIR-V text, for instance hand-edited disassembly, and validates it. |

For a `.py`, a tool can also take `target` (`fragment`, `compute` or `graphics`),
`content`, `arguments` (`name:kind`) and `site_packages`, as `pyshaderc` does.
Any tool can take `target_env`, which defaults to `vulkan1.0`.

`spirv-check <file> [--target …] [--arg …]` compiles and validates from the command
line. With `--hook`, it reads a Claude Code PostToolUse hook's JSON on stdin and
checks the PyShader file that was edited. It finds the shader's target and
arguments in the nearest `pyshader.toml` that lists the shader.

## Building

SPIRV-Tools is built from source, because Homebrew no longer builds it for Intel
Macs. The binary target, `Dependencies/CSpirvTools.xcframework`, comes from:

```sh
uv run scripts/build_spirv_tools.py   # SPIRV-Tools + SPIRV-Headers vulkan-sdk-1.4.363.0, macOS arm64 + x86_64
swift build -c release   # bin/spirv-mcp and bin/spirv-check run the release build
```

The script needs `cmake`, `ninja` and Xcode, and it builds macOS only for now.
Releases will ship the xcframework as a release archive, the way NucleantVulkan
ships its dependencies.

## Packages

| Target | What it is |
|---|---|
| `SpirvTools` | Swift over SPIRV-Tools' C API: validate, disassemble, assemble, optimize. |
| `ShaderDebug` | A module as a debugger sees it: compiled from PyShader or read from a `.spv`, its instructions tied to Python lines, its functions and interface. |
| `SpirvMCP` | The MCP protocol (stdio JSON-RPC) and the tools above. |
| `spirv-mcp`, `spirv-check` | The executables. |

## License

MIT; see [LICENSE](LICENSE). SPIRV-Tools is under the Apache 2.0 license, and
SPIRV-Headers is under Khronos' MIT-style license. Both are built from source and
are not part of this repository.
