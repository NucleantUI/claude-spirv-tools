import SpirvCore

/// What a module shows the pipeline: entry points, their inputs and outputs,
/// descriptor bindings and push constants, with each type spelled out.
extension DebugShader {
    public func interfaceReport() -> String {
        let types = TypeNamer(module: module, names: { self.name(of: $0) })
        var decorations: [UInt32: [(SpirvDecoration?, [UInt32])]] = [:]
        var memberDecorations: [UInt32: [UInt32: [(SpirvDecoration?, [UInt32])]]] = [:]
        var memberNames: [UInt32: [UInt32: String]] = [:]
        var variables: [(id: UInt32, type: UInt32, storage: SpirvStorageClass?)] = []
        var entries: [(model: SpirvExecutionModel?, function: UInt32, name: String, interface: [UInt32])] = []
        var modes: [UInt32: [String]] = [:]

        for inst in module.instructions {
            let o = inst.operands
            switch inst.op {
            case .opEntryPoint:
                let (name, count) = inst.string(at: 2)
                entries.append((SpirvExecutionModel(rawValue: o[0]), o[1], name, Array(o[(2 + count)...])))
            case .opExecutionMode:
                let mode = SpirvExecutionMode(rawValue: o[1]).map { "\($0)" } ?? "mode \(o[1])"
                let literals = o.dropFirst(2).map(String.init).joined(separator: " ")
                modes[o[0], default: []].append(literals.isEmpty ? mode : "\(mode) \(literals)")
            case .opDecorate:
                decorations[o[0], default: []].append((SpirvDecoration(rawValue: o[1]), Array(o.dropFirst(2))))
            case .opMemberDecorate:
                memberDecorations[o[0], default: [:]][o[1], default: []].append((SpirvDecoration(rawValue: o[2]), Array(o.dropFirst(3))))
            case .opMemberName:
                memberNames[o[0], default: [:]][o[1]] = inst.string(at: 2).string
            case .opVariable:
                variables.append((o[1], o[0], SpirvStorageClass(rawValue: o[2])))
            default:
                break
            }
        }

        func decoration(_ id: UInt32, _ kind: SpirvDecoration) -> [UInt32]? {
            decorations[id]?.first { $0.0 == kind }?.1
        }
        func label(_ id: UInt32) -> String { name(of: id).map { $0.isEmpty ? "%\(id)" : $0 } ?? "%\(id)" }
        func users(_ id: UInt32) -> String {
            let using = entries.filter { $0.interface.contains(id) }.map(\.name)
            return using.isEmpty || using.count == entries.count ? "" : "  (\(using.joined(separator: ", ")))"
        }

        var out: [String] = ["Entry points:"]
        for entry in entries {
            let model = entry.model.map { "\($0)" } ?? "model ?"
            let modeList = modes[entry.function].map { "  [\($0.joined(separator: ", "))]" } ?? ""
            out.append("  \(model) \"\(entry.name)\" -> \(label(entry.function))\(modeList)")
        }

        for (title, storage) in [("Inputs", SpirvStorageClass.input), ("Outputs", .output)] {
            let vars = variables.filter { $0.storage == storage }
            guard !vars.isEmpty else { continue }
            out.append("\(title):")
            for v in vars {
                let pointee = types.pointee(of: v.type)
                var slot: String
                if let location = decoration(v.id, .location)?.first {
                    slot = "location \(location)"
                } else if let builtin = decoration(v.id, .builtIn)?.first {
                    slot = "builtin \(SpirvBuiltIn(rawValue: builtin).map { "\($0)" } ?? "\(builtin)")"
                } else {
                    slot = "block"
                }
                if decoration(v.id, .flat) != nil { slot += " flat" }
                out.append("  \(slot)  \(label(v.id)): \(types.name(pointee))\(users(v.id))")
            }
        }

        let resources = variables.filter { [.uniform, .uniformConstant, .storageBuffer].contains($0.storage) }
        if !resources.isEmpty {
            out.append("Descriptors:")
            for v in resources {
                let set = decoration(v.id, .descriptorSet)?.first.map(String.init) ?? "?"
                let binding = decoration(v.id, .binding)?.first.map(String.init) ?? "?"
                let storage = v.storage.map { "\($0)" } ?? "?"
                out.append("  set \(set) binding \(binding)  \(label(v.id)): \(types.name(types.pointee(of: v.type))) (\(storage))\(users(v.id))")
            }
        }

        // The members of each block, by offset: push constants and buffers.
        let blocks = variables.filter { [.pushConstant, .uniform, .storageBuffer].contains($0.storage) }
        for v in blocks {
            let structId = types.pointee(of: v.type)
            guard let members = types.members(of: structId) else { continue }
            let storage = v.storage == .pushConstant ? "Push constants" : "Block"
            out.append("\(storage) \(label(v.id)): \(types.name(structId))")
            for (index, member) in members.enumerated() {
                let decs = memberDecorations[structId]?[UInt32(index)] ?? []
                let offset = decs.first { $0.0 == .offset }?.1.first.map { "offset \($0)" } ?? "offset ?"
                let memberName = memberNames[structId]?[UInt32(index)] ?? "member \(index)"
                out.append("  \(offset)  \(memberName): \(types.name(member))")
            }
        }
        return out.joined(separator: "\n")
    }
}

