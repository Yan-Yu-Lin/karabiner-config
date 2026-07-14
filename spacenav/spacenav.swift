import Foundation
import CoreGraphics
import ApplicationServices
import Darwin

// spacenav next|prev
// macOS 26 and earlier: query real Mission Control Spaces with private CGS SPI,
// then ask Dock to move one Space using a synthetic, high-velocity DockSwipe.
// This is intentionally NOT CGSManagedDisplaySetCurrentSpace: outside Dock that
// call can desynchronize Dock/Mission Control from WindowServer.

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
typealias CGSGetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID
// Modern implementations accept an optional display filter as argument 2.
// Passing nil also works with implementations documented as the older 1-arg ABI
// because the extra arm64/x86_64 register argument is ignored.
typealias CGSCopyManagedDisplaySpacesFn = @convention(c)
    (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?

struct PrivateCGS {
    let mainConnectionID: CGSMainConnectionIDFn
    let getActiveSpace: CGSGetActiveSpaceFn
    let copyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn

    init() throws {
        // CoreGraphics re-exports many CGS symbols; SkyLight exports SLS/CGS
        // variants on current macOS. Loading both keeps symbol lookup explicit.
        let paths = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ]
        let handles = paths.compactMap { dlopen($0, RTLD_LAZY | RTLD_LOCAL) }

        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { // RTLD_DEFAULT
                return p
            }
            for handle in handles {
                if let p = dlsym(handle, name) { return p }
            }
            return nil
        }

        guard let main = symbol("CGSMainConnectionID"),
              let active = symbol("CGSGetActiveSpace"),
              let managed = symbol("CGSCopyManagedDisplaySpaces") else {
            throw NavError.privateSymbolsMissing
        }

        mainConnectionID = unsafeBitCast(main, to: CGSMainConnectionIDFn.self)
        getActiveSpace = unsafeBitCast(active, to: CGSGetActiveSpaceFn.self)
        copyManagedDisplaySpaces = unsafeBitCast(managed, to: CGSCopyManagedDisplaySpacesFn.self)
    }
}

enum Direction {
    case next, prev
}

enum NavError: Error, CustomStringConvertible {
    case usage
    case privateSymbolsMissing
    case noConnection
    case spacesQueryFailed
    case malformedSpaces
    case currentSpaceNotFound
    case accessibilityRequired
    case eventCreationFailed

    var description: String {
        switch self {
        case .usage: return "usage: spacenav next|prev"
        case .privateSymbolsMissing: return "required private CGS symbols are unavailable"
        case .noConnection: return "CGSMainConnectionID returned 0"
        case .spacesQueryFailed: return "CGSCopyManagedDisplaySpaces failed"
        case .malformedSpaces: return "managed Spaces data had an unexpected format"
        case .currentSpaceNotFound: return "could not locate the current Space in its display's ordered Space list"
        case .accessibilityRequired: return "Accessibility permission is required for this binary"
        case .eventCreationFailed: return "could not create synthetic CGEvents"
        }
    }
}

func uint64(_ value: Any?) -> UInt64? {
    if let n = value as? NSNumber { return n.uint64Value }
    if let n = value as? UInt64 { return n }
    if let n = value as? Int, n >= 0 { return UInt64(n) }
    return nil
}

func spaceID(_ dictionary: [String: Any]) -> UInt64? {
    // Both names occur in CGSCopyManagedDisplaySpaces output across releases.
    uint64(dictionary["id64"]) ?? uint64(dictionary["ManagedSpaceID"])
}

struct DisplaySpaces {
    let identifier: String
    let currentID: UInt64
    let orderedIDs: [UInt64]
    let orderedTypes: [Int64]   // CGS space "type": 0 = user/desktop, 4 = native-fullscreen app

    func typeName(at index: Int) -> String {
        guard orderedTypes.indices.contains(index) else { return "unknown" }
        switch orderedTypes[index] {
        case 0: return "user"
        case 4: return "fullscreen"
        default: return "other\(orderedTypes[index])"
        }
    }
}

