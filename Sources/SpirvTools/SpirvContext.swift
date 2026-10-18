import CSpirvTools
import Foundation

/// The environment SPIR-V is checked and transformed against: `vulkan1.0`,
/// `vulkan1.3`, `spv1.6`, … — the names `spirv-val --target-env` takes.
public struct SpirvTargetEnvironment: Sendable, CustomStringConvertible {
    let raw: spv_target_env
    public let description: String

    /// Vulkan 1.0, what PyShader's modules are written for.
    public static let vulkan1_0 = SpirvTargetEnvironment(raw: SPV_ENV_VULKAN_1_0, description: "vulkan1.0")

    init(raw: spv_target_env, description: String) {
        self.raw = raw
        self.description = description
    }

    /// The environment named `name`, as `--target-env` spells it; nil for an unknown name.
    public init?(name: String) {
        var env = SPV_ENV_UNIVERSAL_1_0
        guard spvParseTargetEnv(name, &env) else { return nil }
        raw = env
        description = name
    }
}

/// A message from SPIRV-Tools about a module or an assembly text.
public struct SpirvDiagnostic: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// For a module: the 1-based number of the instruction at fault, counted
    /// from the first after the header; 0 when the message names none.
    public let instruction: Int
    /// For an assembly text: the 0-based line and column.
    public let line: Int
    public let column: Int

    public init(message: String, instruction: Int = 0, line: Int = 0, column: Int = 0) {
        self.message = message
        self.instruction = instruction
        self.line = line
        self.column = column
    }

    init(_ diagnostic: spv_diagnostic) {
        let d = diagnostic.pointee
        message = d.error.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if d.isTextSource {
            instruction = 0
            line = Int(d.position.line)
            column = Int(d.position.column)
        } else {
            instruction = Int(d.position.index)
            line = 0
            column = 0
        }
    }

    public var description: String { message }
}

/// SPIRV-Tools for one target environment: the validator, the disassembler
/// and assembler, and the optimizer, in process.
public final class SpirvContext {
    public let environment: SpirvTargetEnvironment
    private let context: spv_context

    public init(environment: SpirvTargetEnvironment = .vulkan1_0) {
        self.environment = environment
        context = spvContextCreate(environment.raw)
    }

    deinit {
        spvContextDestroy(context)
    }

    /// The SPIRV-Tools version linked in.
    public static var version: String {
        String(cString: spvSoftwareVersionDetailsString())
    }

    // MARK: Validate

    /// Validates the module; nil when it is valid, else the first error. The
    /// message names ids by their `OpName` when `friendlyNames` is set.
    public func validate(_ words: [UInt32], friendlyNames: Bool = true) -> SpirvDiagnostic? {
        let options = spvValidatorOptionsCreate()
        defer { spvValidatorOptionsDestroy(options) }
        spvValidatorOptionsSetFriendlyNames(options, friendlyNames)
        var diagnostic: spv_diagnostic?
        defer { spvDiagnosticDestroy(diagnostic) }
        let result = words.withUnsafeBufferPointer { buffer -> spv_result_t in
            var binary = spv_const_binary_t(code: buffer.baseAddress, wordCount: buffer.count)
            return spvValidateWithOptions(context, options, &binary, &diagnostic)
        }
        guard result != SPV_SUCCESS else { return nil }
        if let diagnostic { return SpirvDiagnostic(diagnostic) }
        return SpirvDiagnostic(message: "validation failed (\(result.rawValue))")
    }

    // MARK: Disassemble / assemble

