import Foundation
import Testing
@testable import ShaderDebug

@Suite("pyshader.toml")
struct PyShaderTomlTests {
    @Test("sections, comments, arrays over several lines, # inside strings")
    func parse() {
        // PyShader's own ConfigTests input.
        let toml = PyShaderToml(parsing: """
            # shaders of this package
            site-packages = ".venv/lib/python3.13/site-packages"

            [clouds]
            source = "Shaders/clouds.py"   # a comment
            output = 'Resources/clouds.spv'
            target = "compute"
            content = true
            arguments = [
                "gain:float",   # one per line
                "tint:float4",
            ]

            ["plain.name"]
            source = "Shaders/#plasma.py"
            """)
        #expect(toml.sitePackages == ".venv/lib/python3.13/site-packages")
        #expect(toml.sections == [
            .init(name: "clouds", source: "Shaders/clouds.py", target: "compute", content: true, arguments: ["gain:float", "tint:float4"]),
            .init(name: "plain.name", source: "Shaders/#plasma.py", target: "fragment", content: false, arguments: []),
        ])
    }

    @Test("a shader's options come from the nearest pyshader.toml that lists it")
    func lookup() throws {
        let folder = try ShaderFolder([
            "pyshader.toml": "site-packages = \".venv/lib/python3.13/site-packages\"\n\n[ripple]\nsource = \"Sources/Pack/ripple.py\"\ntarget = \"graphics\"\narguments = [\"touches:floatArray\"]\n",
            "Sources/Pack/ripple.py": "",
            "Sources/Pack/other.py": "",
        ])
        defer { folder.remove() }
        let options = try #require(PyShaderToml.options(for: folder.file("Sources/Pack/ripple.py")))
        #expect(options.target == "graphics")
        #expect(options.arguments == ["touches:floatArray"])
        #expect(options.sitePackages?.standardizedFileURL.path == folder.file(".venv/lib/python3.13/site-packages").standardizedFileURL.path)
        #expect(PyShaderToml.options(for: folder.file("Sources/Pack/other.py")) == nil, "not listed")
    }

    @Test("no pyshader.toml anywhere above: nil, and the search ends at the root")
    func none() throws {
        let folder = try ShaderFolder(["a/b/shader.py": ""])
        defer { folder.remove() }
        #expect(PyShaderToml.options(for: folder.file("a/b/shader.py")) == nil)
    }
}
