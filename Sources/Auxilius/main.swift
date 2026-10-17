import Foundation

// One binary, two roles: the app itself, and the MCP server that chat clients launch with --mcp.
if CommandLine.arguments.contains("--mcp") {
    MCPServer.run()
} else {
    AuxiliusApp.main()
}