    /// How `disassemble` writes the text.
    public struct DisassemblyOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// `%main` for an id with an `OpName`, instead of `%12`.
        public static let friendlyNames = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_FRIENDLY_NAMES.rawValue)
        /// Results lined up in a column.
        public static let indent = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_INDENT.rawValue)
        /// Block contents indented by nesting depth.
        public static let nestedIndent = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_NESTED_INDENT.rawValue)
        /// Comments on what an instruction refers to (adds lines).
        public static let comment = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_COMMENT.rawValue)
        /// Leaves out the `; SPIR-V` header lines.
        public static let noHeader = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_NO_HEADER.rawValue)
        /// Each instruction's word offset in a comment.
        public static let byteOffsets = DisassemblyOptions(rawValue: SPV_BINARY_TO_TEXT_OPTION_SHOW_BYTE_OFFSET.rawValue)
    }

    /// The module as assembly text.
    public func disassemble(_ words: [UInt32], options: DisassemblyOptions = [.friendlyNames, .indent]) throws -> String {
        var text: spv_text?
        var diagnostic: spv_diagnostic?
        defer {
            spvTextDestroy(text)
            spvDiagnosticDestroy(diagnostic)
        }
        let result = words.withUnsafeBufferPointer { buffer in
            spvBinaryToText(context, buffer.baseAddress, buffer.count, options.rawValue, &text, &diagnostic)
        }
        guard result == SPV_SUCCESS, let text, let str = text.pointee.str else {
            throw diagnostic.map(SpirvDiagnostic.init) ?? SpirvDiagnostic(message: "disassembly failed (\(result.rawValue))")
        }
        let bytes = UnsafeRawBufferPointer(start: str, count: text.pointee.length)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The module the assembly text describes.
    public func assemble(_ source: String) throws -> [UInt32] {
        var binary: spv_binary?
        var diagnostic: spv_diagnostic?
        defer {
            spvBinaryDestroy(binary)
            spvDiagnosticDestroy(diagnostic)
        }
        let utf8 = Array(source.utf8)
        let result = utf8.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                spvTextToBinaryWithOptions(context, chars.baseAddress, chars.count,
                                           SPV_TEXT_TO_BINARY_OPTION_PRESERVE_NUMERIC_IDS.rawValue, &binary, &diagnostic)
            }
        }
        guard result == SPV_SUCCESS, let binary else {
            throw diagnostic.map(SpirvDiagnostic.init) ?? SpirvDiagnostic(message: "assembly failed (\(result.rawValue))")
        }
        return Array(UnsafeBufferPointer(start: binary.pointee.code, count: binary.pointee.wordCount))
    }

    // MARK: Optimize

    /// Runs the optimizer passes `flags` name, as `spirv-opt` spells them:
    /// `-O`, `-Os`, `--eliminate-dead-code-aggressive`, `--strip-debug`, …
    /// Throws for an unknown flag or a pass that fails, with the optimizer's
    /// messages.
    public func optimize(_ words: [UInt32], flags: [String]) throws -> [UInt32] {
        let optimizer = spvOptimizerCreate(environment.raw)
        defer { spvOptimizerDestroy(optimizer) }
        for flag in flags where !spvOptimizerRegisterPassFromFlag(optimizer, flag) {
            throw SpirvDiagnostic(message: "unknown optimizer flag \(flag)")
        }
        let options = spvOptimizerOptionsCreate()
        defer { spvOptimizerOptionsDestroy(options) }
        spvOptimizerOptionsSetRunValidator(options, false)

        var binary: spv_binary?
        defer { spvBinaryDestroy(binary) }
        let (result, messages) = OptimizerMessages.collect {
            spvOptimizerSetMessageConsumer(optimizer, OptimizerMessages.consumer)
            return words.withUnsafeBufferPointer { buffer in
                spvOptimizerRun(optimizer, buffer.baseAddress, buffer.count, &binary, options)
            }
        }
        guard result == SPV_SUCCESS, let binary else {
            let detail = messages.isEmpty ? "error \(result.rawValue)" : messages.joined(separator: "\n")
            throw SpirvDiagnostic(message: "optimizer failed: \(detail)")
        }
        return Array(UnsafeBufferPointer(start: binary.pointee.code, count: binary.pointee.wordCount))
    }
}

/// The optimizer reports through a C function pointer with no context, so its
/// messages go to one collector at a time, behind a lock.
final class OptimizerMessages: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: [String] = []

    static let consumer: spv_message_consumer = { level, _, _, message in
        guard level.rawValue <= SPV_MSG_WARNING.rawValue, let message else { return }
        current.append(String(cString: message))
    }

    static func collect<T>(_ body: () -> T) -> (T, [String]) {
        lock.lock()
        defer { lock.unlock() }
        current = []
        let value = body()
        return (value, current)
    }
}
