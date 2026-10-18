//
//  spirv-check: compile a PyShader .py (or read a .spv) and validate it,
//  errors at their Python file:line.
//
//  usage: spirv-check <file> [--target fragment|compute|graphics] [--content]
//                     [--arg name:kind]... [--site-packages dir] [--target-env env]
//         spirv-check --hook
//
//  --hook is the plugin's PostToolUse hook: it reads the hook's JSON from
//  stdin, and when the edited file is a PyShader shader, checks it and exits 2
//  with the error on stderr (which Claude Code hands back to Claude), else 0.
//  A shader's target and arguments come from the nearest pyshader.toml that
//  lists it; without one, `def vertex` + `def fragment` is a graphics shader
//  and anything else with `def main` is tried as fragment, then compute.
//

import Foundation
import ShaderDebug
import SpirvTools

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    fail("usage: spirv-check <file> [--target fragment|compute|graphics] [--content] [--arg name:kind]... [--site-packages dir] [--target-env env]\n       spirv-check --hook", code: 2)
}

/// Checks the shader; the report and whether it passed.
func check(_ url: URL, options: [CompileOptions], environment: SpirvTargetEnvironment) -> (String, Bool) {
    let tools = SpirvContext(environment: environment)
    var firstError: Error?
    for option in options {
        do {
            let shader = try DebugShader(contentsOf: url, options: option)
            if let error = shader.validate(with: tools) {
                return ("spirv-val (\(environment)), compiled as \(option.target):\n\(error)", false)
            }
            return ("\(url.lastPathComponent): valid \(option.target) shader, \(shader.words.count) words", true)
        } catch {
            firstError = firstError ?? error
        }
    }
    return ("\(firstError.map { "\($0)" } ?? "nothing to check")", false)
}

// MARK: Hook

/// The hook's input: which tool ran, on which file.
struct HookInput: Decodable {
    struct ToolInput: Decodable {
        let file_path: String?
    }
    let tool_input: ToolInput?
}

func runHook() -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = try? JSONDecoder().decode(HookInput.self, from: data),
          let path = input.tool_input?.file_path,
          path.hasSuffix(".py") || path.hasSuffix(".spv") else { exit(0) }
    let url = URL(fileURLWithPath: path)
    // Not installed packages; their shaders are checked where they are written.
    guard !path.contains("/site-packages/"), !path.contains("/.venv/") else { exit(0) }

    var options: [CompileOptions]
    if url.pathExtension == "spv" {
        options = [CompileOptions()]
    } else {
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              source.contains("from pyshader") || source.contains("import pyshader") else { exit(0) }
        if let configured = PyShaderToml.options(for: url) {
            options = [configured]
        } else if source.contains("def vertex("), source.contains("def fragment(") {
            options = [CompileOptions(target: "graphics")]
        } else if source.contains("def main(") {
            options = [CompileOptions(target: "fragment"), CompileOptions(target: "compute")]
        } else {
            // A module of definitions for other shaders to import.
            exit(0)
        }
    }
    let (report, passed) = check(url, options: options, environment: .vulkan1_0)
    if passed { exit(0) }
    fail("PyShader check of \(path) failed:\n\(report)", code: 2)
}

// MARK: Command line

var args = Array(CommandLine.arguments.dropFirst())
// A hook runs on every edit, unattended: it gets less room, and a failure of
// its own lets the edit through (exit 0) rather than blocking it.
let limit = args == ["--hook"]
    ? MemoryLimit(megabytes: 1024, seconds: 20) { reason in
        FileHandle.standardError.write(Data("spirv-check: \(reason)\n".utf8))
        exit(0)
    }
    : MemoryLimit(megabytes: 2048, seconds: 60)
if args == ["--hook"] { runHook() }

var options = CompileOptions()
var environment = SpirvTargetEnvironment.vulkan1_0
var inputs: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--target":
        guard !args.isEmpty else { usage() }
        options.target = args.removeFirst()
    case "--content":
        options.content = true
    case "--arg":
        guard !args.isEmpty else { usage() }
        options.arguments.append(args.removeFirst())
    case "--site-packages":
        guard !args.isEmpty else { usage() }
        options.sitePackages = URL(fileURLWithPath: args.removeFirst())
    case "--target-env":
        guard !args.isEmpty, let env = SpirvTargetEnvironment(name: args.removeFirst()) else { usage() }
        environment = env
    default:
        if a.hasPrefix("-") { usage() }
        inputs.append(a)
    }
}
guard inputs.count == 1 else { usage() }
let (report, passed) = check(URL(fileURLWithPath: inputs[0]), options: [options], environment: environment)
if passed {
    print(report)
} else {
    fail(report)
}
