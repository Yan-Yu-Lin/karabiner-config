import Foundation
import AppKit

// MARK: - Configuration
let home = NSHomeDirectory()
let hudFifoPath = "/tmp/karabiner-hud.fifo"
let modesConfigPath = home + "/Library/Scripts/karabiner-hud/modes.json"

// MARK: - Logging
func log(_ message: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(df.string(from: Date()))] \(message)"
    fputs(line + "\n", stderr)
}

// MARK: - Mode Data
struct AppKeys {
    let extra: [(key: String, desc: String)]
    let replace: [(key: String, desc: String)]?
}

struct ModeConfig {
    let title: String
    let keys: [(key: String, desc: String)]
    let apps: [String: AppKeys]  // bundle ID or path:regex -> app-specific keys
}

func loadModes(from path: String) -> [String: ModeConfig] {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        log("ERROR: Failed to load \(path)")
        return [:]
    }

    var result: [String: ModeConfig] = [:]
    for (name, value) in json {
        guard let dict = value as? [String: Any],
              let title = dict["title"] as? String,
              let rawKeys = dict["keys"] as? [[String]]
        else { continue }

        let keys = rawKeys.compactMap { pair -> (String, String)? in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }

        // Parse per-app extra/replacement keys
        var apps: [String: AppKeys] = [:]
        if let appsDict = dict["apps"] as? [String: Any] {
            for (matcher, appValue) in appsDict {
                guard let appDict = appValue as? [String: Any] else { continue }
                let extraKeys = (appDict["extra"] as? [[String]] ?? []).compactMap { pair -> (String, String)? in
                    guard pair.count == 2 else { return nil }
                    return (pair[0], pair[1])
                }
                let replacementKeys = (appDict["replace"] as? [[String]])?.compactMap { pair -> (String, String)? in
                    guard pair.count == 2 else { return nil }
                    return (pair[0], pair[1])
                }
                apps[matcher] = AppKeys(extra: extraKeys, replace: replacementKeys)
            }
        }

        result[name] = ModeConfig(title: title, keys: keys, apps: apps)
    }

    log("Loaded \(result.count) modes: \(result.keys.sorted().joined(separator: ", "))")
    return result
}

// MARK: - HUD Panel (never steals focus)
class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUD Controller
class HUDController {
    let panel: HUDPanel
    var modes: [String: ModeConfig] = [:]
    var hideTimer: DispatchSourceTimer?
    var currentMode: String?

    init() {
        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.alphaValue = 0
        self.panel = p
    }

    func show(modeName: String) {
        guard let mode = modes[modeName] else {
            log("WARN: Unknown mode '\(modeName)'")
            return
        }

        currentMode = modeName

        // Merge base keys with app-specific extras or replacements
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontmostApp?.bundleIdentifier
        let executablePath = frontmostApp?.executableURL?.path
        var match = bundleId.flatMap { id in mode.apps[id].map { (id, $0) } }
        if match == nil, let path = executablePath {
            match = mode.apps.sorted { $0.key < $1.key }.first { matcher, _ in
                guard matcher.hasPrefix("path:") else { return false }
                let pattern = String(matcher.dropFirst(5))
                return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                    in: path, range: NSRange(path.startIndex..., in: path)
                ) != nil
            }
        }

        var allKeys = mode.keys
        if let (matcher, appKeys) = match {
            allKeys = appKeys.replace ?? allKeys
            allKeys += appKeys.extra
            log("  app=\(matcher), replace=\(appKeys.replace?.count ?? 0), extra=\(appKeys.extra.count)")
        }

        // Build content
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true

        // Title
        let titleLabel = NSTextField(labelWithString: mode.title)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.5)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Key grid
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        for (key, desc) in allKeys {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            keyLabel.textColor = .white
            keyLabel.alignment = .right

            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            descLabel.textColor = NSColor(white: 1.0, alpha: 0.65)
            descLabel.alignment = .left

            grid.addRow(with: [keyLabel, descLabel])
        }

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        bg.addSubview(titleLabel)
        bg.addSubview(grid)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),

            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            grid.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])

        panel.contentView = bg

        // Size to fit
        bg.layoutSubtreeIfNeeded()
        let fitting = bg.fittingSize
        let w = max(fitting.width, 160)
        let h = max(fitting.height, 50)

        // Position: bottom-center of screen
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let x = sf.midX - w / 2
        let y = sf.minY + 120
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)

        // Show with fade-in
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        // Auto-hide safety net
        scheduleAutoHide()

        log("show '\(modeName)' (\(Int(w))x\(Int(h)))")
    }

    func hide() {
        cancelAutoHide()
        currentMode = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
        })

        log("hide")
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 8.0)
        timer.setEventHandler { [weak self] in self?.hide() }
        timer.resume()
        hideTimer = timer
    }

    private func cancelAutoHide() {
        hideTimer?.cancel()
        hideTimer = nil
    }
}

// MARK: - FIFO Setup
func ensureFIFO() {
    let fm = FileManager.default
    if fm.fileExists(atPath: hudFifoPath) {
        var sb = stat()
        stat(hudFifoPath, &sb)
        if (sb.st_mode & S_IFIFO) != 0 { return }
        try? fm.removeItem(atPath: hudFifoPath)
    }
    mkfifo(hudFifoPath, 0o666)
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

log("KarabinerHUD starting (pid \(ProcessInfo.processInfo.processIdentifier))")

let hud = HUDController()
hud.modes = loadModes(from: modesConfigPath)

// SIGHUP = reload modes.json
let sigSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
signal(SIGHUP, SIG_IGN)
sigSource.setEventHandler {
    log("SIGHUP received, reloading config")
    hud.modes = loadModes(from: modesConfigPath)
}
sigSource.resume()

// SIGTERM = clean shutdown
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
termSource.setEventHandler {
    log("Shutting down")
    unlink(hudFifoPath)
    exit(0)
}
termSource.resume()

ensureFIFO()
log("Listening on \(hudFifoPath)")

// FIFO read loop on background thread
DispatchQueue.global(qos: .userInteractive).async {
    while true {
        guard let file = fopen(hudFifoPath, "r") else {
            log("ERROR: Failed to open FIFO, retrying in 1s")
            sleep(1)
            continue
        }

        var buf = [CChar](repeating: 0, count: 256)
        while fgets(&buf, Int32(buf.count), file) != nil {
            let cmd = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.isEmpty { continue }
            log(">> \(cmd)")
            DispatchQueue.main.async {
                if cmd == "hide" {
                    hud.hide()
                } else if cmd.hasPrefix("hide ") {
                    // Conditional hide: only hide if currently showing this mode
                    let targetMode = String(cmd.dropFirst(5))
                    if hud.currentMode == targetMode {
                        hud.hide()
                    } else {
                        log("  ignore hide '\(targetMode)' (showing '\(hud.currentMode ?? "none")')")
                    }
                } else if cmd.hasPrefix("show ") {
                    let modeName = String(cmd.dropFirst(5))
                    hud.show(modeName: modeName)
                } else if cmd.hasPrefix("url ") {
                    let urlStr = String(cmd.dropFirst(4))
                    if let url = URL(string: urlStr) {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = false
                        NSWorkspace.shared.open(url, configuration: config)
                        log("  opened url: \(urlStr)")
                    } else {
                        log("  WARN: invalid url: \(urlStr)")
                    }
                } else {
                    log("WARN: Unknown command '\(cmd)'")
                }
            }
        }

        fclose(file)
    }
}

app.run()
