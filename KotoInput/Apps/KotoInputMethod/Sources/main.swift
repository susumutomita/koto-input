#if canImport(AppKit) && canImport(InputMethodKit)
import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
#else
import Foundation

print("KotoInputMethod は macOS の InputMethodKit が必要です。このプラットフォームでは動作しません。")
exit(EXIT_FAILURE)
#endif
