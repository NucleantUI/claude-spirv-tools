---
name: spirv-debugging
description: Debug SPIR-V and PyShader shaders with the spirv-tools plugin's MCP tools — use when a PyShader .py fails to compile, spirv-val rejects a module, a shader renders wrong or not at all, a .spv needs inspecting (interface, bindings, push constants, disassembly), or a PyShader compiler change needs checking against the SPIR-V it produces.
---

# Debugging SPIR-V and PyShader

The `spirv` MCP server runs SPIRV-Tools in process. Every tool takes `file`:
a PyShader `.py` (compiled with its Python lines kept) or a `.spv`. Errors and
disassembly come back at Python `file:line`, so fix the Python, not the SPIR-V.

| Tool | Use it to |
|---|---|
| `check` | Compile and validate. The first step for any shader problem. `output` writes the `.spv`. |
| `functions` | See what a module contains and where each function starts in Python. |
| `disassemble` | Read one `function`'s SPIR-V next to its Python lines. Always narrow it to one function. |
| `interface` | See what the pipeline must supply: entry points, locations, builtins, set/binding, push constant and block offsets. |
| `optimize` | Run spirv-opt passes. `-O` folds constant computations, which shows what an expression really computes. |
| `assemble` | Try a hand-edited module before changing the compiler that produced it. |

## Compile options for a `.py`

Pass the same options `pyshaderc` takes. If a `pyshader.toml` lists the shader,
copy its section into these arguments:

- `target`: `fragment` (the default; NucleantVulkan's full-screen layout),
  `compute` (NucleantUI's `Shader` view, a storage image), or `graphics`
  (`VertexShader`: `def vertex` plus `def fragment` in one module).
- `arguments`: ShaderArguments as `name:kind`, for example `["gain:float", "touches:floatArray"]`.
  A `main` parameter that is neither a builtin input nor an argument is an
  error ("is not a shader input"). That usually means an argument is missing
  here, not that the shader is wrong.
- `content: true` when the shader samples the view's content (`layer()`).
- `site_packages` when imports live outside the nearest uv `.venv`.

## Workflow

1. Run `check`. A compile error names the Python line, so fix that first.
2. A validation error comes back as `file:line: error: <spirv-val message>`, with
   the offending instruction disassembled in the message. Read the Python line,
   then `disassemble` that `function` to see what PyShader emitted for it.
3. When a shader runs but draws the wrong thing, compare `interface` with what the host
   binds. Look at push constant offsets, which block holds `time` and `resolution`,
   and the set/binding numbers. Also check that the varyings between the
   vertex and fragment stages match by location.
4. When a value is suspect, run `optimize` with the default `-O` on the function.
   A constant computation folds to its result.
5. When the compiler is at fault, `disassemble` the function, hand-edit the text,
   and `assemble` it to check the fix validates. Then change the compiler.

## Reading PyShader's SPIR-V

- Imported functions keep their qualified name: `noise.fbm`, `pyshader.stdlib.fragment.sdf.sd_box`.
  Their `OpLine`s name the module's file relative to where it was found: `tint.py` next to
  the shader, `pyshader/stdlib/fragment/sdf.py` in site-packages.
- The entry point names are `main` for fragment and compute, and `vertex` and
  `fragment` for graphics. A graphics module also has `py_vertex` and `py_fragment`,
  the Python bodies the entry points call.
- A fragment shader's host data is a push constant block (`time` at 0,
  `resolution` at 8, `mouse` at 16). Compute and graphics shaders use a
  `Uniforms` block at set 0, binding 1 instead. ShaderArguments are in
  `ShaderArgs`, as a `float[]`.
- Functions with `list[T]` or host-array parameters are generic. Each set of
  argument types gets its own copy.

## The hook

After an Edit or Write to a `.py` that imports pyshader and defines `main`, or
`vertex` and `fragment`, a PostToolUse hook compiles and validates the file.
When either step fails, the report comes back to you. Fix the file before
moving on. The hook takes the target and arguments from the nearest
`pyshader.toml` that lists the shader. Without one, it tries `fragment`, then
`compute`. Modules without an entry point are skipped, and so is anything
under `.venv` or site-packages.

## Limits

The server stops itself at 2 GB and the hook at 1 GB or 20 seconds. Either
means a compiler or tool bug, not a big shader. Report it rather than retrying.
