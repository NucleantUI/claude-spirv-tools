import Foundation
import PyShader
import SpirvCore
import SpirvTools

/// Something that went wrong getting a shader to look at: a file that is not
/// there, a module that does not parse, a PyShader compile error.
public struct ShaderDebugError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A Python line an instruction came from.
public struct SourceLocation: Sendable, Equatable, CustomStringConvertible {
    /// The file as the module names it: the shader's own name, or an imported
    /// module's path (`shapes/star.py`, `pyshader/stdlib/fragment/sdf.py`).
    public let file: String
    public let line: Int
    /// The line's text, when the file could be found.
    public let text: String?

    public var description: String {
        guard let text else { return "\(file):\(line)" }
        return "\(file):\(line): \(text.trimmingCharacters(in: .whitespaces))"
    }
}

/// How to compile a PyShader file: the target and its ShaderArguments, as
/// `pyshaderc`'s options give them.
public struct CompileOptions: Sendable {
    /// `fragment`, `compute` or `graphics`.
    public var target: String
    /// Whether the shader samples the view's content (`layer()`).
    public var content: Bool
    /// ShaderArguments as `name:kind`, kind `float` … `float4Array`.
    public var arguments: [String]
    /// The site-packages imports are looked up in; nil for the nearest uv `.venv`'s.
    public var sitePackages: URL?

    public init(target: String = "fragment", content: Bool = false, arguments: [String] = [], sitePackages: URL? = nil) {
        self.target = target
        self.content = content
        self.arguments = arguments
        self.sitePackages = sitePackages
    }

    func shaderTarget() throws -> ShaderTarget {
        var parsed: [(name: String, kind: ShaderArgumentKind)] = []
        for spec in arguments {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = Self.kinds[parts[1]] else {
                throw ShaderDebugError("argument \(spec) is not name:kind (kinds: \(Self.kinds.keys.sorted().joined(separator: ", ")))")
            }
            parsed.append((parts[0], kind))
        }
        switch target {
        case "fragment": return .nucleant
        case "compute": return .computeImage(.nucleantUI(samplesContent: content, arguments: parsed))
        case "graphics": return .graphics(.nucleantUI(samplesContent: content, arguments: parsed))
        default: throw ShaderDebugError("target \(target) is not fragment, compute or graphics")
        }
    }

    static let kinds: [String: ShaderArgumentKind] = [
        "float": .float, "float2": .float2, "float3": .float3, "float4": .float4,
        "floatArray": .floatArray, "float2Array": .float2Array,
        "float3Array": .float3Array, "float4Array": .float4Array,
    ]
}

/// A SPIR-V module as a debugger looks at it: its instructions, the Python
/// line each came from (PyShader's `OpLine`s), and its functions by name.
public final class DebugShader {
    /// The module, magic first.
    public let words: [UInt32]
    public let module: SpirvModuleReader
    /// The file it was read or compiled from.
    public let file: URL?
    /// Where the files its `OpLine`s name are looked up.
    public let sourceRoots: [URL]

    /// The `OpLine` in effect at each instruction, by instruction index.
    private let lines: [(file: UInt32, line: Int)?]
    private let strings: [UInt32: String]
    private let names: [UInt32: String]
    private var sourceCache: [String: [Substring]?] = [:]

    /// A module as it is, its source files looked up in `sourceRoots`.
    public init(words: [UInt32], file: URL? = nil, sourceRoots: [URL] = []) throws {
        do {
            module = try SpirvModuleReader(words: words)
        } catch {
            throw ShaderDebugError("\(file?.path ?? "module"): \(error)")
        }
        self.words = words
        self.file = file
        self.sourceRoots = sourceRoots

        var strings: [UInt32: String] = [:]
        var names: [UInt32: String] = [:]
        var lines: [(file: UInt32, line: Int)?] = []
        var current: (file: UInt32, line: Int)?
        for inst in module.instructions {
            switch inst.op {
            case .opString:
                strings[inst.operands[0]] = inst.string(at: 1).string
            case .opName:
                names[inst.operands[0]] = inst.string(at: 1).string
            case .opLine:
                current = (inst.operands[0], Int(inst.operands[1]))
            case .opNoLine, .opFunction, .opFunctionEnd:
                current = nil
            default:
                break
            }
            lines.append(current)
        }
        self.strings = strings
        self.names = names
        self.lines = lines
    }

