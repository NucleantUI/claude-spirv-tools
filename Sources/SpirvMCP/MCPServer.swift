import Foundation

/// A tool the server offers: its name, what it is for, the arguments it
/// takes (a JSON schema), and what it does with them.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// Returns the text result; a thrown error is reported to the client as a
    /// tool error (`isError`), not a protocol error.
    public let run: @Sendable (JSONValue) throws -> String

    public init(name: String, description: String, inputSchema: JSONValue, run: @escaping @Sendable (JSONValue) throws -> String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }
}

/// The Model Context Protocol's server side, as much of it as a tools-only
/// server needs: `initialize`, `ping`, `tools/list` and `tools/call`, one
/// JSON-RPC message per line (the stdio transport).
public final class MCPServer {
    public let name: String
    public let version: String
    public let instructions: String?
    private let tools: [MCPTool]

    /// The protocol versions this server speaks, newest first.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// Serves stdin to stdout until stdin closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// The reply to one message; nil for a notification.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return encode(["jsonrpc": "2.0", "id": .null, "error": ["code": .number(-32700), "message": "parse error"]])
        }
        // A notification has no id and gets no reply.
        guard let id = message["id"], id != .null else { return nil }
        let method = message["method"]?.string ?? ""
        let params = message["params"] ?? [:]

        let result: JSONValue
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.protocolVersions[0]
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            var info: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { info["instructions"] = .string(instructions) }
            result = .object(info)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            })]
        case "tools/call":
            let toolName = params["name"]?.string ?? ""
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                return error(id: id, code: -32602, message: "unknown tool \(toolName)")
            }
            do {
                let text = try tool.run(params["arguments"] ?? [:])
                result = ["content": [["type": "text", "text": .string(text)]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
            }
        default:
            return error(id: id, code: -32601, message: "method not found: \(method)")
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(id: JSONValue, code: Double, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(code), "message": .string(message)]])
    }

    private func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}