func displayUnderPointerIdentifier() -> String? {
    guard let event = CGEvent(source: nil) else { return nil }
    let point = event.location
    var display = CGDirectDisplayID()
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
          let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(display) else { return nil }
    let uuid = unmanagedUUID.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String
}

func loadDisplaySpaces(cgs: PrivateCGS, connection: CGSConnectionID) throws -> DisplaySpaces {
    guard let unmanaged = cgs.copyManagedDisplaySpaces(connection, nil) else {
        throw NavError.spacesQueryFailed
    }
    let raw = unmanaged.takeRetainedValue()
    guard let displays = raw as? [[String: Any]], !displays.isEmpty else {
        throw NavError.malformedSpaces
    }

    let globalActive = cgs.getActiveSpace(connection)
    let pointerDisplay = displayUnderPointerIdentifier()

    func decode(_ display: [String: Any]) -> DisplaySpaces? {
        guard let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any],
              let currentID = spaceID(current) else { return nil }
        let decoded: [(UInt64, Int64)] = spaces.compactMap { dict in
            guard let id = spaceID(dict) else { return nil }
            let type = (dict["type"] as? NSNumber)?.int64Value ?? -1
            return (id, type)
        }
        guard !decoded.isEmpty else { return nil }
        return DisplaySpaces(
            identifier: display["Display Identifier"] as? String ?? "Main",
            currentID: currentID,
            orderedIDs: decoded.map { $0.0 },
            orderedTypes: decoded.map { $0.1 }
        )
    }

    let decoded = displays.compactMap(decode)
    guard !decoded.isEmpty else { throw NavError.malformedSpaces }

    // Match BTT/InstantSpaceSwitcher behavior as closely as possible: inspect
    // the pointer's display, then fall back to the globally active display.
    if let wanted = pointerDisplay,
       let display = decoded.first(where: { $0.identifier.caseInsensitiveCompare(wanted) == .orderedSame }) {
        return display
    }
    if let display = decoded.first(where: { $0.currentID == globalActive }) {
        return display
    }
    if decoded.count == 1 { return decoded[0] }
    return decoded[0]
}

// Undocumented CGEvent fields/types used by Dock's horizontal Space gesture.
let fieldEventSubtype = CGEventField(rawValue: 55)!
let fieldHIDType = CGEventField(rawValue: 110)!
let fieldSwipeMotion = CGEventField(rawValue: 123)!
let fieldSwipeProgress = CGEventField(rawValue: 124)!
let fieldVelocityX = CGEventField(rawValue: 129)!
let fieldGesturePhase = CGEventField(rawValue: 132)!

let eventDockControl: Int64 = 30
let hidDockSwipe: Int64 = 23
let motionHorizontal: Int64 = 1
let phaseBegan: Int64 = 1
let phaseEnded: Int64 = 4

// Current yabai profile (space_manager.c, 7.1.21+): one reused DockControl
// event, progress ±1, velocity ±9999, began→ended back-to-back with no delay
// and no companion Gesture event. Leanest known sequence — fewest chances for
// the compositor to render an intermediate "offset" frame.
// (BTT itself posts ±3.0 progress with a 15ms usleep between phases, which is
// 1-2 frames — the micro-slide was inherent to BTT too.)
func postInstantDockSwipe(_ direction: Direction) throws {
    let sign = direction == .next ? 1.0 : -1.0

    guard let event = CGEvent(source: nil) else {
        throw NavError.eventCreationFailed
    }

    event.setIntegerValueField(fieldEventSubtype, value: eventDockControl)
    event.setIntegerValueField(fieldHIDType, value: hidDockSwipe)
    event.setIntegerValueField(fieldSwipeMotion, value: motionHorizontal)
    event.setDoubleValueField(fieldSwipeProgress, value: sign)
    event.setDoubleValueField(fieldVelocityX, value: sign * 9999.0)

    event.setIntegerValueField(fieldGesturePhase, value: phaseBegan)
    event.post(tap: .cgSessionEventTap)

    event.setIntegerValueField(fieldGesturePhase, value: phaseEnded)
    event.post(tap: .cgSessionEventTap)
}