    /// Reads a `.spv` file; source files are looked up next to it.
    public convenience init(spirv url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ShaderDebugError("cannot read \(url.path): \(error.localizedDescription)")
        }
        let reader: SpirvModuleReader
        do {
            reader = try SpirvModuleReader(data: data)
        } catch {
            throw ShaderDebugError("\(url.path): \(error)")
        }
        try self.init(words: reader.words, file: url, sourceRoots: [url.deletingLastPathComponent()])
    }

    /// Compiles a PyShader file, with its lines in the module.
    public convenience init(python url: URL, options: CompileOptions = .init()) throws {
        let target = try options.shaderTarget()
        var roots = [url.deletingLastPathComponent()]
        if let sitePackages = options.sitePackages ?? Self.nearestSitePackages(above: url) { roots.append(sitePackages) }
        let shader: CompiledShader
        do {
            shader = try PyShader.compile(contentsOf: url, target: target, modules: options.sitePackages)
        } catch let error as PyShaderError {
            throw ShaderDebugError(Self.describe(error, in: url, roots: roots))
        } catch {
            throw ShaderDebugError("\(url.path): \(error)")
        }
        try self.init(words: shader.spirv, file: url, sourceRoots: roots)
    }

    /// A `.py` compiled, anything else read as SPIR-V.
    public convenience init(contentsOf url: URL, options: CompileOptions = .init()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ShaderDebugError("no such file: \(url.path)") }
        if url.pathExtension == "py" {
            try self.init(python: url, options: options)
        } else {
            try self.init(spirv: url)
        }
    }

    // MARK: Source lines

    /// The Python line instruction `index` (0-based, into `module.instructions`) came from.
    public func location(ofInstruction index: Int) -> SourceLocation? {
        guard lines.indices.contains(index), let (fileId, line) = lines[index] else { return nil }
        let name = strings[fileId] ?? "<string \(fileId)>"
        return SourceLocation(file: name, line: line, text: sourceLine(line, of: name))
    }

    private func sourceLine(_ line: Int, of name: String) -> String? {
        if sourceCache[name] == nil {
            sourceCache[name] = sourceRoots.lazy
                .map { $0.appendingPathComponent(name) }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .first
                .map { $0.split(separator: "\n", omittingEmptySubsequences: false) }
        }
        guard let file = sourceCache[name] ?? nil, file.indices.contains(line - 1) else { return nil }
        return String(file[line - 1])
    }

    /// The name `OpName` gives an id.
    public func name(of id: UInt32) -> String? { names[id] }

    // MARK: Validation

    /// A validation error, with the Python line of the instruction it is about.
    public struct ValidationError: Sendable, CustomStringConvertible {
        public let diagnostic: SpirvDiagnostic
        public let location: SourceLocation?

        public var description: String {
            guard let location else { return diagnostic.message }
            return "\(location.file):\(location.line): error: \(diagnostic.message)" +
                (location.text.map { "\n    \($0.trimmingCharacters(in: .whitespaces))" } ?? "")
        }
    }

    /// Validates the module; nil when it is valid.
    public func validate(with tools: SpirvContext) -> ValidationError? {
        guard let diagnostic = tools.validate(words) else { return nil }
        return ValidationError(diagnostic: diagnostic, location: location(ofInstruction: diagnostic.instruction - 1))
    }

    // MARK: Functions

    /// A function in the module: its name and where it is in the instructions.
    public struct Function: Sendable {
        public let id: UInt32
        public let name: String
        /// Instruction indices from `OpFunction` to `OpFunctionEnd`.
        public let range: ClosedRange<Int>
        /// The first Python line in it.
        public let location: SourceLocation?
    }

    public func functions() -> [Function] {
        var out: [Function] = []
        var start: (index: Int, id: UInt32)?
        for (i, inst) in module.instructions.enumerated() {
            if inst.op == .opFunction {
                start = (i, inst.operands[1])
            } else if inst.op == .opFunctionEnd, let s = start {
                let first = (s.index...i).first { lines[$0] != nil }
                out.append(Function(id: s.id, name: names[s.id] ?? "%\(s.id)", range: s.index...i,
                                    location: first.flatMap(location(ofInstruction:))))
                start = nil
            }
        }
        return out
    }

    /// The functions named `name`, exactly or as the last part of a qualified
    /// name (`star` finds `shapes.star.star`).
    public func functions(named name: String) -> [Function] {
        functions().filter { $0.name == name || $0.name.hasSuffix(".\(name)") }
    }

    // MARK: Disassembly

    /// The module as assembly text: all of it, or only the functions named
    /// `function`. With `pythonLines`, each `OpLine` is replaced by a comment
    /// with the Python line it marks.
    public func disassembly(with tools: SpirvContext, function: String? = nil, pythonLines: Bool = true) throws -> String {
        // One line per instruction: no header, no comments.
        let text = try tools.disassemble(words, options: [.friendlyNames, .indent, .noHeader])
        var textLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if textLines.last == "" { textLines.removeLast() }
        guard textLines.count == module.instructions.count else {
            // Should not happen; fall back to the text as it is.
            return text
        }

        let ranges: [ClosedRange<Int>]
        if let function {
            ranges = functions(named: function).map(\.range)
            guard !ranges.isEmpty else {
                let known = functions().map(\.name).joined(separator: ", ")
                throw ShaderDebugError("no function \(function); the module has: \(known)")
            }
        } else {
            ranges = [0...(module.instructions.count - 1)]
        }

        var out: [String] = []
        for range in ranges {
            if !out.isEmpty { out.append("") }
            for i in range {
                if pythonLines, module.instructions[i].op == .opLine {
                    if let location = location(ofInstruction: i) { out.append("; \(location)") }
                    continue
                }
                out.append(String(textLines[i]))
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Helpers

    /// `file:line: error: message` and the line, the file an imported module's
    /// found in `roots` (the shader's folder, then site-packages).
    static func describe(_ error: PyShaderError, in url: URL, roots: [URL]) -> String {
        guard let line = error.line else { return "\(url.path): error: \(error.message)" }
        let file = error.file.map { name in
            roots.map { $0.appendingPathComponent(name).path }.first { FileManager.default.fileExists(atPath: $0) } ?? name
        } ?? url.path
        var text = "\(file):\(line): error: \(error.message)"
        if let source = try? String(contentsOfFile: file, encoding: .utf8) {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.indices.contains(line - 1) { text += "\n    \(lines[line - 1].trimmingCharacters(in: .whitespaces))" }
        }
        return text
    }

    /// `.venv/lib/python3.*/site-packages` of the nearest directory above `url` that has one.
    static func nearestSitePackages(above url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            let lib = dir.appendingPathComponent(".venv/lib")
            if let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib.path) {
                for python in pythons.sorted() where python.hasPrefix("python") {
                    let site = lib.appendingPathComponent(python).appendingPathComponent("site-packages")
                    if FileManager.default.fileExists(atPath: site.path) { return site }
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
