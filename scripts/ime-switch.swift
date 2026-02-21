import Cocoa
import Carbon

// Usage: ime-switch toggle | ime-switch <input-source-id>
// Toggle: ABC ↔ Zhuyin. Direct: switch to specified input source.
// For CJK sources, uses a brief window trick to force proper mode initialization.

let ABC = "com.apple.keylayout.ABC"
let ZHUYIN = "com.apple.inputmethod.TCIM.Zhuyin"

func getCurrentID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func selectSource(_ id: String) -> Bool {
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    guard let source = sources.first(where: {
        guard let ptr = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return (Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String) == id
    }) else { return false }
    return TISSelectInputSource(source) == noErr
}

func isCJK(_ id: String) -> Bool {
    // CJK input methods have input_mode_id; keyboard layouts (ABC) don't
    return id.contains("inputmethod")
}

func switchWithCJKFix(to targetID: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Step 1: bounce through ABC (primes the switch, like macime's load does)
    if getCurrentID() != ABC {
        _ = selectSource(ABC)
    }

    // Step 2: select the CJK target
    _ = selectSource(targetID)

    // Step 3: create a non-activating panel with a text field
    // NSPanel with .nonactivatingPanel becomes key WITHOUT stealing app focus
    // The text field first responder forces macOS to initialize CJK internal mode
    let panel = NSPanel(
        contentRect: NSRect(x: -100, y: -100, width: 1, height: 1),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .screenSaver
    panel.alphaValue = 0.01
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

    let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    panel.contentView?.addSubview(textField)

    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(textField)
    // No app.activate — panel handles key status without stealing focus

    // Step 4: run the event loop so macOS processes the input source + window events
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

    // Step 5: clean up
    panel.orderOut(nil)
}

// --- Main ---
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "toggle"
let currentID = getCurrentID() ?? ABC

if command == "toggle" {
    if currentID == ABC {
        switchWithCJKFix(to: ZHUYIN)
    } else {
        _ = selectSource(ABC)
    }
} else {
    // Direct switch to specified ID
    if isCJK(command) {
        switchWithCJKFix(to: command)
    } else {
        _ = selectSource(command)
    }
}

// Print result for callers that want to know
if let result = getCurrentID() {
    // Print to stderr so it doesn't interfere with piping
    FileHandle.standardError.write(Data((result + "\n").utf8))
}
