import Foundation
import AppKit

// MARK: - Configuration
let home = NSHomeDirectory()
let configPath = home + "/Library/Scripts/karabiner-scripts/actions.json"
let fifoPath = "/tmp/karabiner-scripts.fifo"

// MARK: - Logging
func log(_ message: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(df.string(from: Date()))] \(message)"
    fputs(line + "\n", stderr)
}

// MARK: - AX Menu Click (fast, ~20ms, needs Accessibility permission)
func clickMenuItem(appName: String, menuPath: [String]) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == appName
    }) else {
        log("  App '\(appName)' not running")
        return false
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var menuBarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
          let menuBar = menuBarRef else {
        log("  Cannot access menu bar of '\(appName)'")
        return false
    }

    var current = menuBar as! AXUIElement

    for (depth, targetName) in menuPath.enumerated() {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else {
            log("  No children at depth \(depth)")
            return false
        }

        var matched = false
        for child in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == targetName else { continue }

            if depth == menuPath.count - 1 {
                let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
                return result == .success
            } else {
                var submenuRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &submenuRef)
                if let submenus = submenuRef as? [AXUIElement], !submenus.isEmpty {
                    current = submenus[0]
                }
                matched = true
                break
            }
        }

        if !matched {
            log("  '\(targetName)' not found at depth \(depth)")
            return false
        }
    }

    return false
}

// MARK: - Action Types
enum Action {
    case menu(app: String, path: [String])
    case applescript(compiled: NSAppleScript)
    case shell(command: String)
}

// MARK: - Action Store
class ActionStore {
    private var actions: [String: Action] = [:]

    func load(from path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("ERROR: Failed to load \(path)")
            return
        }

        actions.removeAll()

        for (name, value) in json {
            if let dict = value as? [String: Any] {
                if let appName = dict["app"] as? String,
                   let menuPath = dict["menu"] as? [String] {
                    // AX menu click — fast path
                    actions[name] = .menu(app: appName, path: menuPath)
                } else if let source = dict["applescript"] as? String {
                    // Pre-compiled AppleScript — fast, needs Automation permission
                    guard let script = NSAppleScript(source: source) else {
                        log("ERROR: Could not create script for '\(name)'")
                        continue
                    }
                    var error: NSDictionary?
                    script.compileAndReturnError(&error)
                    if let error = error {
                        log("ERROR: Compile '\(name)': \(error[NSAppleScript.errorMessage] ?? "unknown")")
                        continue
                    }
                    actions[name] = .applescript(compiled: script)
                } else if let cmd = dict["shell"] as? String {
                    actions[name] = .shell(command: cmd)
                }
            } else if let cmd = value as? String {
                // Plain string = shell command (backwards compat)
                actions[name] = .shell(command: cmd)
            }
        }

        log("Loaded \(actions.count) actions: \(actions.keys.sorted().joined(separator: ", "))")
    }

    func execute(_ name: String) {
        guard let action = actions[name] else {
            log("WARN: Unknown action '\(name)'")
            return
        }

        let start = CFAbsoluteTimeGetCurrent()

        switch action {
        case .menu(let app, let path):
            let ok = clickMenuItem(appName: app, menuPath: path)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            log(ok ? "OK: '\(name)' menu (\(ms)ms)" : "FAIL: '\(name)' menu (\(ms)ms)")

        case .applescript(let script):
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if let error = error {
                log("ERROR: '\(name)' applescript (\(ms)ms): \(error[NSAppleScript.errorMessage] ?? "unknown")")
            } else {
                log("OK: '\(name)' applescript (\(ms)ms)")
            }

        case .shell(let command):
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
            do {
                try proc.run()
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                log("OK: '\(name)' shell (\(ms)ms)")
            } catch {
                log("ERROR: '\(name)' shell: \(error)")
            }
        }
    }
}

// MARK: - FIFO Setup
func ensureFIFO() {
    let fm = FileManager.default
    if fm.fileExists(atPath: fifoPath) {
        var sb = stat()
        stat(fifoPath, &sb)
        if (sb.st_mode & S_IFIFO) != 0 { return }
        try? fm.removeItem(atPath: fifoPath)
    }
    mkfifo(fifoPath, 0o666)
}

// MARK: - Main
log("KarabinerScripts daemon starting (pid \(ProcessInfo.processInfo.processIdentifier))")
log("AX trusted: \(AXIsProcessTrusted())")

let store = ActionStore()
store.load(from: configPath)

// SIGHUP = reload config
let sigSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
signal(SIGHUP, SIG_IGN)
sigSource.setEventHandler {
    log("SIGHUP received, reloading config")
    store.load(from: configPath)
}
sigSource.resume()

// SIGTERM = clean shutdown
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
termSource.setEventHandler {
    log("Shutting down")
    unlink(fifoPath)
    exit(0)
}
termSource.resume()

ensureFIFO()
log("Listening on \(fifoPath)")

DispatchQueue.global(qos: .userInteractive).async {
    while true {
        guard let file = fopen(fifoPath, "r") else {
            log("ERROR: Failed to open FIFO, retrying in 1s")
            sleep(1)
            continue
        }

        var buf = [CChar](repeating: 0, count: 4096)
        while fgets(&buf, Int32(buf.count), file) != nil {
            let cmd = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.isEmpty { continue }
            log(">> \(cmd)")
            DispatchQueue.main.async {
                store.execute(cmd)
            }
        }

        fclose(file)
    }
}

RunLoop.main.run()
