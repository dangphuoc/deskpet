import AppKit

// Ghi vào pipe của tiến trình claude đã thoát sẽ phát SIGPIPE — bỏ qua để app không bị kill.
signal(SIGPIPE, SIG_IGN)
DeskPetMCP.runIfRequested() // chế độ MCP server cho phiên trợ lý — phải chạy trước mọi thứ khác
SelfTest.runIfRequested()
Snapshot.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // không có icon ở Dock
app.run()
