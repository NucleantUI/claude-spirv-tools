import Testing
@testable import SpirvTools

/// A fragment shader writing a constant color, with one dead computation.
let fragment = """
               OpCapability Shader
               OpMemoryModel Logical GLSL450
               OpEntryPoint Fragment %main "main" %color
               OpExecutionMode %main OriginUpperLeft
               OpName %main "main"
               OpName %color "color"
               OpDecorate %color Location 0
       %void = OpTypeVoid
         %fn = OpTypeFunction %void
      %float = OpTypeFloat 32
     %float4 = OpTypeVector %float 4
%_ptr_Output_float4 = OpTypePointer Output %float4
      %color = OpVariable %_ptr_Output_float4 Output
        %one = OpConstant %float 1
       %half = OpConstant %float 0.5
       %main = OpFunction %void None %fn
      %entry = OpLabel
        %sum = OpFAdd %float %one %half
      %value = OpCompositeConstruct %float4 %sum %half %half %one
               OpStore %color %value
               OpReturn
               OpFunctionEnd
"""

@Suite("SpirvContext")
struct SpirvContextTests {
    let tools = SpirvContext()

    @Test("assembles and validates a module")
    func validModule() throws {
        let words = try tools.assemble(fragment)
        #expect(words[0] == 0x0723_0203)
        #expect(tools.validate(words) == nil)
    }

    @Test("names the instruction a validation error is about")
    func invalidModule() throws {
        // Floats added into a vector: OpFAdd, the 18th instruction after the header.
        let bad = fragment.replacingOccurrences(of: "OpFAdd %float %one %half", with: "OpFAdd %float4 %one %half")
        let words = try tools.assemble(bad)
        let diagnostic = try #require(tools.validate(words))
        #expect(diagnostic.message.contains("OpFAdd"))
        #expect(diagnostic.instruction == 18, "\(diagnostic)")
    }

    @Test("an assembly error has its line")
    func assemblyError() throws {
        let error = try #require(throws: SpirvDiagnostic.self) { try tools.assemble("OpCapability Shader\nOpNotAThing\n") }
        #expect(error.line == 1)
    }

    @Test("disassembles with friendly names")
    func disassemble() throws {
        let text = try tools.disassemble(try tools.assemble(fragment), options: [.friendlyNames, .noHeader])
        #expect(text.contains("%main = OpFunction"))
        #expect(!text.contains("; SPIR-V"))
    }

    @Test("-O folds the constant addition")
    func optimize() throws {
        let words = try tools.assemble(fragment)
        let optimized = try tools.optimize(words, flags: ["-O"])
        #expect(tools.validate(optimized) == nil)
        let text = try tools.disassemble(optimized, options: [.noHeader])
        #expect(!text.contains("OpFAdd"))
        #expect(text.contains("1.5"))
    }

    @Test("an unknown optimizer flag throws")
    func unknownFlag() throws {
        let words = try tools.assemble(fragment)
        #expect(throws: SpirvDiagnostic.self) { try tools.optimize(words, flags: ["--no-such-pass"]) }
    }

    @Test("target environments parse by name")
    func environments() {
        #expect(SpirvTargetEnvironment(name: "vulkan1.3") != nil)
        #expect(SpirvTargetEnvironment(name: "vulkan9") == nil)
    }
}
