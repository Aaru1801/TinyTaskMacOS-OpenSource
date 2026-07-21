import Cocoa
import CoreGraphics
import Combine

/// Replays a recorded macro by posting CGEvents at the original relative timestamps.
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentLoop: Int = 0
    @Published private(set) var totalLoops: Int = 1
    @Published private(set) var currentEvent: Int = 0
    @Published private(set) var totalEvents: Int = 0

    /// Progress across the complete finite run, rather than only the current
    /// loop. Continuous playback intentionally reports the current-loop phase.
    var overallProgress: Double {
        guard isPlaying else { return 0 }
        let phase = max(0, min(1, progress))
        guard totalLoops > 0 else { return phase }
        let completedLoops = max(0, currentLoop - 1)
        return max(0, min(1, (Double(completedLoops) + phase) / Double(totalLoops)))
    }

    var isContinuous: Bool { isPlaying && totalLoops == 0 }

    private var task: Task<Void, Never>?
    private let inputTracker = SyntheticInputTracker()
    private lazy var telemetryRelay = PlaybackTelemetryRelay(player: self)
    /// Incremented on every play()/stop(). A task only touches published state
    /// if its generation still matches, so a stale epilogue can't clobber a
    /// newer playback that started right after stop().
    private var generation: UInt64 = 0

    deinit {
        let activeGeneration = generation
        task?.cancel()
        inputTracker.releaseInputs(for: activeGeneration, invalidate: true)
    }

    /// Play the macro `loops` times. Pass `loops <= 0` for continuous (infinite) playback,
    /// which only stops on `stop()` or the configured stop hotkey.
    /// The completion receives `true` only when playback ran to natural completion.
    /// A superseded/cancelled generation stays silent, so it cannot affect a newer
    /// playback run's state.
    func play(events: [RecordedEvent], loops: Int = 1, speed: Double = 1.0, completion: ((Bool) -> Void)? = nil) {
        // Recorder, library, importers, and editor persistence all normalize at
        // their boundary. Avoid an O(n log n) copy/sort on the UI thread every
        // time the user presses Play.
        guard !isPlaying, !events.isEmpty else { completion?(false); return }
        let normalizedLoops = normalizedLoopCount(loops)
        let infinite = (normalizedLoops == 0)
        let total = infinite ? 0 : normalizedLoops

        generation &+= 1
        let gen = generation
        isPlaying = true
        progress = 0
        currentLoop = 0
        totalLoops = total
        currentEvent = 0
        totalEvents = events.count
        let speed = max(0.1, min(speed, 10.0))
        let lastTime = events.last?.time ?? 0
        inputTracker.begin(generation: gen)
        let telemetryRelay = telemetryRelay

        task = Task.detached(priority: .userInitiated) { [weak self, inputTracker, telemetryRelay] in
            var loopIndex = 0
            while !Task.isCancelled {
                if !infinite, loopIndex >= total { break }
                loopIndex += 1
                let snapshot = loopIndex
                telemetryRelay.submit(PlaybackTelemetry(
                    generation: gen,
                    currentLoop: snapshot,
                    progress: 0,
                    currentEvent: 0
                ))
                let wallStart = CFAbsoluteTimeGetCurrent()
                var lastTelemetryPush = 0.0
                for (eventIndex, event) in events.enumerated() {
                    if Task.isCancelled { break }
                    let target = wallStart + (event.time / speed)
                    // Sleep in short, precise chunks. Besides remaining promptly
                    // cancellable, this keeps progress moving through long pauses
                    // instead of freezing until the next recorded event posts.
                    while !Task.isCancelled {
                        let remaining = target - CFAbsoluteTimeGetCurrent()
                        guard remaining > 0, remaining.isFinite else { break }
                        let slice = min(remaining, 1.0 / 30.0)
                        try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                        if lastTime > 0 {
                            let elapsed = max(0, CFAbsoluteTimeGetCurrent() - wallStart)
                            let fraction = min(1.0, elapsed * speed / lastTime)
                            telemetryRelay.submit(PlaybackTelemetry(
                                generation: gen,
                                progress: fraction
                            ))
                        }
                    }
                    if Task.isCancelled { break }
                    guard inputTracker.post(event, generation: gen) else { continue }

                    let now = CFAbsoluteTimeGetCurrent()
                    let isLast = eventIndex == events.count - 1
                    if isLast || now - lastTelemetryPush >= (1.0 / 30.0) {
                        lastTelemetryPush = now
                        let postedCount = eventIndex + 1
                        let fraction = lastTime > 0
                            ? min(1.0, max(event.time, (now - wallStart) * speed) / lastTime)
                            : Double(postedCount) / Double(max(1, events.count))
                        telemetryRelay.submit(PlaybackTelemetry(
                            generation: gen,
                            progress: isLast ? 1 : fraction,
                            currentEvent: postedCount
                        ))
                    }
                }

                // A malformed macro may omit keyUp/mouseUp. Neutralize each
                // loop so continuous/repeated playback can never accumulate a
                // logically held Command key or mouse button.
                inputTracker.releaseInputs(for: gen, invalidate: false)
                if Task.isCancelled { break }
            }
            inputTracker.releaseInputs(for: gen, invalidate: true)
            let finished = !Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A cancelled, superseded run must not call its completion: a
                // controller may already have started a newer macro, and the old
                // completion could otherwise clear its chain/stat bookkeeping.
                guard self.generation == gen else { return }
                // Invalidate any coalesced telemetry still waiting behind this
                // epilogue on the main queue.
                self.generation &+= 1
                self.isPlaying = false
                self.progress = 0
                self.currentLoop = 0
                self.totalLoops = 1
                self.currentEvent = 0
                self.totalEvents = 0
                self.task = nil
                completion?(finished)
            }
        }
    }

    func stop() {
        let cancelledGeneration = generation
        generation &+= 1
        task?.cancel()
        task = nil
        // Serialized with event posting, so Stop cannot land between a
        // synthetic keyDown and the tracker's bookkeeping.
        inputTracker.releaseInputs(for: cancelledGeneration, invalidate: true)
        isPlaying = false
        progress = 0
        currentLoop = 0
        totalLoops = 1
        currentEvent = 0
        totalEvents = 0
    }

    /// Synchronous playback for CLI mode — no MainActor hops, no published state.
    /// Blocks the calling (background) thread until done.
    static func playSynchronously(events: [RecordedEvent], loops: Int, speed: Double) {
        let events = RecordedEvent.normalized(events)
        guard !events.isEmpty else { return }
        let speed = max(0.1, min(speed, 10.0))
        let total = max(1, normalizedLoopCount(loops))
        let tracker = SyntheticInputTracker()
        for loopIndex in 0..<total {
            let gen = UInt64(loopIndex + 1)
            tracker.begin(generation: gen)
            let wallStart = CFAbsoluteTimeGetCurrent()
            for event in events {
                let target = wallStart + (event.time / speed)
                let delay = target - CFAbsoluteTimeGetCurrent()
                if delay > 0, delay.isFinite {
                    Thread.sleep(forTimeInterval: min(delay, 3600))
                }
                _ = tracker.post(event, generation: gen)
            }
            tracker.releaseInputs(for: gen, invalidate: true)
        }
    }

    // MARK: - Posting

    private struct PlaybackTelemetry: Sendable {
        let generation: UInt64
        var currentLoop: Int?
        var progress: Double?
        var currentEvent: Int?

        init(
            generation: UInt64,
            currentLoop: Int? = nil,
            progress: Double? = nil,
            currentEvent: Int? = nil
        ) {
            self.generation = generation
            self.currentLoop = currentLoop
            self.progress = progress
            self.currentEvent = currentEvent
        }

        mutating func merge(_ newer: PlaybackTelemetry) {
            guard generation == newer.generation else { return }
            currentLoop = newer.currentLoop ?? currentLoop
            progress = newer.progress ?? progress
            currentEvent = newer.currentEvent ?? currentEvent
        }
    }

    /// Coalesces playback telemetry onto the main queue without ever making the
    /// timing worker wait for SwiftUI/AppKit. A stalled UI receives one freshest
    /// snapshot instead of a backlog that could perturb event posting cadence.
    private final class PlaybackTelemetryRelay: @unchecked Sendable {
        private weak var player: Player?
        private let lock = NSLock()
        private var pending: PlaybackTelemetry?
        private var deliveryScheduled = false

        init(player: Player) {
            self.player = player
        }

        func submit(_ update: PlaybackTelemetry) {
            lock.lock()
            if var current = pending, current.generation == update.generation {
                current.merge(update)
                pending = current
            } else {
                pending = update
            }
            let shouldSchedule = !deliveryScheduled
            deliveryScheduled = true
            lock.unlock()

            if shouldSchedule {
                DispatchQueue.main.async { [weak self] in self?.deliver() }
            }
        }

        private func deliver() {
            lock.lock()
            let update = pending
            pending = nil
            deliveryScheduled = false
            lock.unlock()

            guard let update, let player, player.generation == update.generation else { return }
            if let currentLoop = update.currentLoop { player.currentLoop = currentLoop }
            if let progress = update.progress { player.progress = progress }
            if let currentEvent = update.currentEvent { player.currentEvent = currentEvent }
        }
    }

    @discardableResult
    private static func post(_ ev: RecordedEvent) -> Bool {
        guard let cgType = CGEventType(rawValue: UInt32(ev.kind.rawValue)) else { return false }

        switch ev.kind {
        case .keyDown, .keyUp:
            if let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(ev.keyCode),
                keyDown: ev.kind == .keyDown
            ) {
                cgEvent.flags = CGEventFlags(rawValue: ev.flags)
                cgEvent.post(tap: .cghidEventTap)
                return true
            }
            return false

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
                return true
            }
            return false

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
                return true
            }
            return false

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
                return true
            }
            return false
        }
    }

    /// Serializes synthetic event posting with emergency cleanup. This closes a
    /// subtle race where Stop could release inputs immediately before a detached
    /// playback task posted one final keyDown.
    private final class SyntheticInputTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64?
        private var keysDown: Set<UInt16> = []
        private var modifierKeys: Set<UInt16> = []
        private var mouseButtons: [Int64: CGPoint] = [:]

        func begin(generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            releaseLocked()
            self.generation = generation
        }

        @discardableResult
        func post(_ event: RecordedEvent, generation: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard self.generation == generation else { return false }
            guard Player.post(event) else { return false }
            observe(event)
            return true
        }

        func releaseInputs(for generation: UInt64, invalidate: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard self.generation == generation else { return }
            releaseLocked()
            if invalidate { self.generation = nil }
        }

        private func observe(_ event: RecordedEvent) {
            switch event.kind {
            case .keyDown:
                keysDown.insert(event.keyCode)
            case .keyUp:
                keysDown.remove(event.keyCode)
            case .flagsChanged:
                if Self.modifierIsActive(keyCode: event.keyCode, flags: event.flags) {
                    modifierKeys.insert(event.keyCode)
                } else {
                    modifierKeys.remove(event.keyCode)
                }
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                mouseButtons[Self.buttonNumber(for: event)] = event.location
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                let button = Self.buttonNumber(for: event)
                if mouseButtons[button] != nil { mouseButtons[button] = event.location }
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                mouseButtons.removeValue(forKey: Self.buttonNumber(for: event))
            default:
                break
            }
        }

        private func releaseLocked() {
            let keys = keysDown
            let modifiers = modifierKeys
            let buttons = mouseButtons
            keysDown.removeAll(keepingCapacity: true)
            modifierKeys.removeAll(keepingCapacity: true)
            mouseButtons.removeAll(keepingCapacity: true)

            for keyCode in keys {
                guard let event = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: CGKeyCode(keyCode),
                    keyDown: false
                ) else { continue }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }

            for keyCode in modifiers {
                guard let event = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: CGKeyCode(keyCode),
                    keyDown: false
                ) else { continue }
                event.type = .flagsChanged
                event.flags = []
                event.post(tap: .cghidEventTap)
            }

            for (buttonNumber, location) in buttons {
                let raw = UInt32(max(0, min(buttonNumber, Int64(UInt32.max))))
                let button = CGMouseButton(rawValue: raw) ?? .center
                let type: CGEventType = buttonNumber == 0
                    ? .leftMouseUp
                    : (buttonNumber == 1 ? .rightMouseUp : .otherMouseUp)
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: location,
                    mouseButton: button
                ) else { continue }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }

        private static func buttonNumber(for event: RecordedEvent) -> Int64 {
            switch event.kind {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return 0
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
            default: return max(2, event.mouseButton)
            }
        }

        private static func modifierIsActive(keyCode: UInt16, flags rawFlags: UInt64) -> Bool {
            let flags = CGEventFlags(rawValue: rawFlags)
            let flag: CGEventFlags?
            switch keyCode {
            case 54, 55: flag = .maskCommand
            case 56, 60: flag = .maskShift
            case 57:     flag = .maskAlphaShift
            case 58, 61: flag = .maskAlternate
            case 59, 62: flag = .maskControl
            case 63:     flag = .maskSecondaryFn
            default:     flag = nil
            }
            return flag.map(flags.contains) ?? !flags.isEmpty
        }
    }
}
