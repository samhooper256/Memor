//
//  memor-mcp
//
//  Tiny stdio ↔ HTTP proxy. Claude Desktop spawns this as a subprocess;
//  it forwards each newline-delimited JSON-RPC message from stdin to Memor's
//  in-app MCP HTTP server at http://127.0.0.1:51745/mcp and writes the
//  response back to stdout, one JSON message per line.
//
//  Uses raw POSIX sockets rather than URLSession, because URLSession has
//  significant (~60s) latency when this helper is spawned by sandboxed
//  macOS apps like Claude Desktop.
//

import Darwin
import Foundation

let targetHost = "127.0.0.1"
let targetPort: UInt16 = 51745
let targetPath = "/mcp"
let ioTimeoutSeconds: Int = 10

let output = FileHandle.standardOutput
let errOut = FileHandle.standardError

// Read from fd 0 directly. FileHandle.standardInput.read(upToCount:) buffers
// aggressively when stdin is a pipe from another process, which stalls each
// message until the pipe is closed. Raw read(2) returns as soon as any bytes
// arrive on the pipe.
func readChunk() -> Data? {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
        Darwin.read(0, ptr.baseAddress, ptr.count)
    }
    if n < 0 {
        if errno == EINTR { return Data() } // retry
        return nil
    }
    if n == 0 { return nil } // EOF
    return Data(buf[0..<n])
}

// MARK: - stdio helpers

func writeLine(_ data: Data) {
    output.write(data)
    output.write(Data([0x0A]))
}

func logErr(_ message: String) {
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = df.string(from: Date())
    errOut.write(Data("memor-mcp \(ts): \(message)\n".utf8))
}

// MARK: - JSON-RPC helpers

func errorResponse(id: Any?, message: String) -> Data {
    var payload: [String: Any] = [
        "jsonrpc": "2.0",
        "error": ["code": -32000, "message": message]
    ]
    payload["id"] = id ?? NSNull()
    return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
}

func extractRequestID(from json: Data) -> Any? {
    guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
        return nil
    }
    return obj["id"]
}

func isNotification(_ data: Data) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return obj["id"] == nil && obj["method"] != nil
}

// MARK: - HTTP over raw sockets

enum HTTPClientError: Error {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case malformedResponse
}

struct HTTPResult {
    let statusCode: Int
    let body: Data
}

func performHTTPPost(body: Data) throws -> HTTPResult {
    logErr("performHTTPPost: socket()")
    let sockfd = socket(AF_INET, SOCK_STREAM, 0)
    if sockfd < 0 { throw HTTPClientError.socketFailed(errno) }
    defer { close(sockfd) }

    // Set send/receive timeouts so we can't hang forever.
    var tv = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
    _ = setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = targetPort.bigEndian
    if inet_pton(AF_INET, targetHost, &addr.sin_addr) != 1 {
        throw HTTPClientError.connectFailed(errno)
    }

    logErr("performHTTPPost: connect()")
    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult != 0 { throw HTTPClientError.connectFailed(errno) }
    logErr("performHTTPPost: connected")

    // Build and send request.
    var head = ""
    head += "POST \(targetPath) HTTP/1.1\r\n"
    head += "Host: \(targetHost):\(targetPort)\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Accept: application/json, text/event-stream\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n"
    head += "\r\n"

    var packet = Data(head.utf8)
    packet.append(body)

    logErr("performHTTPPost: sending \(packet.count) bytes")
    try packet.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        var sent = 0
        while sent < raw.count {
            let n = Darwin.send(sockfd, base.advanced(by: sent), raw.count - sent, 0)
            if n <= 0 { throw HTTPClientError.writeFailed(errno) }
            sent += n
        }
    }
    logErr("performHTTPPost: sent, reading response")

    // Read response until server closes (Content-Length + Connection: close)
    var responseData = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
            Darwin.recv(sockfd, buf.baseAddress, buf.count, 0)
        }
        if n == 0 { break } // clean close
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw HTTPClientError.readFailed(errno)
            }
            throw HTTPClientError.readFailed(errno)
        }
        responseData.append(chunk, count: n)
    }
    logErr("performHTTPPost: received \(responseData.count) bytes")

    return try parseHTTPResponse(responseData)
}

func parseHTTPResponse(_ data: Data) throws -> HTTPResult {
    guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else {
        throw HTTPClientError.malformedResponse
    }
    let headerBytes = data.subdata(in: data.startIndex..<terminator.lowerBound)
    let bodyBytes = data.subdata(in: terminator.upperBound..<data.endIndex)

    guard let headerText = String(data: headerBytes, encoding: .utf8) else {
        throw HTTPClientError.malformedResponse
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else { throw HTTPClientError.malformedResponse }
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2, let code = Int(parts[1]) else {
        throw HTTPClientError.malformedResponse
    }
    return HTTPResult(statusCode: code, body: bodyBytes)
}

// MARK: - Forwarding

func forward(_ line: Data) {
    logErr("forward: begin")
    do {
        let result = try performHTTPPost(body: line)
        guard (200..<300).contains(result.statusCode), !result.body.isEmpty else {
            let body = errorResponse(
                id: extractRequestID(from: line),
                message: "Memor returned HTTP \(result.statusCode)."
            )
            logErr("forward: writing error response (\(body.count) bytes)")
            writeLine(body)
            logErr("forward: wrote error response")
            return
        }
        var payload = result.body
        if payload.last == 0x0A { payload.removeLast() }
        logErr("forward: writing response (\(payload.count) bytes)")
        writeLine(payload)
        logErr("forward: wrote response")
    } catch {
        let body = errorResponse(
            id: extractRequestID(from: line),
            message: "Memor MCP server unreachable: \(error). Is Memor running?"
        )
        logErr("forward: caught error: \(error), writing error response")
        writeLine(body)
        logErr("forward: wrote error response")
    }
}

func forwardNotification(_ line: Data) {
    // Notifications: fire-and-forget. Still POST to the server so it can
    // react (e.g. notifications/initialized), but don't write a response.
    do {
        _ = try performHTTPPost(body: line)
    } catch {
        logErr("notification forward failed: \(error)")
    }
}

// MARK: - Main loop

var buffer = Data()
while true {
    guard let chunk = readChunk() else { break } // EOF
    if chunk.isEmpty { continue } // EINTR
    buffer.append(chunk)

    while let nlIndex = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<nlIndex)
        buffer.removeSubrange(buffer.startIndex...nlIndex)
        if line.isEmpty { continue }

        logErr("main: got line of \(line.count) bytes")
        if isNotification(line) {
            forwardNotification(line)
        } else {
            forward(line)
            logErr("main: forward() returned")
        }
    }
}
