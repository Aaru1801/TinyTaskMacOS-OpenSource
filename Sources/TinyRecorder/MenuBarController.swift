import Cocoa
import SwiftUI
import Combine
import UniformTypeIdentifiers

final class MenuBarController: NSObject, NSPopoverDelegate {
    static let focusSearchNotification = Notification.Name("TinyRecorder.focusSearch")
    static let quickRunNotification = Notification.Name("TinyRecorder.quickRun")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var globalClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var editorWC: EditorWindowController?
    private var hud: RecordingHUDController?
    private var countdown: CountdownOverlayController?
    private var welcomeWC: WelcomeWindowController?

    let recorder = Recorder()
    let player = Player()
    let state = AppState()
    let library = MacroLibrary()

    private var globalHotkeyIDs: [UInt32] = []
    private var perMacroHotkeyIDs: [UInt32: UUID] = [:]   // hotkey-id → macro id
    private var dockBadgeTimer: Timer?
    private var playStartTime: CFAbsoluteTime = 0
    private(set) var playingMacroID: UUID?
    /// Playback starts after a tiny window-dismissal grace period. A generation
    /// token makes that pending launch cancellable, so Stop can never race a
    /// delayed synthetic-input session back to life.
    private var playbackRequestGeneration: UInt64 = 0
    private var playbackPending = false
    /// Macros already visited in the current chain run — breaks A→B→A cycles.
    private var chainVisited: Set<UUID> = []
    private var settingsWC: SettingsWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
        configureHUD()
        countdown = CountdownOverlayController()
        observeStateForIcon()
        observeLibraryForHotkeys()
        observeAccessibilityRevocation()
        registerAllHotkeys()
        loadInitialMacroIntoRecorder()
    }

    deinit {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        HotkeyManager.shared.unregisterAll()
        dockBadgeTimer?.invalidate()
    }

    // MARK: - Status item

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = TinyIcons.idle
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("TinyRecorder")
        }
    }

    private func observeStateForIcon() {
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon(); self?.updateDockBadge() }
            .store(in: &cancellables)
        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon(); self?.updateDockBadge() }
            .store(in: &cancellables)
        // Finder-style live progress in the menu bar and Dock. Collapse the
        // 30 Hz player updates to integer percentages before touching AppKit.
        player.$progress
            .map { Int(($0 * 100).rounded(.down)) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon(); self?.updateDockBadge() }
            .store(in: &cancellables)
        player.$currentLoop
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon(); self?.updateDockBadge() }
            .store(in: &cancellables)
        player.$totalLoops
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon(); self?.updateDockBadge() }
            .store(in: &cancellables)
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if recorder.isRecording {
            button.image = TinyIcons.recording
            button.title = " REC"
            button.setAccessibilityLabel("TinyRecorder — recording")
        } else if player.isPlaying {
            button.image = TinyIcons.playing
            button.title = player.isContinuous
                ? " ∞"
                : " \(Int((player.overallProgress * 100).rounded(.down)))%"
            let loop = max(1, player.currentLoop)
            let detail = player.isContinuous
                ? "continuous playback, loop \(loop)"
                : "\(Int((player.overallProgress * 100).rounded(.down))) percent, loop \(loop) of \(max(1, player.totalLoops))"
            button.setAccessibilityLabel("TinyRecorder — playing, \(detail)")
            let playingName = playingMacroID
                .flatMap { id in library.macros.first(where: { $0.id == id })?.name }
                ?? "macro"
            button.toolTip = "Playing \(playingName) — \(detail)"
        } else {
            button.image = TinyIcons.idle
            button.title = ""
            button.setAccessibilityLabel("TinyRecorder")
            button.toolTip = "TinyRecorder"
        }
    }

    private func updateDockBadge() {
        let tile = NSApp.dockTile
        if recorder.isRecording {
            tile.badgeLabel = "●"
            startBadgePulse()
        } else if player.isPlaying {
            stopBadgePulse()
            tile.badgeLabel = player.isContinuous
                ? "∞"
                : "\(Int((player.overallProgress * 100).rounded(.down)))%"
        } else {
            stopBadgePulse()
            tile.badgeLabel = nil
        }
    }

    private func startBadgePulse() {
        guard dockBadgeTimer == nil else { return }
        var visible = true
        dockBadgeTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            visible.toggle()
            NSApp.dockTile.badgeLabel = visible ? "●" : " "
        }
    }

    private func stopBadgePulse() {
        dockBadgeTimer?.invalidate()
        dockBadgeTimer = nil
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let view = PopoverContentView(controller: self, isWindow: false)
            .environmentObject(recorder)
            .environmentObject(player)
            .environmentObject(state)
            .environmentObject(library)

        popover.contentViewController = NSHostingController(rootView: view)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        stopPlaybackBeforePresenting("TinyRecorder")
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.becomeKey()
        installGlobalClickMonitor()
    }

    private func installGlobalClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    // MARK: - HUD

    private func configureHUD() {
        hud = RecordingHUDController(
            recorder: recorder,
            state: state,
            onDiscard: { [weak self] in self?.cancelRecording() },
            onStop:    { [weak self] in self?.toggleRecording() }
        )
    }

    /// Stop recording and throw away the captured events without saving.
    func cancelRecording() {
        guard recorder.isRecording else { return }
        recorder.stopRecording()
        recorder.clearAll()
        // Restore the previously-active macro (if any) into the recorder buffer
        // so we don't leave the editor pointing at nothing.
        if let m = library.currentMacro {
            recorder.loadEvents(m.events)
        }
        hud?.hide()
        state.statusMessage = "Recording discarded."
        SoundController.shared.play(.error)
    }

    // MARK: - Hotkeys

    private func observeLibraryForHotkeys() {
        // Re-register per-macro hotkeys when the library changes. Debounced so a
        // burst of mutations (rename keystrokes, playback stat updates) costs one
        // re-registration, and delayed past objectWillChange so we read the
        // library AFTER the mutation lands. DispatchQueue.main (not RunLoop.main)
        // so it still fires during event-tracking run-loop modes.
        library.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPerMacroHotkeys()
                self?.refreshIgnoredKeyCodes()
            }
            .store(in: &cancellables)
        // Global-hotkey changes go through reapplyHotkeys() explicitly from the
        // settings UI — no state-wide sink needed.
    }

    /// If macOS revokes either input permission while a recording is live, the
    /// event tap goes dead but our UI would keep "recording" forever. Stop
    /// cleanly, keep the partial capture in the buffer, and tell the user.
    private func observeAccessibilityRevocation() {
        Publishers.CombineLatest(state.$accessibilityGranted, state.$inputMonitoringGranted)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accessibilityGranted, inputMonitoringGranted in
                guard let self,
                      (!accessibilityGranted || !inputMonitoringGranted),
                      self.recorder.isRecording else { return }
                self.recorder.stopRecording()
                self.hud?.hide()
                self.state.statusMessage = accessibilityGranted
                    ? "Recording stopped — Input Monitoring permission was revoked."
                    : "Recording stopped — Accessibility permission was revoked."
                SoundController.shared.play(.error)
            }
            .store(in: &cancellables)
    }

    private func registerAllHotkeys() {
        registerGlobalHotkeys()
        refreshPerMacroHotkeys()
        refreshIgnoredKeyCodes()
    }

    private func registerGlobalHotkeys() {
        for id in globalHotkeyIDs { HotkeyManager.shared.unregister(id) }
        globalHotkeyIDs.removeAll()

        let recordH: () -> Void = { [weak self] in self?.toggleRecording() }
        let stopH:   () -> Void = { [weak self] in self?.emergencyStop() }
        let playH:   () -> Void = { [weak self] in self?.play() }

        if let id = HotkeyManager.shared.register(keyCode: state.recordHotkey.keyCode, handler: recordH) {
            globalHotkeyIDs.append(id)
        }
        if let id = HotkeyManager.shared.register(keyCode: state.stopHotkey.keyCode, handler: stopH) {
            globalHotkeyIDs.append(id)
        }
        if let id = HotkeyManager.shared.register(keyCode: state.playHotkey.keyCode, handler: playH) {
            globalHotkeyIDs.append(id)
        }
    }

    private func refreshPerMacroHotkeys() {
        for id in perMacroHotkeyIDs.keys { HotkeyManager.shared.unregister(id) }
        perMacroHotkeyIDs.removeAll()

        for macro in library.macros {
            guard let hk = macro.hotkey else { continue }
            // Skip if conflicts with global hotkeys.
            if hk.keyCode == state.recordHotkey.keyCode ||
               hk.keyCode == state.stopHotkey.keyCode ||
               hk.keyCode == state.playHotkey.keyCode { continue }
            let macroID = macro.id
            if let id = HotkeyManager.shared.register(keyCode: hk.keyCode, handler: { [weak self] in
                self?.playMacroByID(macroID)
            }) {
                perMacroHotkeyIDs[id] = macroID
            }
        }
    }

    private func refreshIgnoredKeyCodes() {
        var ignore: Set<UInt16> = [
            UInt16(state.recordHotkey.keyCode),
            UInt16(state.stopHotkey.keyCode),
            UInt16(state.playHotkey.keyCode),
        ]
        for macro in library.macros {
            if let hk = macro.hotkey {
                ignore.insert(UInt16(hk.keyCode))
            }
        }
        recorder.ignoredKeyCodes = ignore
    }

    func reapplyHotkeys() {
        registerGlobalHotkeys()
        refreshPerMacroHotkeys()
        refreshIgnoredKeyCodes()
    }

    // MARK: - Library glue

    private func loadInitialMacroIntoRecorder() {
        if let m = library.currentMacro {
            recorder.loadEvents(m.events)
        }
    }

    func selectMacro(_ id: UUID) {
        persistCurrentMacroIfNeeded()
        library.select(id: id)
        if let m = library.currentMacro {
            recorder.loadEvents(m.events)
            state.statusMessage = "Loaded \(m.name)."
        }
    }

    func renameMacro(_ id: UUID, to name: String) {
        library.rename(id: id, to: name)
    }

    func duplicateMacro(_ id: UUID) {
        library.duplicate(id: id)
    }

    func deleteMacro(_ id: UUID) {
        // Only reload the recorder buffer when the CURRENT macro was deleted;
        // otherwise we'd wipe unsaved editor edits to an unrelated macro.
        let wasCurrent = (id == library.currentMacroID)
        library.delete(id: id)
        if wasCurrent {
            if let m = library.currentMacro {
                recorder.loadEvents(m.events)
            } else {
                recorder.clearAll()
            }
        }
    }

    func deleteMacros(_ ids: Set<UUID>) {
        let wasCurrent = library.currentMacroID.map { ids.contains($0) } ?? false
        library.deleteMany(ids: ids)
        if wasCurrent {
            if let m = library.currentMacro {
                recorder.loadEvents(m.events)
            } else {
                recorder.clearAll()
            }
        }
    }

    func setMacroLoops(_ id: UUID, to loops: Int) {
        library.setLoops(id: id, loops: loops)
    }

    func setMacroSpeed(_ id: UUID, to speed: Double) {
        library.setSpeed(id: id, speed: speed)
    }

    func setMacroIcon(_ id: UUID, to icon: String?) {
        library.setIcon(id: id, icon: icon)
    }

    func setMacroAccent(_ id: UUID, to color: String?) {
        library.setAccent(id: id, accent: color)
    }

    func setMacroHotkey(_ id: UUID, to hotkey: HotkeyBinding?) {
        library.setHotkey(id: id, hotkey: hotkey)
        refreshPerMacroHotkeys()
        refreshIgnoredKeyCodes()
    }

    func toggleFavorite(_ id: UUID) {
        library.toggleFavorite(id: id)
    }

    func addTag(_ id: UUID, _ tag: String) {
        library.addTag(id: id, tag)
    }

    func removeTag(_ id: UUID, _ tag: String) {
        library.removeTag(id: id, tag)
    }

    func setMacroNotes(_ id: UUID, to notes: String) {
        library.setNotes(id: id, notes: notes)
    }

    func setChain(_ id: UUID, to target: UUID?) {
        library.setChainTo(id: id, target: target)
    }

    private func persistCurrentMacroIfNeeded() {
        // Never persist while a recording is live: the buffer holds the partial
        // in-flight recording, and writing it over the selected macro destroys it.
        guard !recorder.isRecording else { return }
        guard let id = library.currentMacroID else { return }
        library.updateEvents(id: id, events: recorder.events)
    }

    // MARK: - Actions

    func toggleRecording() {
        // A second press during the countdown means "never mind".
        if let countdown, countdown.isActive {
            countdown.cancel()
            state.recordingCountdownActive = false
            state.statusMessage = "Recording cancelled."
            performHaptic(.alignment)
            return
        }
        if recorder.isRecording {
            recorder.stopRecording()
            let count = recorder.eventCount
            if count > 0 {
                let newMacro = library.add(events: recorder.events, loops: state.loops)
                state.statusMessage = "Saved \(newMacro.name) · \(count) events."
                SoundController.shared.play(.recordStop)
                performHaptic(.levelChange)
            } else {
                state.statusMessage = "No events captured."
                performHaptic(.alignment)
                // Don't leave an empty buffer that a later persist would write
                // over the selected macro — restore it.
                if let m = library.currentMacro {
                    recorder.loadEvents(m.events)
                }
            }
            hud?.hide()
        } else {
            beginRecordingFlow()
        }
    }

    /// Wraps the actual recording start with an optional countdown.
    private func beginRecordingFlow() {
        // Fail immediately instead of making the user sit through a countdown
        // before discovering that macOS cannot start the capture.
        guard state.inputMonitoringGranted else {
            state.statusMessage = "Input Monitoring permission is required to record."
            SoundController.shared.play(.error)
            return
        }
        if player.isPlaying || playbackPending { stopPlayback() }
        persistCurrentMacroIfNeeded()
        prepareInterfaceForCapture()

        let secs = state.countdownSeconds
        if secs > 0 {
            state.recordingCountdownActive = true
            countdown?.start(seconds: secs) { [weak self] in
                self?.state.recordingCountdownActive = false
                self?.actuallyStartRecording()
            }
        } else {
            state.recordingCountdownActive = false
            actuallyStartRecording()
        }
    }

    private func actuallyStartRecording() {
        state.recordingCountdownActive = false
        guard state.inputMonitoringGranted else {
            state.statusMessage = "Could not start recording. Grant Input Monitoring permission."
            SoundController.shared.play(.error)
            return
        }
        let ok = recorder.startRecording()
        if ok {
            if state.showRecordingHUD { hud?.show() }
            state.statusMessage = "Recording…"
            SoundController.shared.play(.recordStart)
            performHaptic(.generic)
        } else {
            state.statusMessage = "Could not start recording. Check Input Monitoring permission."
            SoundController.shared.play(.error)
        }
    }

    func stopAll() {
        countdown?.cancel()
        state.recordingCountdownActive = false
        if recorder.isRecording {
            // The native File → Stop command is a normal stop: preserve the
            // recording exactly like the HUD's Stop button does.
            toggleRecording()
            return
        }
        if player.isPlaying || playbackPending { stopPlayback() }
        state.statusMessage = "Stopped."
    }

    /// The global stop hotkey is intentionally stronger than File → Stop. It is
    /// the user's escape hatch from runaway playback and discards an in-flight
    /// capture, matching the explicit "Discard" control in the recording HUD.
    func emergencyStop() {
        countdown?.cancel()
        state.recordingCountdownActive = false
        if recorder.isRecording {
            cancelRecording()
            return
        }
        if player.isPlaying || playbackPending { stopPlayback() }
        state.statusMessage = "Emergency stop."
    }

    private func stopPlayback() {
        playbackRequestGeneration &+= 1
        playbackPending = false
        player.stop()
        performHaptic(.levelChange)
        playingMacroID = nil
        chainVisited.removeAll()
    }

    func play() {
        play(isChained: false)
    }

    private func play(isChained: Bool) {
        guard state.accessibilityGranted else {
            state.statusMessage = "Playback requires Accessibility permission."
            SoundController.shared.play(.error)
            return
        }
        guard !recorder.events.isEmpty else {
            state.statusMessage = "Nothing to play. Record first."
            return
        }
        // A pending record countdown and playback can't coexist — the recorder
        // would capture our own synthetic events.
        if let countdown, countdown.isActive {
            countdown.cancel()
            state.recordingCountdownActive = false
        }
        if recorder.isRecording { toggleRecording() }
        if player.isPlaying || playbackPending { return }
        if !isChained { chainVisited.removeAll() }
        let macro = library.currentMacro
        let name = macro?.name ?? "macro"
        let loops = macro?.loops ?? state.loops
        let speed = macro?.speed ?? state.speed
        let events = recorder.events
        state.statusMessage = loops <= 0
            ? "Playing \(name) on loop…"
            : "Playing \(name) · ×\(loops)…"
        playingMacroID = macro?.id
        if let id = macro?.id { chainVisited.insert(id) }

        playbackRequestGeneration &+= 1
        let request = playbackRequestGeneration
        playbackPending = true

        let startPlayback = { [weak self] in
            guard let self,
                  self.playbackPending,
                  self.playbackRequestGeneration == request else { return }
            self.playbackPending = false
            self.playStartTime = CFAbsoluteTimeGetCurrent()
            SoundController.shared.play(.playStart)
            self.performHaptic(.generic)

            // Completion arrives on the main actor. `finished` is false when the
            // run was cancelled — skip stats, sound, status, and the chain.
            self.player.play(events: events, loops: loops, speed: speed) { [weak self] finished in
                guard let self else { return }
                // Look the chain up LIVE (not from the stale pre-playback copy)
                // so clearing it mid-run is respected.
                let chainID = self.playingMacroID.flatMap { pid in
                    self.library.macros.first(where: { $0.id == pid })?.chainTo
                }
                self.playingMacroID = nil
                guard finished else { return }

                let elapsed = CFAbsoluteTimeGetCurrent() - self.playStartTime
                if let id = macro?.id {
                    self.library.recordPlay(id: id, runTime: elapsed)
                }
                SoundController.shared.play(.playEnd)
                self.performHaptic(.alignment)

                if let id = chainID, let next = self.library.macros.first(where: { $0.id == id }) {
                    guard !self.chainVisited.contains(id) else {
                        self.state.statusMessage = "Chain stopped (loop detected)."
                        return
                    }
                    self.state.statusMessage = "Chaining to \(next.name)…"
                    self.library.select(id: next.id)
                    self.recorder.loadEvents(next.events)
                    self.play(isChained: true)
                } else {
                    self.state.statusMessage = "Playback finished."
                }
            }
        }

        if state.hideDuringPlayback && !isChained {
            prepareInterfaceForPlayback()
            // Let AppKit finish ordering windows out before the first CGEvent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: startPlayback)
        } else {
            if popover.isShown { popover.performClose(nil) }
            startPlayback()
        }
    }

    private func prepareInterfaceForPlayback() {
        prepareInterfaceForCapture()
    }

    /// Clear TinyRecorder's working surfaces out of the target app before either
    /// recording or playback. This deliberately covers *every* app-owned window,
    /// not just our known controllers: an open/save panel left in front could
    /// otherwise receive synthetic typing or clicks from a global playback.
    private func prepareInterfaceForCapture() {
        if popover.isShown { popover.performClose(nil) }

        // End modal sessions first so a cancelled panel cannot keep the app's
        // main run loop nested after it has disappeared.
        if NSApp.modalWindow != nil { NSApp.abortModal() }

        for window in NSApp.windows.filter(\.isVisible) {
            if let panel = window as? NSSavePanel {
                panel.cancel(nil)
            } else if let parent = window.sheetParent {
                parent.endSheet(window, returnCode: .cancel)
            }
            window.orderOut(nil)
        }
    }

    /// Interactive app surfaces must never appear over live synthetic input.
    /// User-invoked panels stop playback first; the global stop hotkey remains
    /// available when the app is hidden.
    private func stopPlaybackBeforePresenting(_ destination: String) {
        guard player.isPlaying || playbackPending else { return }
        stopPlayback()
        state.statusMessage = "Playback stopped to open \(destination)."
    }

    /// Play a specific saved macro by id (used by per-macro hotkeys + library card buttons).
    func playMacroByID(_ id: UUID) {
        guard let macro = library.macros.first(where: { $0.id == id }) else { return }
        if recorder.isRecording { toggleRecording() }
        if player.isPlaying || playbackPending { stopPlayback() }
        persistCurrentMacroIfNeeded()
        chainVisited.removeAll()
        library.select(id: id)
        recorder.loadEvents(macro.events)
        play()
    }

    // MARK: - Save / Open / Export

    /// Import any supported macro file: TinyTask `.rec`, plain-text `.txt`/`.trm`,
    /// or native `.tinyrec`/`.json`. Dispatches on extension, falling back to a
    /// content sniff so a mislabeled file still has a chance.
    func importMacro(at url: URL) {
        stopPlaybackBeforePresenting("Import")
        // Finder drops and file-open events may arrive while a recording is
        // active. Save that capture before replacing the recorder buffer.
        if recorder.isRecording { toggleRecording() }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()

            // Native formats first (preserve full metadata).
            if ext == "tinyrec" || ext == "json" {
                let dec = JSONDecoder()
                if let saved = try? dec.decode(SavedMacro.self, from: data) {
                    DispatchQueue.main.async {
                        var copy = saved
                        copy.id = UUID()
                        copy.hotkey = nil
                        self.library.insert(copy)
                        self.recorder.loadEvents(copy.events)
                        self.state.statusMessage = "Imported \(copy.name)."
                    }
                    return
                }
                if let macro = try? dec.decode(Macro.self, from: data) {
                    finishImport(events: macro.events, name: url.deletingPathExtension().lastPathComponent, warning: nil)
                    return
                }
            }

            // External formats by extension.
            let result: MacroImportResult
            switch ext {
            case "rec":
                result = try TinyTaskImporter.parse(data)
            case "txt", "trm":
                guard let text = String(data: data, encoding: .utf8) else {
                    throw MacroImportError.notTextFormat("file is not UTF-8 text.")
                }
                result = try TextMacroFormat.parse(text)
            default:
                // Unknown extension — sniff: TinyTask .rec is binary multiple-of-20;
                // otherwise try text, then JSON.
                if data.count % 20 == 0, let r = try? TinyTaskImporter.parse(data) {
                    result = r
                } else if let text = String(data: data, encoding: .utf8),
                          let r = try? TextMacroFormat.parse(text) {
                    result = r
                } else if let macro = try? JSONDecoder().decode(Macro.self, from: data) {
                    result = MacroImportResult(events: macro.events, parsed: macro.events.count, skipped: 0, warning: nil)
                } else {
                    throw MacroImportError.unreadable("Unrecognized macro file format.")
                }
            }

            finishImport(events: result.events,
                         name: url.deletingPathExtension().lastPathComponent,
                         warning: result.warning ?? (result.skipped > 0 ? result.summary : nil))
        } catch {
            DispatchQueue.main.async {
                self.state.statusMessage = "Import failed: \(error.localizedDescription)"
                SoundController.shared.play(.error)
            }
        }
    }

    private func finishImport(events: [RecordedEvent], name: String, warning: String?) {
        DispatchQueue.main.async {
            let imported = self.library.add(events: events, name: name)
            self.recorder.loadEvents(imported.events)
            if let warning {
                self.state.statusMessage = "Imported \(imported.name) — \(warning)"
            } else {
                self.state.statusMessage = "Imported \(imported.name) · \(events.count) events."
            }
        }
    }

    /// Export the current macro as a hand-editable `.txt` (TRM) file.
    func exportAsText() {
        guard !recorder.events.isEmpty else {
            state.statusMessage = "Nothing to export."
            return
        }
        stopPlaybackBeforePresenting("Export")
        let panel = NSSavePanel()
        panel.title = "Export as Text"
        let baseName = library.currentMacro?.name ?? defaultMacroName()
        panel.nameFieldStringValue = safeFileName(baseName) + ".txt"
        if let ut = UTType(filenameExtension: "txt") {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        if popover.isShown { popover.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let text = TextMacroFormat.export(self.recorder.events)
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.restrictPermissions(url)
                self.state.statusMessage = "Exported \(url.lastPathComponent)."
            } catch {
                self.state.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Export a specific macro (by id) as a `.txt` (TRM) file.
    func exportMacroAsText(_ id: UUID) {
        guard let macro = library.macros.first(where: { $0.id == id }) else { return }
        stopPlaybackBeforePresenting("Export")
        let panel = NSSavePanel()
        panel.title = "Export \(macro.name) as Text"
        panel.nameFieldStringValue = safeFileName(macro.name) + ".txt"
        if let ut = UTType(filenameExtension: "txt") {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let text = TextMacroFormat.export(macro.events)
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.restrictPermissions(url)
                self.state.statusMessage = "Exported \(url.lastPathComponent)."
            } catch {
                self.state.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func open() {
        stopPlaybackBeforePresenting("Import")
        let panel = NSOpenPanel()
        panel.title = "Import Macro"
        panel.message = "Import a TinyRecorder (.tinyrec), TinyTask (.rec), or text (.txt) macro."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let exts = ["tinyrec", "rec", "txt", "trm"]
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        types.append(.json)
        types.append(.plainText)
        panel.allowedContentTypes = types
        if popover.isShown { popover.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls { self.importMacro(at: url) }
        }
    }

    // MARK: - Export helpers

    /// Strip path separators and leading dots so a macro name can't traverse
    /// directories or hide the exported file when used as a suggested filename.
    private func safeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let unhidden = String(cleaned.drop(while: { $0 == "." }))
        let trimmed = unhidden.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "macro" : trimmed
    }

    /// POSIX single-quote a string for safe embedding in a generated shell script.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Exported macros can contain recorded keystrokes (incl. passwords); keep the
    /// files owner-only so other local users can't read them. `.command` also
    /// needs the execute bit, so 0700 there instead of 0600.
    private func restrictPermissions(_ url: URL, executable: Bool = false) {
        let mode = executable ? 0o700 : 0o600
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func exportAsScript() {
        guard !recorder.events.isEmpty else {
            state.statusMessage = "Nothing to export."
            return
        }
        stopPlaybackBeforePresenting("Export")
        let panel = NSSavePanel()
        panel.title = "Export as Shell Script"
        let baseName = library.currentMacro?.name ?? defaultMacroName()
        panel.nameFieldStringValue = safeFileName(baseName) + ".command"
        if let ut = UTType(filenameExtension: "command") {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        if popover.isShown { popover.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                // Embed the full v3 SavedMacro so name/speed/loops survive the
                // round-trip. Hotkey and chain are meaningless outside this
                // library, so strip them.
                var payload: SavedMacro
                if let current = self.library.currentMacro {
                    payload = current
                    payload.events = self.recorder.events
                } else {
                    payload = SavedMacro(name: self.defaultMacroName(), events: self.recorder.events)
                }
                payload.hotkey = nil
                payload.chainTo = nil
                let json = try JSONEncoder().encode(payload)
                let exec = Bundle.main.executablePath ?? "/Applications/TinyRecorder.app/Contents/MacOS/TinyRecorder"
                let macroLine = json.base64EncodedString()
                let script = """
                #!/bin/bash
                # TinyRecorder self-running macro
                EXEC=\(self.shellQuote(exec))
                if [ ! -x "$EXEC" ]; then
                    echo "TinyRecorder binary not found at $EXEC. Please install TinyRecorder."
                    exit 1
                fi
                TMP=$(mktemp -t tinyrec)
                trap 'rm -f "$TMP"' EXIT
                echo "\(macroLine)" | base64 -D > "$TMP"
                "$EXEC" --play "$TMP"
                """
                try script.write(to: url, atomically: true, encoding: .utf8)
                self.restrictPermissions(url, executable: true)
                self.state.statusMessage = "Exported \(url.lastPathComponent)."
            } catch {
                self.state.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Export a specific macro (from card menu).
    func exportMacroToFile(_ id: UUID) {
        guard let macro = library.macros.first(where: { $0.id == id }) else { return }
        stopPlaybackBeforePresenting("Export")
        let panel = NSSavePanel()
        panel.title = "Export \(macro.name)"
        panel.nameFieldStringValue = safeFileName(macro.name) + ".tinyrec"
        if let ut = UTType(filenameExtension: "tinyrec") {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                let data = try enc.encode(macro)
                try data.write(to: url, options: .atomic)
                self.restrictPermissions(url)
                self.state.statusMessage = "Exported \(url.lastPathComponent)."
            } catch {
                self.state.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func persistEdits() {
        persistCurrentMacroIfNeeded()
        state.statusMessage = "Saved."
    }

    private func defaultMacroName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "macro-" + f.string(from: Date())
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // MARK: - Editor

    func openEditor() {
        stopPlaybackBeforePresenting("the editor")
        if popover.isShown { popover.performClose(nil) }
        if editorWC == nil {
            let view = EditorView(controller: self)
                .environmentObject(recorder)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(state)
            editorWC = EditorWindowController(rootView: view)
        }
        NSApp.activate(ignoringOtherApps: true)
        editorWC?.showWindow(nil)
        editorWC?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Appearance (Dock vs menu-bar-only)

    /// Apply the persisted appearance mode to the activation policy. Call on launch.
    func applyAppearanceMode() {
        NSApp.setActivationPolicy(state.menuBarOnly ? .accessory : .regular)
    }

    /// Switch between Dock app (`.regular`) and menu-bar-only (`.accessory`) live.
    func setMenuBarOnly(_ menuBarOnly: Bool) {
        guard menuBarOnly != state.menuBarOnly else { return }
        stopPlaybackBeforePresenting("appearance settings")
        state.menuBarOnly = menuBarOnly
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if menuBarOnly {
            // No Dock icon now — flash the menu-bar popover so the control surface
            // is discoverable, then leave the user there.
            state.statusMessage = "Menu-bar only. Click the menu-bar icon to open TinyRecorder."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showPopoverProgrammatically()
            }
        } else {
            // Dock icon returns — bring the app forward and show the library window.
            NSApp.activate(ignoringOtherApps: true)
            showMainWindow()
        }
    }

    /// Bring up the menu-bar popover from code (used after switching to menu-bar-only).
    func showPopoverProgrammatically() {
        guard !popover.isShown else { return }
        showPopover()
    }

    /// Opens the main library window (forwarded from AppDelegate so the controller
    /// can show it after an appearance switch).
    var showMainWindowHandler: (() -> Void)?
    func showMainWindow() {
        stopPlaybackBeforePresenting("the library")
        showMainWindowHandler?()
    }

    /// Present Quick Run in the surface appropriate to the user's current app
    /// mode, then notify that surface after AppKit has made it visible.
    func presentQuickRun() {
        guard !recorder.isRecording, !state.recordingCountdownActive else {
            state.statusMessage = "Quick Run is unavailable during recording."
            performHaptic(.alignment)
            return
        }
        stopPlaybackBeforePresenting("Quick Run")
        let targetIsWindow = !state.menuBarOnly
        if state.menuBarOnly {
            showPopoverProgrammatically()
        } else {
            if popover.isShown { popover.performClose(nil) }
            showMainWindow()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.quickRunNotification,
                object: NSNumber(value: targetIsWindow)
            )
        }
    }

    // MARK: - Settings window

    func showSettingsWindow() {
        stopPlaybackBeforePresenting("Settings")
        if popover.isShown { popover.performClose(nil) }
        if settingsWC == nil {
            settingsWC = SettingsWindowController(controller: self)
        }
        settingsWC?.show()
    }

    // MARK: - Onboarding

    func showWelcomeIfNeeded() {
        guard !state.onboardingComplete else { return }
        if welcomeWC == nil {
            // Closing the window by ANY means (Done button or the red close
            // button) completes onboarding — never leave a half-finished state.
            welcomeWC = WelcomeWindowController(controller: self, onDone: { [weak self] in
                self?.welcomeWC?.window?.performClose(nil)
            }, onClose: { [weak self] in
                self?.state.onboardingComplete = true
                self?.welcomeWC = nil
                if self?.state.menuBarOnly == true {
                    self?.showPopoverProgrammatically()
                } else {
                    self?.showMainWindow()
                }
            })
        }
        welcomeWC?.show()
    }

    func showWelcome() {
        stopPlaybackBeforePresenting("Welcome")
        // Force-show even if already complete.
        welcomeWC = WelcomeWindowController(controller: self, onDone: { [weak self] in
            self?.welcomeWC?.window?.performClose(nil)
        }, onClose: { [weak self] in
            self?.welcomeWC = nil
        })
        welcomeWC?.show()
    }

    // MARK: - Termination

    /// Called from applicationWillTerminate so Cmd-Q never loses work:
    /// a live recording is stopped and saved, pending editor edits persist.
    func prepareForTermination() {
        countdown?.cancel()
        state.recordingCountdownActive = false
        if player.isPlaying || playbackPending { stopPlayback() }
        if recorder.isRecording {
            recorder.stopRecording()
            if recorder.eventCount > 0 {
                library.add(events: recorder.events, loops: state.loops)
            }
        } else {
            persistCurrentMacroIfNeeded()
        }
        library.save()
        library.flushSaves()
    }

    func openAccessibilityPrefs() {
        stopPlaybackBeforePresenting("System Settings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringPrefs() {
        stopPlaybackBeforePresenting("System Settings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func showAbout() {
        stopPlaybackBeforePresenting("About")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func showHelp() {
        stopPlaybackBeforePresenting("Help")
        if let url = URL(string: "https://github.com/Aaru1801/TinyTask-macOS#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        NSApp.terminate(nil)   // prepareForTermination runs via applicationWillTerminate
    }
}

// MARK: - Icons

enum TinyIcons {
    private static func make(_ name: String, description: String, color: NSColor? = nil) -> NSImage? {
        let baseCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let cfg: NSImage.SymbolConfiguration
        if let color {
            cfg = baseCfg.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        } else {
            cfg = baseCfg
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = (color == nil)
        return img
    }
    static var idle: NSImage? { make("record.circle", description: "TinyRecorder") }
    static var recording: NSImage? { make("record.circle.fill", description: "TinyRecorder — recording", color: .systemRed) }
    static var playing: NSImage? { make("play.circle.fill", description: "TinyRecorder — playing", color: .systemGreen) }
}
