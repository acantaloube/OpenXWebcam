// Soak test for the camera engine. Streams through CameraManager the way the app
// does, triggers autofocus every 2 minutes and toggles AE lock every 5, and prints
// per-minute frame rate and the longest gap, then a summary of every error.
//
// Build after ./build.sh (which produces buildout/):
//
//   SDK=$(xcrun --show-sdk-path); INC=CameraEngine/Sources/CPTPTransport/include
//   swiftc -O -o soak -sdk "$SDK" -target arm64-apple-macosx14.0 -I buildout -I "$INC" \
//     -Xcc -fmodule-map-file="$INC/module.modulemap" tools/soak.swift \
//     buildout/libCameraEngine.a buildout/PTPUSBTransport.o buildout/PTPUSBWatcher.o \
//     -framework Foundation -framework IOKit -framework IOUSBHost
//
// Run with the app closed and the camera on:
//
//   OPENXWEBCAM_LOG=1 ./soak 60 > soak.out 2> soak.engine.log
//
// It stops cleanly on SIGTERM/SIGINT. Never SIGKILL it mid-stream: an abrupt stop
// is what hangs the X-T3's USB firmware.
import Foundation
import CameraEngine

let minutes = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let duration = minutes * 60

final class Stats {
    private let lock = NSLock()
    private(set) var frames = 0
    private(set) var minuteFrames = 0
    private(set) var lastFrame = Date()
    private(set) var longestGapThisMinute: TimeInterval = 0
    private(set) var stalls: [(Date, TimeInterval)] = []
    private var inStall: Date? = nil
    func frame() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let gap = now.timeIntervalSince(lastFrame)
        if gap > longestGapThisMinute { longestGapThisMinute = gap }
        if let started = inStall { stalls.append((started, now.timeIntervalSince(started))); inStall = nil }
        frames += 1; minuteFrames += 1; lastFrame = now
    }
    func tick() {
        lock.lock(); defer { lock.unlock() }
        if inStall == nil, Date().timeIntervalSince(lastFrame) > 2 { inStall = lastFrame }
    }
    func takeMinute() -> (Int, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let r = (minuteFrames, max(longestGapThisMinute, Date().timeIntervalSince(lastFrame)))
        minuteFrames = 0; longestGapThisMinute = 0
        return r
    }
    func finish() -> [(Date, TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        if let started = inStall { stalls.append((started, Date().timeIntervalSince(started))) }
        return stalls
    }
}

let stats = Stats()
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
func out(_ s: String) { print("\(fmt.string(from: Date())) \(s)"); fflush(stdout) }

let m = CameraManager(size: .xga, quality: .normal)
var states: [String] = []
var aeLocked = false
m.onFrame = { _ in stats.frame() }
m.onState = { st in out("STATE \(st)"); states.append("\(st)") }
m.onAutofocusResult = { out("AF \($0 ? "locked" : "missed")") }
m.onExposureLockChanged = { aeLocked = $0; out("AE-L \($0 ? "locked" : "released")") }

// Stop cleanly on a termination signal: killing a client mid-stream is exactly what
// hangs the camera's USB firmware, so never exit with a transfer in flight.
var stopRequested = false
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { out("signal \(sig) - stopping cleanly"); stopRequested = true }
    src.resume()
    signalSources.append(src)
}

out("soak test: \(Int(minutes)) min")
m.start()
let start = Date()
var nextMinute = start.addingTimeInterval(60)
var nextAF = start.addingTimeInterval(120)
var nextAE = start.addingTimeInterval(300)
var minute = 0
while Date().timeIntervalSince(start) < duration && !stopRequested {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
    stats.tick()
    let now = Date()
    if now >= nextMinute {
        minute += 1
        let (f, gap) = stats.takeMinute()
        out(String(format: "MIN %02d  %5d frames  %5.1f fps  longest gap %.1fs", minute, f, Double(f)/60, gap))
        nextMinute = nextMinute.addingTimeInterval(60)
    }
    if now >= nextAF { m.requestAutofocus(); nextAF = now.addingTimeInterval(120) }
    if now >= nextAE { m.setAutoExposureLock(!aeLocked); nextAE = now.addingTimeInterval(300) }
}
m.stop()
m.waitUntilIdle(timeout: 8)
out("camera released")

let log = EngineLog.dump()
func count(_ needle: String) -> Int { log.filter { $0.contains(needle) }.count }
let stalls = stats.finish()
let elapsed = Date().timeIntervalSince(start)
print("\n===== SUMMARY =====")
print(String(format: "duration %.1f min, %d frames, %.1f fps average", elapsed/60, stats.frames, Double(stats.frames)/elapsed))
print("stalls > 2s: \(stalls.count)" + (stalls.isEmpty ? "" : "  (" + stalls.map { String(format: "%@ %.1fs", fmt.string(from: $0.0), $0.1) }.joined(separator: ", ") + ")"))
print("stream errors:        \(count("stream error"))")
print("  WritePipe failures: \(count("WritePipe"))   <- camera frozen; must be 0")
print("  malformed:          \(count("error 2"))")
print("stale containers:     \(count("discarded stale container"))")
print("stray fragments:      \(count("were not a container"))")
print("failed commands:      \(count("failed:"))")
print("camera error state:   \(states.filter { $0.contains("cameraError") }.count)   <- must be 0")
print("engine log kept: \(log.count) lines (last 300)")
