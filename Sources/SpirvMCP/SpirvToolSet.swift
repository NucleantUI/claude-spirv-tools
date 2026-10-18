import Foundation
import ShaderDebug
import SpirvTools

/// The tools the plugin's MCP server offers. Each takes a `file`: a PyShader
/// `.py`, compiled with its Python lines in the module, or a `.spv`.
public final class SpirvToolSet {
    public init() {}

    public static let instructions = """
    SPIR-V tools for PyShader shaders and .spv modules, running SPIRV-Tools in process. \
    Point `file` at a PyShader .py (compiled with its Python lines kept, so errors and \
    disassembly point at Python source) or at a .spv. Start with `check`; narrow \
    `disassemble` to one `function` instead of reading the whole module.
    """

    public func server() -> MCPServer {
        MCPServer(name: "spirv-tools", version: "0.1.0", instructions: Self.instructions, tools: tools())
    }

    public func tools() -> [MCPTool] {
        [check, functions, disassemble, interface, optimize, assemble]
    }

    // MARK: Arguments

    static let fileProperties: [String: JSONValue] = [
        "file": ["type": "string", "description": "Path to a PyShader .py or a .spv module."],
        "target": ["type": "string", "enum": ["fragment", "compute", "graphics"],
                   "description": "For a .py: what to compile for, as pyshaderc --target. Default fragment."],
        "content": ["type": "boolean", "description": "For a .py: the shader samples the view's content (layer())."],
        "arguments": ["type": "array", "items": ["type": "string"],
                      "description": "For a .py: ShaderArguments as name:kind (float, float2, float3, float4, floatArray … float4Array)."],
        "site_packages": ["type": "string",
                          "description": "For a .py: site-packages to find imports in. Default: the nearest uv .venv's."],
        "target_env": ["type": "string", "description": "SPIR-V target environment, as spirv-val --target-env. Default vulkan1.0."],
    ]

    static func schema(_ extra: [String: JSONValue] = [:], required: [String] = ["file"]) -> JSONValue {
        ["type": "object",
         "properties": .object(fileProperties.merging(extra) { $1 }),
         "required": .array(required.map { .string($0) })]
    }

    static func shader(_ args: JSONValue) throws -> DebugShader {
        guard let path = args["file"]?.string else { throw ShaderDebugError("file is required") }
        let options = CompileOptions(
            target: args["target"]?.string ?? "fragment",
            content: args["content"]?.bool ?? false,
            arguments: args["arguments"]?.strings ?? [],
            sitePackages: args["site_packages"]?.string.map { URL(fileURLWithPath: expand($0)) }
        )
        return try DebugShader(contentsOf: URL(fileURLWithPath: expand(path)), options: options)
    }

    static func context(_ args: JSONValue) throws -> SpirvContext {
        guard let name = args["target_env"]?.string else { return SpirvContext() }
        guard let env = SpirvTargetEnvironment(name: name) else { throw ShaderDebugError("unknown target_env \(name)") }
        return SpirvContext(environment: env)
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func write(_ words: [UInt32], to path: String) throws {
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: URL(fileURLWithPath: expand(path)))
    }

    // MARK: Tools

    let check = MCPTool(
        name: "check",
        description: """
        Compile a PyShader .py (or read a .spv) and validate it with spirv-val's validator. \
        Reports a compile error or the first validation error at its Python file:line, \
        or a summary of the module: size, entry points, functions. Writes the module to `output` when given.
        """,
        inputSchema: schema(["output": ["type": "string", "description": "Where to write the compiled .spv."]])
    ) { args in
        let shader = try shader(args)
        let tools = try context(args)
        if let output = args["output"]?.string { try write(shader.words, to: output) }
        if let error = shader.validate(with: tools) {
            return "INVALID (\(tools.environment))\n\(error)"
        }
        let entries = shader.module.instructions.filter { $0.op == .opEntryPoint }.map { "\"\($0.string(at: 2).string)\"" }
        let functions = shader.functions().map(\.name)
        return """
        OK: valid for \(tools.environment), \(shader.words.count) words, bound \(shader.module.bound)
        entry points: \(entries.joined(separator: ", "))
        functions: \(functions.joined(separator: ", "))
        """
    }

