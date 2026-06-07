import Foundation
import Logging
import MCP
import Network

/// Minimal HTTP/1.1 listener for loopback, backed by Network.framework.
///
/// Each accepted connection is parsed as a single HTTP/1.1 request, handed to the
/// MCP `StatelessHTTPServerTransport`, and the returned `HTTPResponse` is serialized
/// back to the socket. `Connection: close` is sent so we never have to support
/// keep-alive framing.
final class MCPHTTPListener {

    private let port: UInt16
    private let transport: StatelessHTTPServerTransport
    private let logger: Logger
    private var listener: NWListener?

    init(port: UInt16, transport: StatelessHTTPServerTransport, logger: Logger) {
        self.port = port
        self.transport = transport
        self.logger = logger
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        self.listener = listener

        listener.stateUpdateHandler = { [logger, port] state in
            switch state {
            case .failed(let error):
                logger.error("MCP listener failed: \(error)")
            case .ready:
                logger.info("MCP listener ready on 127.0.0.1:\(port)")
            case .cancelled:
                logger.info("MCP listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        let transport = self.transport
        let logger = self.logger
        Task.detached {
            defer { connection.cancel() }
            do {
                guard let request = try await Self.readRequest(from: connection) else {
                    return
                }
                let response = await transport.handleRequest(request)
                try await Self.writeResponse(response, to: connection)
            } catch {
                logger.error("MCP connection error: \(error)")
            }
        }
    }

    // MARK: - HTTP reading

    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 4 * 1024 * 1024

    private static func readRequest(from connection: NWConnection) async throws -> HTTPRequest? {
        var buffer = Data()

        while true {
            let chunk = try await receive(from: connection, maximumLength: 8192)
            if chunk.isEmpty { return nil }
            buffer.append(chunk)

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
                guard let head = parseHead(headerData) else { return nil }

                var body = buffer.subdata(in: terminator.upperBound..<buffer.endIndex)
                let contentLength = head.headers
                    .first(where: { $0.key.lowercased() == "content-length" })
                    .flatMap { Int($0.value) } ?? 0

                if contentLength > maxBodyBytes { return nil }

                while body.count < contentLength {
                    let more = try await receive(from: connection, maximumLength: contentLength - body.count)
                    if more.isEmpty { break }
                    body.append(more)
                }

                return HTTPRequest(
                    method: head.method,
                    headers: head.headers,
                    body: body.isEmpty ? nil : body,
                    path: head.path
                )
            }

            if buffer.count > maxHeaderBytes { return nil }
        }
    }

    private static func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        return (method, path, headers)
    }

    private static func receive(from connection: NWConnection, maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximumLength)) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - HTTP writing

    private static func writeResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
        // StatelessHTTPServerTransport never returns .stream; treat it as empty if encountered.
        let body: Data
        switch response {
        case .stream:
            body = Data()
        default:
            body = response.bodyData ?? Data()
        }

        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var packet = Data(head.utf8)
        packet.append(body)

        try await send(data: packet, on: connection)
    }

    private static func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status \(code)"
        }
    }
}
