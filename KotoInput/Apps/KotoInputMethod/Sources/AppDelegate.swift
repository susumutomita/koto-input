#if canImport(AppKit) && canImport(InputMethodKit)
import AppKit
import InputMethodKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connectionName =
            (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
            ?? "Koto_1_Connection"
        server = IMKServer(
            name: connectionName,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}
#endif