// Minimal AeroSpace socket client — same protocol as the `aerospace` CLI but
// without the ~30ms process spawn. Protocol: connect to the unix socket, swap
// UInt32 protocol versions (1), then length-prefixed JSON ClientRequest.
// Used to coordinate AeroSpace's focused workspace around Space switches so it
// doesn't corner-stash the desktop's windows on arrival (the wallpaper flash).
final class AeroClient {
    private let fd: Int32

    init?() {
        guard let fd = AeroClient.connectAndHandshake() else { return nil }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    private static func connectAndHandshake() -> Int32? {
        let path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits: Bool = path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let len = strlen(cstr)
                guard len + 1 <= raw.count else { return false }
                raw.baseAddress!.copyMemory(from: cstr, byteCount: len + 1)
                return true
            }
        }
        guard fits else { Darwin.close(fd); return nil }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(fd); return nil }

        // Version handshake: send ours, require the same back.
        guard writeAll(fd, uint32Data(1)),
              let reply = readExact(fd, 4),
              reply.withUnsafeBytes({ $0.load(as: UInt32.self) }) == 1 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Send a CLI-equivalent command; returns the server's stdout, or nil on failure.
    func send(_ args: [String]) -> String? {
        let request: [String: Any] = [
            "args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull(),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var msg = AeroClient.uint32Data(UInt32(payload.count))
        msg.append(payload)
        guard AeroClient.writeAll(fd, msg),
              let lenData = AeroClient.readExact(fd, 4) else { return nil }
        let len = lenData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard len < 10_000_000, let body = AeroClient.readExact(fd, Int(len)),
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return obj["stdout"] as? String
    }

    private static func uint32Data(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value) { Data($0) }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let n = read(fd, &buf, min(buf.count, count - data.count))
            guard n > 0 else { return nil }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }
}

func dumpSpaces(cgs: PrivateCGS, connection: CGSConnectionID) {
    guard let unmanaged = cgs.copyManagedDisplaySpaces(connection, nil) else {
        print("CGSCopyManagedDisplaySpaces failed")
        return
    }
    print(unmanaged.takeRetainedValue())
}

func run() throws {
    guard CommandLine.arguments.count == 2 else { throw NavError.usage }

    if CommandLine.arguments[1] == "dump" {
        let cgs = try PrivateCGS()
        dumpSpaces(cgs: cgs, connection: cgs.mainConnectionID())
        return
    }

    let direction: Direction
    switch CommandLine.arguments[1] {
    case "next": direction = .next
    case "prev": direction = .prev
    default: throw NavError.usage
    }

    // One-shot mode. Prompting from a short-lived CLI is awkward, so fail with
    // a useful message. (Daemon mode prompts properly at startup.)
    guard AXIsProcessTrusted() else { throw NavError.accessibilityRequired }

    let cgs = try PrivateCGS()
    let connection = cgs.mainConnectionID()
    guard connection != 0 else { throw NavError.noConnection }
    try performSwitch(direction, cgs: cgs, connection: connection)
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(message)")
    fflush(stdout)
}