    let functions = MCPTool(
        name: "functions",
        description: "List the module's functions: name, instruction count and the Python line each starts at.",
        inputSchema: schema()
    ) { args in
        let shader = try shader(args)
        return shader.functions().map { f in
            "\(f.name)  (\(f.range.count) instructions)" + (f.location.map { "  \($0.file):\($0.line)" } ?? "")
        }.joined(separator: "\n")
    }

    let disassemble = MCPTool(
        name: "disassemble",
        description: """
        Disassemble the module, or only `function` (a name, or the last part of a qualified \
        name). Each OpLine is shown as the Python line it marks, so the SPIR-V reads next \
        to the source. Prefer one function: a whole module is long.
        """,
        inputSchema: schema([
            "function": ["type": "string", "description": "Only this function."],
            "python_lines": ["type": "boolean", "description": "Show Python lines in place of OpLine. Default true."],
        ])
    ) { args in
        let shader = try shader(args)
        return try shader.disassembly(with: try context(args), function: args["function"]?.string,
                                      pythonLines: args["python_lines"]?.bool ?? true)
    }

    let interface = MCPTool(
        name: "interface",
        description: """
        The module's interface: entry points and execution modes, inputs and outputs by \
        location or builtin, descriptor sets and bindings, and push constant / buffer \
        block members by offset, with types spelled as PyShader writes them.
        """,
        inputSchema: schema()
    ) { args in
        try shader(args).interfaceReport()
    }

    let optimize = MCPTool(
        name: "optimize",
        description: """
        Run spirv-opt passes in process (default -O) and show the result: size before and \
        after, whether it still validates, and the disassembly (of `function` when given). \
        -O folds computations on constants, so it shows what an expression reduces to.
        """,
        inputSchema: schema([
            "flags": ["type": "array", "items": ["type": "string"],
                      "description": "spirv-opt flags: -O, -Os, --eliminate-dead-code-aggressive, --strip-debug, … Default [\"-O\"]."],
            "function": ["type": "string", "description": "Only disassemble this function."],
            "python_lines": ["type": "boolean", "description": "Show Python lines in place of OpLine. Default true."],
            "output": ["type": "string", "description": "Where to write the optimized .spv."],
        ])
    ) { args in
        let shader = try shader(args)
        let tools = try context(args)
        let flags = args["flags"]?.strings ?? ["-O"]
        let optimized = try tools.optimize(shader.words, flags: flags)
        if let output = args["output"]?.string { try write(optimized, to: output) }
        let result = try DebugShader(words: optimized, file: shader.file, sourceRoots: shader.sourceRoots)
        let validity = result.validate(with: tools).map { "INVALID after optimizing: \($0)" } ?? "valid"
        let text = try result.disassembly(with: tools, function: args["function"]?.string,
                                          pythonLines: args["python_lines"]?.bool ?? true)
        return """
        \(flags.joined(separator: " ")): \(shader.words.count) -> \(optimized.count) words, \(validity)

        \(text)
        """
    }

    let assemble = MCPTool(
        name: "assemble",
        description: """
        Assemble SPIR-V assembly text (as `disassemble` prints it, or hand-edited) and validate \
        it; writes the module to `output` when given. For trying a change to a module before \
        changing the compiler that produced it.
        """,
        inputSchema: ["type": "object",
                      "properties": [
                          "text": ["type": "string", "description": "The assembly text."],
                          "source": ["type": "string", "description": "A .spvasm file to read the text from instead."],
                          "output": ["type": "string", "description": "Where to write the .spv."],
                          "target_env": ["type": "string", "description": "Default vulkan1.0."],
                      ]]
    ) { args in
        let tools = try context(args)
        let text: String
        if let inline = args["text"]?.string {
            text = inline
        } else if let source = args["source"]?.string {
            text = try String(contentsOfFile: expand(source), encoding: .utf8)
        } else {
            throw ShaderDebugError("give text or source")
        }
        let words: [UInt32]
        do {
            words = try tools.assemble(text)
        } catch let error as SpirvDiagnostic {
            throw ShaderDebugError("line \(error.line + 1), column \(error.column + 1): \(error.message)")
        }
        if let output = args["output"]?.string { try write(words, to: output) }
        let shader = try DebugShader(words: words)
        if let error = shader.validate(with: tools) {
            return "assembled \(words.count) words; INVALID (\(tools.environment))\n\(error)"
        }
        return "assembled \(words.count) words; valid for \(tools.environment)"
    }
}
