//
//  spirv-mcp: the plugin's MCP server, over stdio.
//

import ShaderDebug
import SpirvMCP

// It runs for the whole session; a tool call that keeps allocating ends the
// server at 2 GB rather than the machine.
let limit = MemoryLimit(megabytes: 2048)
SpirvToolSet().server().run()
