import AppKit

// A deterministic scrolling target for testing Peg's scroll capture.
// Build: swiftc -O -swift-version 5 Tools/ScrollToy/main.swift -o build/ScrollToy
//
// It shows a tall list in a real NSScrollView and steps it by 100 points each
// time /tmp/toy-step appears, so a capture session can be checked against a
// known truth without depending on timing.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let width: CGFloat = 900
let height: CGFloat = 9000
let visible: CGFloat = 700

let window = NSWindow(contentRect: NSRect(x: 300, y: 160, width: width, height: visible),
                      styleMask: [.titled, .closable],
                      backing: .buffered,
                      defer: false)
window.title = "ScrollToy"
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .stationary]

let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: visible))
scroll.hasVerticalScroller = false
scroll.hasHorizontalScroller = false
scroll.drawsBackground = true
scroll.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

var seed: UInt32 = 20_261_017
func random() -> UInt32 {
    seed = seed &* 1_664_525 &+ 1_013_904_223
    return seed >> 8
}

var y: CGFloat = height
var index = 0
while y > 0 {
    index += 1
    let rowHeight = 26 + CGFloat(random() % 26)
    y -= rowHeight
    let label = NSTextField(labelWithString:
        "ROW \(String(format: "%04d", index))  " + String(repeating: "=", count: Int(random() % 16)))
    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.textColor = NSColor(calibratedRed: 0.75, green: 0.85, blue: 0.95, alpha: 1)
    label.frame = NSRect(x: 18 + CGFloat(random() % 60), y: y + 4, width: width - 40, height: 20)
    document.addSubview(label)
}

scroll.documentView = document
window.contentView = scroll
window.orderFrontRegardless()
NSApp.activate(ignoringOtherApps: true)

var offset: CGFloat = 0
Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
    let clip = scroll.contentView
    offset = min(offset + 100, height - visible)
    let next = offset
    clip.scroll(to: NSPoint(x: 0, y: next))
    scroll.reflectScrolledClipView(clip)
    try? String(format: "%.1f", next).write(toFile: "/tmp/toy-offset", atomically: true, encoding: .utf8)
}

app.run()
