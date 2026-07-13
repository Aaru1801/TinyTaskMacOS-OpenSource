import Cocoa
import CoreGraphics
import Combine

/// Captures live mouse + keyboard events into an in-memory macro using a CGEventTap.
final class Recorder: ObservableObject {
    struct CaptureStats {
        var clicks = 0
        var keys = 0
        var scrolls = 0
        var drags = 0

        mutating func include(_ kind: RecordedEvent.Kind) {
            switch kind {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: clicks += 1
            case .keyDown: keys += 1
            case .scrollWheel: scrolls += 1
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: drags += 1
            default: break
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var events: [RecordedEvent] = []
    @Published private(set) var liveDuration: TimeInterval = 0
    /// Maintained incrementally as pending events flush. The HUD redraws at 10 Hz,
    /// so rescanning an hours-long recording on every frame quickly became O(n²).
    private(set) var liveStats = CaptureStats()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var startTime: CFAbsoluteTime = 0
    private var displayTimer: Timer?
    /// Captured events accumulate here (on the main run loop, where the tap
    /// callback fires) and flush into the @Published array at 10 Hz. Per-event
    /// @Published mutations caused a SwiftUI re-render per input event, which
    /// could starve the tap into timeout during fast input.
    private var pending: [RecordedEvent] = []

    /// Key codes the recorder must NOT capture (our own hotkeys).
    var ignoredKeyCodes: Set<UInt16> = []

    var eventCount: Int { events.count }

    deinit {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        displayTimer?.invalidate()
    }

    /// Replace the in-memory event list (used when opening a saved macro).
    func loadEvents(_ new: [RecordedEvent]) {
        events = RecordedEvent.normalized(new)
        liveStats = Self.stats(for: events)
        liveDuration = events.last?.time ?? 0
    }

    // MARK: - Editing

    func deleteEvents(at indices: IndexSet) {
        let sorted = indices.sorted(by: >)
        for i in sorted where events.indices.contains(i) {
            events.remove(at: i)
        }
        liveDuration = events.last?.time ?? 0
    }

    /// Returns the event's index after the time-ordered re-sort so callers can
    /// keep their selection pointing at the edited event.
    @discardableResult
    func updateEvent(at index: Int, with new: RecordedEvent) -> Int? {
        guard events.indices.contains(index) else { return nil }
        events[index] = new
        events.sort { $0.time < $1.time }
        liveDuration = events.last?.time ?? 0
        return events.firstIndex(of: new)
    }

    /// Stretch (>1) or compress (<1) the timestamps of every event.
    func scaleTime(by factor: Double) {
        let f = max(0.01, factor)
        for i in events.indices {
            events[i].time *= f
        }
        liveDuration = events.last?.time ?? 0
    }

    /// Add or subtract a constant from the timestamps of selected events.
    func shiftTime(of indices: IndexSet, by delta: TimeInterval) {
        for i in indices where events.indices.contains(i) {
            events[i].time = max(0, events[i].time + delta)
        }
        events.sort { $0.time < $1.time }
        liveDuration = events.last?.time ?? 0
    }

    /// Drop everything before `index` and rebase remaining timestamps to start at 0.
    func trimBefore(index: Int) {
        guard events.indices.contains(index), index > 0 else { return }
        let cutoff = events[index].time
        events.removeFirst(index)
        for i in events.indices {
            events[i].time = max(0, events[i].time - cutoff)
        }
        liveDuration = events.last?.time ?? 0
    }

    /// Drop everything after `index`.
    func trimAfter(index: Int) {
        guard events.indices.contains(index), index < events.count - 1 else { return }
        events.removeSubrange((index + 1)..<events.count)
        liveDuration = events.last?.time ?? 0
    }

    func clearAll() {
        events.removeAll()
        pending.removeAll()
        liveStats = CaptureStats()
        liveDuration = 0
    }

    /// Insert a wait of `milliseconds` at `index` (shifting subsequent events forward in time).
    /// `index == 0` adds the wait at the very start. `index == events.count` extends the end.
    func insertWait(at index: Int, milliseconds: Double) {
        let delta = max(0, milliseconds / 1000.0)
        guard delta > 0, !events.isEmpty else { return }
        let clamped = max(0, min(index, events.count))
        for i in clamped..<events.count {
            events[i].time += delta
        }
        liveDuration = events.last?.time ?? 0
    }

    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)     |
            (1 << CGEventType.leftMouseUp.rawValue)       |
            (1 << CGEventType.rightMouseDown.rawValue)    |
            (1 << CGEventType.rightMouseUp.rawValue)      |
            (1 << CGEventType.mouseMoved.rawValue)        |
            (1 << CGEventType.leftMouseDragged.rawValue)  |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)           |
            (1 << CGEventType.keyUp.rawValue)             |
            (1 << CGEventType.flagsChanged.rawValue)      |
            (1 << CGEventType.scrollWheel.rawValue)       |
            (1 << CGEventType.otherMouseDown.rawValue)    |
            (1 << CGEventType.otherMouseUp.rawValue)      |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
            recorder.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("TinyRecorder: failed to create event tap. Grant Accessibility & Input Monitoring permission.")
            return false
        }

        // Do not discard the active macro until the system has actually given us
        // a usable tap. Otherwise a denied permission can leave an empty buffer
        // that a later save would write over the user's macro.
        events.removeAll()
        pending.removeAll()
        liveStats = CaptureStats()
        liveDuration = 0
        startTime = CFAbsoluteTimeGetCurrent()
        tap = newTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        isRecording = true
        startDisplayTimer()
        return true
    }

    func stopRecording() {
        guard isRecording else { return }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        stopDisplayTimer()
        flushPending()
        isRecording = false
        liveDuration = events.last?.time ?? 0
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        for event in pending { liveStats.include(event.kind) }
        events.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    private static func stats(for events: [RecordedEvent]) -> CaptureStats {
        var stats = CaptureStats()
        for event in events { stats.include(event.kind) }
        return stats
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isRecording {
                self.flushPending()
                self.liveDuration = CFAbsoluteTimeGetCurrent() - self.startTime
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Re-enable on tap timeout / disable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard let kind = RecordedEvent.Kind(rawValue: Int(type.rawValue)) else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if kind.isKey, ignoredKeyCodes.contains(keyCode) { return }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let loc = event.location
        let recorded = RecordedEvent(
            kind: kind,
            time: elapsed,
            x: loc.x,
            y: loc.y,
            keyCode: keyCode,
            flags: event.flags.rawValue,
            mouseButton: event.getIntegerValueField(.mouseEventButtonNumber),
            clickCount: event.getIntegerValueField(.mouseEventClickState),
            scrollDeltaY: Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
            scrollDeltaX: Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        )

        // The tap's run-loop source is on the main run loop, so this executes
        // on the main thread already — append directly. The display timer
        // flushes into the @Published array at 10 Hz, and stopRecording()
        // flushes synchronously, so no tail events are ever lost.
        if Thread.isMainThread {
            pending.append(recorded)
        } else {
            DispatchQueue.main.async { self.pending.append(recorded) }
        }
    }
}
