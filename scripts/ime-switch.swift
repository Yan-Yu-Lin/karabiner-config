import Cocoa
import Carbon

// Usage:
//   ime-switch toggle
//   ime-switch <input-source-id>
//   ime-switch arc-enter <session-id>
//   ime-switch arc-mark-override <session-id>
//   ime-switch arc-exit <session-id>
// Toggle/direct switch use TIS APIs.
// Arc commands manage command-bar IME session state.

let ABC = "com.apple.keylayout.ABC"
let ZHUYIN = "com.apple.inputmethod.TCIM.Zhuyin"
let stateDir = "/tmp/karabiner-ime"
let arcStateTTLSeconds: TimeInterval = 120

struct ArcState {
    let prevID: String
    let switchedByAutomation: Bool
    let overriddenByUser: Bool
    let createdAt: TimeInterval
}

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

func applyTarget(_ targetID: String) {
    if getCurrentID() == targetID { return }
    if isCJK(targetID) {
        switchWithCJKFix(to: targetID)
    } else {
        _ = selectSource(targetID)
    }
}

func ensureStateDir() {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
}

func arcStatePath(_ sessionID: String) -> String {
    return "\(stateDir)/\(sessionID).arc-state"
}

func writeArcState(_ sessionID: String, _ state: ArcState) {
    ensureStateDir()
    let payload = [
        "prev=\(state.prevID)",
        "switched=\(state.switchedByAutomation ? "1" : "0")",
        "override=\(state.overriddenByUser ? "1" : "0")",
        "ts=\(state.createdAt)",
    ].joined(separator: "\n") + "\n"
    try? payload.write(toFile: arcStatePath(sessionID), atomically: true, encoding: .utf8)
}

func readArcState(_ sessionID: String) -> ArcState? {
    guard let payload = try? String(contentsOfFile: arcStatePath(sessionID), encoding: .utf8) else {
        return nil
    }

    var map: [String: String] = [:]
    for rawLine in payload.split(separator: "\n") {
        let line = String(rawLine)
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq])
        let value = String(line[line.index(after: eq)...])
        map[key] = value
    }

    guard let prevID = map["prev"] else { return nil }
    let switched = map["switched"] == "1"
    let overridden = map["override"] == "1"
    let ts = TimeInterval(map["ts"] ?? "") ?? Date().timeIntervalSince1970

    return ArcState(prevID: prevID, switchedByAutomation: switched, overriddenByUser: overridden, createdAt: ts)
}

func clearArcState(_ sessionID: String) {
    try? FileManager.default.removeItem(atPath: arcStatePath(sessionID))
}

func sendNativeCmdSpace() {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
    else { return }

    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func toggleWithFallback(expectedAfterToggle targetID: String) {
    sendNativeCmdSpace()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    if getCurrentID() != targetID {
        applyTarget(targetID)
    }
}

func arcEnter(_ sessionID: String) {
    let currentID = getCurrentID() ?? ABC
    let switched = (currentID == ZHUYIN)

    writeArcState(
        sessionID,
        ArcState(
            prevID: currentID,
            switchedByAutomation: switched,
            overriddenByUser: false,
            createdAt: Date().timeIntervalSince1970
        )
    )

    if switched {
        toggleWithFallback(expectedAfterToggle: ABC)
    }
}

func arcMarkOverride(_ sessionID: String) {
    guard let state = readArcState(sessionID) else { return }
    writeArcState(
        sessionID,
        ArcState(
            prevID: state.prevID,
            switchedByAutomation: state.switchedByAutomation,
            overriddenByUser: true,
            createdAt: state.createdAt
        )
    )
}

func arcExit(_ sessionID: String) {
    guard let state = readArcState(sessionID) else { return }
    defer { clearArcState(sessionID) }

    if Date().timeIntervalSince1970 - state.createdAt > arcStateTTLSeconds { return }
    if !state.switchedByAutomation { return }
    if state.overriddenByUser { return }

    if state.prevID == ZHUYIN {
        toggleWithFallback(expectedAfterToggle: ZHUYIN)
    } else {
        applyTarget(state.prevID)
    }
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
        applyTarget(ZHUYIN)
    } else {
        applyTarget(ABC)
    }
} else if command == "arc-enter" {
    guard args.count > 2 else { exit(2) }
    arcEnter(args[2])
} else if command == "arc-mark-override" {
    guard args.count > 2 else { exit(2) }
    arcMarkOverride(args[2])
} else if command == "arc-exit" {
    guard args.count > 2 else { exit(2) }
    arcExit(args[2])
} else {
    // Direct switch to specified ID
    applyTarget(command)
}

// Print result for callers that want to know
if let result = getCurrentID() {
    // Print to stderr so it doesn't interfere with piping
    FileHandle.standardError.write(Data((result + "\n").utf8))
}
