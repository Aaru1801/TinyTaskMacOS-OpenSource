import Cocoa
import CoreGraphics
import Combine

/// Replays a recorded macro by posting CGEvents at the original relative timestamps.
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentLoop: Int = 0
    @Published private(set) var totalLoops: Int = 1

    private var task: Task<Void, Never>?
    /// Incremented on every play()/stop(). A task only touches published state
    /// if its generation still matches, so a stale epilogue can't clobber a
    /// newer playback that started right after stop().
    private var generation: UInt64 = 0

    /// Play the macro `loops` times. Pass `loops <= 0` for continuous (infinite) playback,
    /// which only stops on `stop()` or the configured stop hotkey.
    /// The completion receives `true` only when playback ran to natural completion.
    /// A superseded/cancelled generation stays silent, so it cannot affect a newer
    /// playback run's state.
    func play(events: [RecordedEvent], loops: Int = 1, speed: Double = 1.0, completion: ((Bool) -> Void)? = nil) {
        let events = RecordedEvent.normalized(events)
        guard !isPlaying, !events.isEmpty else { completion?(false); return }
        let infinite = (loops <= 0)
        let total = infinite ? 0 : max(1, loops)

        generation &+= 1
        let gen = generation
        isPlaying = true
        progress = 0
        currentLoop = 0
        totalLoops = total
        let speed = max(0.1, min(speed, 10.0))
        let lastTime = events.last?.time ?? 0

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var loopIndex = 0
            // Throttle progress updates to ~30 Hz so the hot posting loop never
            // waits on a busy main thread between events.
            var lastProgressPush = 0.0
            outer: while !Task.isCancelled {
                if !infinite, loopIndex >= total { break }
                loopIndex += 1
                let snapshot = loopIndex
                await MainActor.run {
                    if self.generation == gen { self.currentLoop = snapshot }
                }
                let wallStart = CFAbsoluteTimeGetCurrent()
                for event in events {
                    if Task.isCancelled { break outer }
                    let target = wallStart + (event.time / speed)
                    let now = CFAbsoluteTimeGetCurrent()
                    let delay = target - now
                    // Guard non-finite / absurd delays from corrupt or hostile macro data:
                    // UInt64(inf) traps, UInt64(huge) overflows, and a giant finite delay
                    // would hang. Non-finite (inf/NaN) fails `.isFinite` and posts immediately.
                    if delay > 0, delay.isFinite {
                        try? await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000))
                    }
                    if Task.isCancelled { break outer }
                    Player.post(event)
                    let postTime = CFAbsoluteTimeGetCurrent()
                    if lastTime > 0, postTime - lastProgressPush > 0.033 {
                        lastProgressPush = postTime
                        let frac = min(1.0, event.time / lastTime)
                        await MainActor.run {
                            if self.generation == gen { self.progress = frac }
                        }
                    }
                }
            }
            await MainActor.run {
                // A cancelled, superseded run must not call its completion: a
                // controller may already have started a newer macro, and the old
                // completion could otherwise clear its chain/stat bookkeeping.
                guard self.generation == gen else { return }
                let finished = !Task.isCancelled
                self.isPlaying = false
                self.progress = 0
                self.currentLoop = 0
                self.totalLoops = 1
                completion?(finished)
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        isPlaying = false
        progress = 0
        currentLoop = 0
        totalLoops = 1
    }

    /// Synchronous playback for CLI mode — no MainActor hops, no published state.
    /// Blocks the calling (background) thread until done.
    static func playSynchronously(events: [RecordedEvent], loops: Int, speed: Double) {
        let events = RecordedEvent.normalized(events)
        guard !events.isEmpty else { return }
        let speed = max(0.1, min(speed, 10.0))
        let total = max(1, loops)
        for _ in 0..<total {
            let wallStart = CFAbsoluteTimeGetCurrent()
            for event in events {
                let target = wallStart + (event.time / speed)
                let delay = target - CFAbsoluteTimeGetCurrent()
                if delay > 0, delay.isFinite {
                    Thread.sleep(forTimeInterval: min(delay, 3600))
                }
                Player.post(event)
            }
        }
    }

    // MARK: - Posting

    private static func post(_ ev: RecordedEvent) {
        guard let cgType = CGEventType(rawValue: UInt32(ev.kind.rawValue)) else { return }

        switch ev.kind {
        case .keyDown, .keyUp:
            if let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(ev.keyCode),
                keyDown: ev.kind == .keyDown
            ) {
                cgEvent.flags = CGEventFlags(rawValue: ev.flags)
                cgEvent.post(tap: .cghidEventTap)
            }

        case .flagsChanged:
            // Construct a flagsChanged event by reusing keyboardEvent then overriding.
            if let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(ev.keyCode),
                keyDown: false
            ) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = CGEventFlags(rawValue: ev.flags)
                cgEvent.post(tap: .cghidEventTap)
            }

        case .scrollWheel:
            if let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                // Recorder stores legacy scroll-delta axes, whose units are
                // lines. Replaying them as pixels made wheel macros too small.
                units: .line,
                wheelCount: 2,
                wheel1: ev.scrollDeltaY,
                wheel2: ev.scrollDeltaX,
                wheel3: 0
            ) {
                cgEvent.flags = CGEventFlags(rawValue: ev.flags)
                cgEvent.post(tap: .cghidEventTap)
            }

        default:
            // Mouse events
            let button: CGMouseButton
            switch ev.kind {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                button = .left
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                button = .right
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                button = CGMouseButton(rawValue: UInt32(ev.mouseButton)) ?? .center
            case .mouseMoved:
                button = .left
            default:
                button = .left
            }

            if let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: cgType,
                mouseCursorPosition: CGPoint(x: ev.x, y: ev.y),
                mouseButton: button
            ) {
                if ev.clickCount > 0 {
                    cgEvent.setIntegerValueField(.mouseEventClickState, value: ev.clickCount)
                }
                cgEvent.flags = CGEventFlags(rawValue: ev.flags)
                cgEvent.post(tap: .cghidEventTap)
            }
        }
    }
}