/// Spells SPIR-V types the way PyShader writes them: `float4`, `float4x4`,
/// `float[8]`, a struct by its name.
struct TypeNamer {
    private var types: [UInt32: SpirvModuleReader.Instruction] = [:]
    private var constants: [UInt32: UInt32] = [:]
    private let names: (UInt32) -> String?

    init(module: SpirvModuleReader, names: @escaping (UInt32) -> String?) {
        self.names = names
        for inst in module.instructions {
            guard let op = inst.op else { continue }
            switch op {
            case .opTypeVoid, .opTypeBool, .opTypeInt, .opTypeFloat, .opTypeVector, .opTypeMatrix,
                 .opTypeImage, .opTypeSampler, .opTypeSampledImage, .opTypeArray, .opTypeRuntimeArray,
                 .opTypeStruct, .opTypePointer:
                types[inst.operands[0]] = inst
            case .opConstant where inst.operands.count >= 3:
                constants[inst.operands[1]] = inst.operands[2]
            default:
                break
            }
        }
    }

    func pointee(of pointer: UInt32) -> UInt32 {
        guard let inst = types[pointer], inst.op == .opTypePointer else { return pointer }
        return inst.operands[2]
    }

    func members(of id: UInt32) -> [UInt32]? {
        guard let inst = types[id], inst.op == .opTypeStruct else { return nil }
        return Array(inst.operands.dropFirst())
    }

    func name(_ id: UInt32) -> String {
        guard let inst = types[id], let op = inst.op else { return "%\(id)" }
        let o = inst.operands
        switch op {
        case .opTypeVoid: return "void"
        case .opTypeBool: return "bool"
        case .opTypeInt: return o[2] == 1 ? (o[1] == 32 ? "int" : "int\(o[1])") : (o[1] == 32 ? "uint" : "uint\(o[1])")
        case .opTypeFloat: return o[1] == 32 ? "float" : o[1] == 64 ? "double" : "float\(o[1])"
        case .opTypeVector: return "\(name(o[1]))\(o[2])"
        case .opTypeMatrix:
            // Columns of `rows`-vectors: floatCxR.
            let column = types[o[1]]
            let rows = column?.operands[2] ?? 0
            let scalar = column.map { name($0.operands[1]) } ?? "?"
            return "\(scalar)\(o[2])x\(rows)"
        case .opTypeArray: return "\(name(o[1]))[\(constants[o[2]].map(String.init) ?? "?")]"
        case .opTypeRuntimeArray: return "\(name(o[1]))[]"
        case .opTypeStruct: return names(id).flatMap { $0.isEmpty ? nil : $0 } ?? "struct %\(id)"
        case .opTypePointer:
            let storage = SpirvStorageClass(rawValue: o[1]).map { "\($0)" } ?? "?"
            return "ptr<\(storage), \(name(o[2]))>"
        case .opTypeSampler: return "sampler"
        case .opTypeImage:
            let dim = SpirvDim(rawValue: o[2]).map { "\($0)" } ?? "?"
            let storage = o.count > 6 && o[6] == 2 ? "storage image" : "image"
            return "\(storage) \(dim) of \(name(o[1]))"
        case .opTypeSampledImage: return "sampled \(name(o[1]))"
        default: return "%\(id)"
        }
    }
}
