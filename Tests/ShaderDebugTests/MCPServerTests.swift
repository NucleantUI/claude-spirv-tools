import Foundation
import Testing
@testable import SpirvMCP

@Suite("MCP server")
struct MCPServerTests {
    let server = SpirvToolSet().server()

    func reply(_ message: String) throws -> JSONValue {
        let text = try #require(server.handle(line: message))
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func call(_ tool: String, _ arguments: JSONValue) throws -> (text: String, isError: Bool) {
        let request: JSONValue = ["jsonrpc": "2.0", "id": .number(3), "method": "tools/call",
                                  "params": ["name": .string(tool), "arguments": arguments]]
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let result = try #require(try reply(line)["result"])
        guard case .array(let content) = result["content"], let text = content.first?["text"]?.string else {
            Issue.record("no text content: \(result)")
            return ("", true)
        }
        return (text, result["isError"]?.bool ?? false)
    }

    @Test("initialize answers with the client's protocol version and the tools capability")
    func initialize() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(r["id"] == .number(1))
        #expect(r["result"]?["protocolVersion"] == "2025-06-18")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["serverInfo"]?["name"] == "spirv-tools")
    }

    @Test("notifications get no reply")
    func notification() {
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("tools/list names every tool with a schema")
    func list() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools) = r["result"]?["tools"] else {
            Issue.record("no tools: \(r)")
            return
        }
        let names = tools.compactMap { $0["name"]?.string }
        #expect(names == ["check", "functions", "disassemble", "interface", "optimize", "assemble"])
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })
    }

    @Test("unknown methods are JSON-RPC errors")
    func unknownMethod() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)
        #expect(r["error"]?["code"] == .number(-32601))
    }

    @Test("check, functions, disassemble, interface and optimize on a shader")
    func tools() throws {
        let folder = try ShaderFolder(["shade.py": shade, "tint.py": tint])
        defer { folder.remove() }
        let file = JSONValue.string(folder.file("shade.py").path)

        let check = try call("check", ["file": file, "output": .string(folder.file("shade.spv").path)])
        #expect(!check.isError)
        #expect(check.text.hasPrefix("OK: valid for vulkan1.0"), "\(check.text)")
        #expect(FileManager.default.fileExists(atPath: folder.file("shade.spv").path))

        let functions = try call("functions", ["file": file])
        #expect(functions.text.contains("shade.py:6"), "\(functions.text)")
        #expect(functions.text.contains("tint.py:5"))

        let disassembly = try call("disassemble", ["file": file, "function": "warm"])
        #expect(disassembly.text.contains("; tint.py:5: return float3(0.2, 0.1, 0.0) * sin(t)"), "\(disassembly.text)")

        let interface = try call("interface", ["file": .string(folder.file("shade.spv").path)])
        #expect(interface.text.contains("Entry points:"))

        let optimized = try call("optimize", ["file": file, "function": "main"])
        #expect(optimized.text.hasPrefix("-O: "), "\(optimized.text)")
        #expect(optimized.text.contains("valid"))
    }

    @Test("errors come back as tool errors")
    func toolErrors() throws {
        let missing = try call("check", ["file": "/no/such/shader.py"])
        #expect(missing.isError)
        #expect(missing.text.contains("no such file"))

        let folder = try ShaderFolder(["bad.py": "from pyshader import *\n\ndef main(uv: float2) -> float4:\n    return nope\n"])
        defer { folder.remove() }
        let bad = try call("check", ["file": .string(folder.file("bad.py").path)])
        #expect(bad.isError)
        #expect(bad.text.contains("bad.py:4: error:"), "\(bad.text)")

        let assembly = try call("assemble", ["text": "OpCapability Shader\nOpBogus\n"])
        #expect(assembly.isError)
        #expect(assembly.text.contains("line 2"), "\(assembly.text)")
    }
}
