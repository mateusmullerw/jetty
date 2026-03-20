import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()  // strong ref — NSApplication.delegate is weak internally
app.delegate = delegate
app.run()
