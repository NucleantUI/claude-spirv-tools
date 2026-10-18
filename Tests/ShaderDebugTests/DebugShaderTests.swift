import Foundation
import Testing
import SpirvTools
@testable import ShaderDebug

/// A folder of PyShader files for one test, removed after it.
final class ShaderFolder {
    let url: URL

    init(_ files: [String: String]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("spirv-tools-\(UUID().uuidString)")
        for (name, text) in files {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Deletes the folder; each test defers it, so the files outlive every read.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

let shade = """
from pyshader import *
from tint import warm


def shade(t: float) -> float3:
    c = float3(t)
    return c * 0.5


def main(uv: float2, time: float) -> float4:
    x = uv.x
    if x > 0.5:
        x = 1.0 - x
    return float4(shade(x) + warm(time), 1.0)
"""

let tint = """
from pyshader import *


def warm(t: float) -> float3:
    return float3(0.2, 0.1, 0.0) * sin(t)
"""

@Suite("DebugShader")
struct DebugShaderTests {
    let tools = SpirvContext()

    func compiled() throws -> (ShaderFolder, DebugShader) {
        let folder = try ShaderFolder(["shade.py": shade, "tint.py": tint])
        return (folder, try DebugShader(contentsOf: folder.file("shade.py")))
    }

    @Test("a compiled shader validates and lists its functions with their Python lines")
    func functions() throws {
        let (folder, shader) = try compiled()
        defer { folder.remove() }
        #expect(shader.validate(with: tools) == nil)
        let functions = shader.functions()
        let shadeFunction = try #require(functions.first { $0.name == "shade" })
        #expect(shadeFunction.location == SourceLocation(file: "shade.py", line: 6, text: "    c = float3(t)"))
        let warm = try #require(shader.functions(named: "warm").first)
        #expect(warm.location?.file == "tint.py", "an imported function's lines are in its own file")
        #expect(warm.location?.text?.contains("sin(t)") == true)
    }

    @Test("a function's disassembly has its Python lines in place of OpLine")
    func disassembly() throws {
        let (folder, shader) = try compiled()
        defer { folder.remove() }
        let text = try shader.disassembly(with: tools, function: "shade")
        #expect(text.contains("; shade.py:6: c = float3(t)"))
        #expect(text.contains("; shade.py:7: return c * 0.5"))
        #expect(!text.contains("OpLine"))
        #expect(!text.contains("OpEntryPoint"), "only the function")
        #expect(text.hasPrefix("%shade = OpFunction") || text.contains("= OpFunction"))
    }

    @Test("an unknown function lists the ones there are")
    func unknownFunction() throws {
        let (folder, shader) = try compiled()
        defer { folder.remove() }
        let error = try #require(throws: ShaderDebugError.self) { try shader.disassembly(with: tools, function: "nope") }
        #expect(error.message.contains("shade"))
    }

    @Test("a validation error points at the Python line of its instruction")
    func validationLine() throws {
        let (folder, shader) = try compiled()
        defer { folder.remove() }
        // Break `c * 0.5` (line 7): give its result a vector type of the wrong size.
        let text = try tools.disassemble(shader.words, options: [.friendlyNames])
        let lines = text.split(separator: "\n").map(String.init)
        let index = try #require(lines.firstIndex { $0.contains("OpVectorTimesScalar %v3float") })
        var broken = lines
        broken[index] = broken[index].replacingOccurrences(of: "OpVectorTimesScalar %v3float", with: "OpVectorTimesScalar %v4float")
        let words = try tools.assemble(broken.joined(separator: "\n"))
        let bad = try DebugShader(words: words, sourceRoots: [folder.url])
        let error = try #require(bad.validate(with: tools))
        #expect(error.location?.file == "shade.py")
        #expect(error.location?.line == 7)
        #expect(error.description.hasPrefix("shade.py:7: error:"))
        #expect(error.description.contains("return c * 0.5"))
    }

    @Test("a compile error is reported at its file and line")
    func compileError() throws {
        let folder = try ShaderFolder(["bad.py": "from pyshader import *\n\ndef main(uv: float2) -> float4:\n    return float4(nope, 1.0)\n"])
        defer { folder.remove() }
        let error = try #require(throws: ShaderDebugError.self) { try DebugShader(contentsOf: folder.file("bad.py")) }
        #expect(error.message.contains("bad.py:4: error:"), "\(error)")
        #expect(error.message.contains("return float4(nope, 1.0)"))
    }

    @Test("the interface report lists entry point, outputs and push constants")
    func interface() throws {
        let (folder, shader) = try compiled()
        defer { folder.remove() }
        let report = shader.interfaceReport()
        #expect(report.contains("fragment \"main\""), "\(report)")
        #expect(report.contains("Outputs:"))
        #expect(report.contains("location 0"))
        #expect(report.contains("float4"))
    }

    @Test("a graphics shader has both stages and their varyings")
    func graphicsInterface() throws {
        let folder = try ShaderFolder(["quad.py": """
        from pyshader import *


        class Varyings:
            position: float4
            shade: float


        def vertex(vertex_index: int) -> Varyings:
            x = float(vertex_index % 2)
            return Varyings(float4(x, 0.0, 0.0, 1.0), shade=x)


        def fragment(shade: float) -> float4:
            return float4(shade)
        """])
        defer { folder.remove() }
        let shader = try DebugShader(contentsOf: folder.file("quad.py"), options: CompileOptions(target: "graphics"))
        #expect(shader.validate(with: tools) == nil)
        let report = shader.interfaceReport()
        #expect(report.contains("vertex \""), "\(report)")
        #expect(report.contains("fragment \""))
        #expect(report.contains("builtin position") || report.contains("builtin Position"), "\(report)")
    }

    @Test("bad compile options are errors, not crashes")
    func badOptions() throws {
        let (folder, _) = try compiled()
        defer { folder.remove() }
        #expect(throws: ShaderDebugError.self) {
            try DebugShader(contentsOf: folder.file("shade.py"), options: CompileOptions(target: "geometry"))
        }
        #expect(throws: ShaderDebugError.self) {
            try DebugShader(contentsOf: folder.file("shade.py"), options: CompileOptions(target: "compute", arguments: ["x:float5"]))
        }
    }
}
