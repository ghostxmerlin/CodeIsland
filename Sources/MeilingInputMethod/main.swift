import AppKit
import InputMethodKit

// 美玲输入法: commits text that aism decoded from the Tab5's key frames, through the standard input-method path
// (insertText). It never consumes keys. aism selects it for one dictation frame and restores the user's source.
let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "com.aism.inputmethod.Meiling_Connection"
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
MeilingCommitPort.shared.start()
_ = server
NSApplication.shared.run()
