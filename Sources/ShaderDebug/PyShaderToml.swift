import Foundation

/// The parts of a package's `pyshader.toml` that say how to compile one of
/// its shaders: each section's `source`, `target`, `content` and
/// `arguments`, and the file's `site-packages`. Paths are relative to the
/// file. (PyShader's own reader is internal to it.)
public struct PyShaderToml: Sendable {
    public struct Section: Sendable, Equatable {
        public let name: String
        public let source: String
        public let target: String
        public let content: Bool
        public let arguments: [String]
    }

    public let sitePackages: String?
    public let sections: [Section]

    public init(parsing text: String) {
        var top: [String: String] = [:]
        var tables: [(name: String, keys: [String: String])] = []
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Self.stripComment(String($0)) }[...]
        while let first = lines.popFirst() {
            var line = first.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && !line.contains("=") {
                tables.append((Self.unquote(String(line.dropFirst().dropLast())), [:]))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            // An array may go on over the next lines until its `]`.
            while line.hasSuffix("[") || (line[eq...].contains("[") && !line[eq...].contains("]")), let next = lines.popFirst() {
                line += " " + next.trimmingCharacters(in: .whitespaces)
            }
            let key = Self.unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if tables.isEmpty { top[key] = value } else { tables[tables.count - 1].keys[key] = value }
        }
        sitePackages = top["site-packages"].map(Self.unquote)
        sections = tables.compactMap { table in
            guard let source = table.keys["source"].map(Self.unquote) else { return nil }
            let arguments = table.keys["arguments"].map { list in
                list.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",")
                    .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
            } ?? []
            return Section(name: table.name, source: source,
                           target: table.keys["target"].map(Self.unquote) ?? "fragment",
                           content: table.keys["content"] == "true", arguments: arguments)
        }
    }

    /// The compile options the nearest `pyshader.toml` above `file` gives it,
    /// when one lists it as a `source`.
    public static func options(for file: URL) -> CompileOptions? {
        let target = file.standardizedFileURL.path
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while true {
            let url = dir.appendingPathComponent("pyshader.toml")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let toml = PyShaderToml(parsing: text)
                if let section = toml.sections.first(where: { dir.appendingPathComponent($0.source).standardizedFileURL.path == target }) {
                    return CompileOptions(target: section.target, content: section.content, arguments: section.arguments,
                                          sitePackages: toml.sitePackages.map { dir.appendingPathComponent($0) })
                }
            }
            // Stop at the root by its path: the parent of `file:///` is `file:///../`.
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// The line up to a `#` that is not inside a string.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (i, c) in zip(line.indices, line) {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<i])
            }
        }
        return line
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" else { return t }
        return String(t.dropFirst().dropLast())
    }
}