func performSwitch(_ direction: Direction, cgs: PrivateCGS, connection: CGSConnectionID) throws {
    let display = try loadDisplaySpaces(cgs: cgs, connection: connection)

    guard let index = display.orderedIDs.firstIndex(of: display.currentID) else {
        throw NavError.currentSpaceNotFound
    }
    let target = direction == .next ? index + 1 : index - 1

    // BTT clamps rather than wraps. The no-op is a successful invocation.
    guard display.orderedIDs.indices.contains(target) else {
        log("NOOP")
        return
    }

    let fromType = display.typeName(at: index)
    let toType = display.typeName(at: target)
    let statePath = "/tmp/.spacenav.desktop-ws"

    // Sample the active space BEFORE switching so we can detect the moment
    // the switch actually commits.
    let activeBefore = cgs.getActiveSpace(connection)

    // Gesture FIRST — nothing may delay the keypress→switch latency.
    // The target ID is deliberately not passed to CGS. The adjacent DockSwipe
    // is what keeps Dock, WindowServer, menu bar, fullscreen Spaces, and Mission
    // Control state synchronized while SIP remains enabled.
    try postInstantDockSwipe(direction)

    // AeroSpace coordination happens AFTER the gesture (no-op if AeroSpace
    // isn't running). Kill switch: `touch /tmp/.spacenav-no-aero`.
    let coordinate = !FileManager.default.fileExists(atPath: "/tmp/.spacenav-no-aero")
    let aero = coordinate ? AeroClient() : nil

    // Leaving a desktop space: remember which workspace the user was really in
    // (the focused WINDOW's workspace — the focused-workspace value itself is
    // exactly the state that desyncs after fullscreen roundtrips). Querying
    // ~2ms after the gesture is safe: AeroSpace's model lags the space change
    // by ~50ms+ (notification → task → task), so we still see pre-switch focus.
    if fromType == "user", let aero {
        var ws = aero.send(["list-windows", "--focused", "--format", "%{workspace}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ws.isEmpty {
            ws = aero.send(["list-workspaces", "--focused"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if !ws.isEmpty {
            try? ws.write(toFile: statePath, atomically: true, encoding: .utf8)
        }
    }

    // Returning to the desktop: re-focus the remembered workspace the INSTANT
    // the native space actually changes. AeroSpace's own reaction goes
    // notification → task → task before touching windows; landing our command
    // first (or mid-refresh — incoming commands cancel an in-flight refresh)
    // keeps its model coherent and puts focus back on the remembered window.
    if fromType == "fullscreen", toType == "user", let aero,
       let ws = (try? String(contentsOfFile: statePath, encoding: .utf8))?
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !ws.isEmpty {
        let deadline = Date().addingTimeInterval(0.5)
        while cgs.getActiveSpace(connection) == activeBefore, Date() < deadline {
            usleep(1000)  // ~1ms poll; switch usually commits within a frame
        }
        _ = aero.send(["workspace", ws])
    }

    log("FROM=\(fromType) TO=\(toType)")
}

// Resident daemon mode: `spacenav --daemon`, driven by a LaunchAgent.
// Karabiner echoes "next"/"prev" into the FIFO; no process spawn per keypress,
// so keypress→switch is ~15ms instead of ~100ms (spacenav cold-start was ~70ms).
// NOTE: the daemon owns its own TCC identity — rebuilding the binary
// invalidates its Accessibility grant (re-add in System Settings after rebuild).
func runDaemon() -> Never {
    // Trigger the Accessibility prompt on first run, then wait for the grant.
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
        log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)…")
        while !AXIsProcessTrusted() { sleep(2) }
    }
    log("accessibility granted")

    guard let cgs = try? PrivateCGS() else {
        log("fatal: private CGS symbols unavailable"); exit(1)
    }
    let connection = cgs.mainConnectionID()
    guard connection != 0 else { log("fatal: no CGS connection"); exit(1) }

    let fifoPath = "/tmp/spacenav.fifo"
    unlink(fifoPath)
    guard mkfifo(fifoPath, 0o600) == 0 else {
        log("fatal: mkfifo failed: \(String(cString: strerror(errno)))"); exit(1)
    }
    // O_RDWR keeps a writer open so reads block instead of returning EOF
    // whenever a client closes its end.
    let fd = open(fifoPath, O_RDWR)
    guard fd >= 0 else { log("fatal: cannot open fifo"); exit(1) }
    log("listening on \(fifoPath)")

    var buf = [UInt8](repeating: 0, count: 1024)
    var pending = ""
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { usleep(100_000); continue }
        pending += String(decoding: buf[0..<n], as: UTF8.self)
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: nl)...])
            let direction: Direction?
            switch line {
                case "next": direction = .next
                case "prev": direction = .prev
                case "": direction = nil
                default: log("unknown command: \(line)"); direction = nil
            }
            if let direction {
                do { try performSwitch(direction, cgs: cgs, connection: connection) }
                catch { log("error: \(error)") }
            }
        }
    }
}

do {
    if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--daemon" {
        runDaemon()
    }
    try run()
} catch {
    fputs("spacenav: \(error)\n", stderr)
    exit(error is NavError ? 2 : 1)
}
