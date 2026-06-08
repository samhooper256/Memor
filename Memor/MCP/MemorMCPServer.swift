import Foundation
import Logging
import MCP

final class MemorMCPServer {
    private let appDatabase: AppDatabase
    private let logger = Logger(label: "com.sam.Memor.mcp")
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listener: MCPHTTPListener?
    private var startTask: Task<Void, Never>?

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
    }

    func start() {
        guard server == nil else { return }

        let server = Server(
            name: "Memor",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let transport = StatelessHTTPServerTransport(logger: logger)
        let listener = MCPHTTPListener(
            port: UInt16(MCPConstants.port),
            transport: transport,
            logger: logger
        )

        self.server = server
        self.transport = transport
        self.listener = listener

        startTask = Task { [appDatabase, logger] in
            await MemorMCPTools.register(on: server, appDatabase: appDatabase)
            do {
                try await server.start(transport: transport)
            } catch {
                logger.error("MCP server start failed: \(error)")
                return
            }

            // Claude Desktop respawns the stdio helper multiple times (discovery +
            // chat sessions). Each respawn sends a fresh `initialize`, but the SDK's
            // default handler throws "Server is already initialized" the second time.
            // Replace it with an idempotent handler so every new client session
            // receives a valid initialize response.
            await server.withMethodHandler(Initialize.self) { params in
                let supported: Set<String> = [
                    "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
                ]
                let negotiated = supported.contains(params.protocolVersion)
                    ? params.protocolVersion
                    : Version.latest
                return Initialize.Result(
                    protocolVersion: negotiated,
                    capabilities: .init(tools: .init(listChanged: false)),
                    serverInfo: .init(name: "Memor", version: "0.1.0"),
                    instructions: nil
                )
            }

            do {
                try listener.start()
            } catch {
                logger.error("MCP HTTP listener failed: \(error)")
            }
        }
    }

    func stop() {
        listener?.stop()
        let server = self.server
        self.listener = nil
        self.transport = nil
        self.server = nil
        self.startTask?.cancel()
        self.startTask = nil
        Task {
            await server?.stop()
        }
    }
}
