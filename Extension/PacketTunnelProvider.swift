import Foundation
import Library
#if os(iOS)
    import Libbox
#endif

class PacketTunnelProvider: ExtensionProvider {
    #if os(iOS)
        override func startTunnel(options: [String: NSObject]?) async throws {
            // Surge scripts run in WebKit's content process instead of the
            // extension's own memory; goja remains the fallback.
            LibboxSetScriptEngine(WebScriptEngine.shared)
            try await super.startTunnel(options: options)
        }
    #endif
}
