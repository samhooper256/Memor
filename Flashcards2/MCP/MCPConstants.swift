import Foundation

enum MCPConstants {
    static let host = "127.0.0.1"
    static let port: Int = 51745
    static let httpPath = "/mcp"
}

extension Notification.Name {
    static let memorDidChangeDatabase = Notification.Name("com.sam.Memor.didChangeDatabase")
}
