import Cocoa
import CoreGraphics

// bdkeyswitch — keeps BetterDisplay's brightness-key targeting correct as
// displays come and go.
//
// Rule: external display present  -> brightness keys affect ONLY the external
//       (allowKeyboardControl@Display:2 = 0, the built-in is excluded)
//       external absent            -> keys affect the built-in again ( = 1)
//
// KEY DISCOVERY (2026-07-27, tested): BetterDisplay reads this pref LIVE on
// every media-key press — a plain `defaults write` takes effect on the next
// keypress, NO app restart needed. So the daemon only flips this one pref.
// (videoMediaKeyAssumeControlMode stays at its current value; whatever the
// mode, BD keeps intercepting the keys, so routing must be done here. Its
// "conditional" modes do NOT release the keys back to macOS when the
// external display leaves — tested: keys went fully dead — hence this
// daemon rather than relying on those modes.)
//
// Display change detection: CGDisplayRegisterReconfigurationCallback with a
// 3s debounce, plus a 10s poll fallback (CG callbacks proved droppable).

let DOMAIN = "pro.betterdisplay.BetterDisplay"
let BUILTIN_KEY = "allowKeyboardControl@Display:2"

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

func externalPresent() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) == 0 {
        return true
    }
    return false
}

func run(_ cmd: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

func currentPrefAllowsBuiltin() -> Bool {
    // Read fresh from disk each time (cfprefsd may cache; -currentHost off)
    UserDefaults.standard.synchronize()
    let d = UserDefaults(suiteName: DOMAIN)
    return d?.bool(forKey: BUILTIN_KEY) ?? true
}

func reconcile() {
    let wantBuiltinKeys = !externalPresent() // no external -> builtin gets the keys
    let haveBuiltinKeys = currentPrefAllowsBuiltin()
    guard wantBuiltinKeys != haveBuiltinKeys else { return }

    log("display change: external=\(!wantBuiltinKeys) -> set \(BUILTIN_KEY)=\(wantBuiltinKeys) (live, no restart)")
    run("/usr/bin/defaults", ["write", DOMAIN, BUILTIN_KEY, "-bool", wantBuiltinKeys ? "true" : "false"])
}

var debounce: DispatchWorkItem?

// NOTE: debounce must NOT use DispatchQueue.main — in a plain CLI daemon
// RunLoop.main.run() never drains the main GCD queue, so main-queue blocks
// silently never execute (the original bug: plug events were detected but
// reconcile never ran). A background queue works regardless.
let workQueue = DispatchQueue(label: "bdkeyswitch.reconcile")

let callback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    // ignore the "begin" phase; act after changes settle
    if flags.contains(.beginConfigurationFlag) { return }
    log("display reconfiguration event (flags=\(flags.rawValue))")
    debounce?.cancel()
    let work = DispatchWorkItem { reconcile() }
    debounce = work
    workQueue.asyncAfter(deadline: .now() + 3.0, execute: work)
}

CGDisplayRegisterReconfigurationCallback(callback, nil)

// Belt and braces: the CG callback proved unreliable in this daemon context
// (a real plug event at 17:54 was never delivered — see git history), so also
// poll. externalPresent() is a cheap in-process call; reconcile() is a no-op
// unless the pref actually disagrees with reality.
let pollTimer = DispatchSource.makeTimerSource(queue: workQueue)
pollTimer.schedule(deadline: .now() + 10, repeating: 10)
pollTimer.setEventHandler { reconcile() }
pollTimer.resume()

log("bdkeyswitch started; external=\(externalPresent()), builtinKeys=\(currentPrefAllowsBuiltin())")
reconcile() // fix state at startup too (e.g. plugged/unplugged while daemon was down)
RunLoop.main.run()
