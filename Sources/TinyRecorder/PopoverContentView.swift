import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Accent color palette

/// Maps a stored accent name to a vibrant signal color (the design palette).
/// `nil`/unknown fall back to the brand red.
func cardAccentColor(for accent: String?) -> Color {
    Brand.accent(accent)
}

/// Named accent options shown in the per-macro Color submenu.
let accentNames: [String] = [
    "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Indigo", "Purple", "Pink", "Gray",
]

// MARK: - Root view

struct PopoverContentView: View {
    let controller: MenuBarController
    /// `true` when hosted in the resizable Dock window, `false` for the menu-bar popover.
    var isWindow: Bool = false

    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var player: Player
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: MacroLibrary

    @State private var search: String = ""
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var selection: Set<UUID> = []
    @State private var filter: LibraryFilter = .all
    @State private var showAssignHotkey: SavedMacro?
    @State private var showAddTag: SavedMacro?
    @State private var showNotesFor: SavedMacro?
    @State private var newTagText: String = ""
    @State private var notesDraft: String = ""
    @State private var isDroppingFiles = false
    @State private var showQuickRun = false
    @FocusState private var searchFocused: Bool
    /// Deterministic anchor for shift-click range selection.
    @State private var lastAnchorID: UUID?

    private var filteredMacros: [SavedMacro] {
        library.macros(for: filter, search: search)
    }

    var body: some View {
        ZStack {
            ZStack {
                VisualEffectBackground(material: isWindow ? .windowBackground : .popover, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                if isWindow {
                    VStack(spacing: 0) {
                        // Custom titlebar strip: wordmark centered, traffic lights
                        // live in the leading inset.
                        ZStack {
                            Wordmark(size: 12)
                        }
                        .frame(height: 32)
                        .frame(maxWidth: .infinity)
                        .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
                        .overlay(Divider().opacity(0.5), alignment: .bottom)

                        HStack(spacing: 0) {
                            LibrarySidebar(controller: controller, filter: $filter)
                                .frame(width: 160)
                            Divider().opacity(0.5)
                            libraryColumn
                        }
                    }
                } else {
                    libraryColumn
                }

                // File-drop overlay (shown only while user is dragging macro files in)
                if isDroppingFiles {
                    ZStack {
                        Color.accentColor.opacity(0.10)
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(.tint)
                            Text("Drop to import")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("Drop a .tinyrec, TinyTask .rec, or .txt macro.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(0.7),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                            )
                            .padding(8)
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(!showQuickRun)
            .accessibilityHidden(showQuickRun)

            if showQuickRun {
                QuickRunPalette(
                    controller: controller,
                    compact: !isWindow,
                    onDismiss: { withAnimation(Brand.spring) { showQuickRun = false } }
                )
                .environmentObject(recorder)
                .environmentObject(player)
                .environmentObject(state)
                .environmentObject(library)
                .transition(.scale(scale: 0.965).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .frame(
            minWidth: isWindow ? 620 : 400,
            idealWidth: isWindow ? 720 : 400,
            maxWidth: isWindow ? .infinity : 400,
            minHeight: isWindow ? 390 : 500,
            idealHeight: isWindow ? 460 : 500,
            maxHeight: isWindow ? .infinity : 500
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.accessibilityGranted)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.inputMonitoringGranted)
        .animation(Brand.spring, value: state.recordingCountdownActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filteredMacros.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filter)
        .onChange(of: filter) { selection.removeAll() }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarController.focusSearchNotification)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarController.quickRunNotification)) { notification in
            guard let targetIsWindow = (notification.object as? NSNumber)?.boolValue,
                  targetIsWindow == isWindow else { return }
            withAnimation(Brand.spring) { showQuickRun = true }
        }
        .sheet(item: $showAssignHotkey) { macro in
            HotkeyAssignmentSheet(
                macro: macro,
                currentHotkey: macro.hotkey,
                allHotkeys: usedHotkeys,
                onSave: { binding in
                    controller.setMacroHotkey(macro.id, to: binding)
                    showAssignHotkey = nil
                },
                onCancel: { showAssignHotkey = nil }
            )
        }
        .sheet(item: $showAddTag) { macro in
            TagAssignmentSheet(
                macro: macro,
                allTags: library.allTags,
                tagText: $newTagText,
                onAdd: { tag in
                    controller.addTag(macro.id, tag)
                    newTagText = ""
                },
                onRemove: { tag in controller.removeTag(macro.id, tag) },
                onDone: { showAddTag = nil; newTagText = "" }
            )
        }
        .sheet(item: $showNotesFor) { macro in
            NotesSheet(
                macro: macro,
                text: $notesDraft,
                onSave: {
                    controller.setMacroNotes(macro.id, to: notesDraft)
                    showNotesFor = nil
                },
                onCancel: { showNotesFor = nil }
            )
            .onAppear { notesDraft = macro.notes }
        }
        .animation(.easeInOut(duration: 0.15), value: isDroppingFiles)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDroppingFiles) { providers in
            handleFileDrop(providers: providers)
        }
    }

    /// Importable macro file extensions accepted via drag-and-drop.
    private static let importableExts: Set<String> = ["tinyrec", "rec", "txt", "trm", "json"]

    /// Returns `true` if any provider was a macro file URL we accepted.
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, Self.importableExts.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async {
                    controller.importMacro(at: url)
                }
            }
        }
        return accepted
    }

    private var usedHotkeys: Set<UInt32> {
        var s: Set<UInt32> = [
            state.recordHotkey.keyCode,
            state.stopHotkey.keyCode,
            state.playHotkey.keyCode,
        ]
        for m in library.macros { if let hk = m.hotkey { s.insert(hk.keyCode) } }
        return s
    }

    @ViewBuilder
    private var libraryColumn: some View {
        VStack(spacing: 0) {
            LibraryHeader(
                controller: controller,
                search: $search,
                searchFocused: $searchFocused,
                isWindow: isWindow,
                macroCount: library.macros.count,
                onQuickRun: { withAnimation(Brand.spring) { showQuickRun = true } }
            )
            .padding(.horizontal, isWindow ? 10 : 12)
            .padding(.top, isWindow ? 9 : 10)
            .padding(.bottom, isWindow ? 9 : 7)
            .background(Color.primary.opacity(isWindow ? 0.018 : 0))
            .overlay(Divider().opacity(isWindow ? 0.35 : 0), alignment: .bottom)

            if hasLiveActivity {
                ActivityCenterView(controller: controller, compact: !isWindow)
                    .padding(.horizontal, isWindow ? 10 : 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            #if !HIDE_PERMISSION_BANNER
            if !state.accessibilityGranted || !state.inputMonitoringGranted {
                PermissionBanner(
                    controller: controller,
                    accessibilityGranted: state.accessibilityGranted,
                    inputMonitoringGranted: state.inputMonitoringGranted
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif

            if !visibleSelection.isEmpty {
                SelectionToolbar(
                    selectionCount: visibleSelection.count,
                    onClearSelection: { selection.removeAll() },
                    onDelete: {
                        controller.deleteMacros(visibleSelection)
                        selection.removeAll()
                    },
                    onExport: {
                        for id in visibleSelection { controller.exportMacroToFile(id) }
                    },
                    onAddTag: {
                        if let m = library.macros.first(where: { $0.id == visibleSelection.first }) {
                            showAddTag = m
                        }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Filter chips — brings the window sidebar's filters to the popover.
            if !isWindow {
                FilterChipRow(filter: $filter, tags: library.allTags)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if filteredMacros.isEmpty && hasLiveActivity {
                Spacer(minLength: 0)
            } else if filteredMacros.isEmpty {
                EmptyState(
                    filter: filter,
                    hasSearch: !search.isEmpty,
                    countdownSeconds: state.countdownSeconds,
                    onPrimaryAction: {
                        if !search.isEmpty {
                            search = ""
                        } else if filter == .all {
                            controller.toggleRecording()
                        } else {
                            filter = .all
                        }
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Computed once for the whole grid, not per card.
                let allChainCandidates = library.macros.map { ($0.id, $0.name) }
                ScrollView {
                    // Section label, mockup-style.
                    HStack {
                        Text(filter.label.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Text("\(filteredMacros.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 6)

                    LazyVGrid(
                        columns: isWindow
                            ? [GridItem(.adaptive(minimum: 225, maximum: 310), spacing: 8)]
                            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(filteredMacros) { macro in
                            let activePlayback = player.isPlaying && macro.id == controller.playingMacroID
                            MacroCard(
                                macro: macro,
                                isCurrent: macro.id == library.currentMacroID,
                                isPlaying: activePlayback,
                                playProgress: activePlayback
                                    ? (player.isContinuous ? player.progress : player.overallProgress)
                                    : 0,
                                currentLoop: activePlayback ? player.currentLoop : 0,
                                totalLoops: activePlayback ? player.totalLoops : 1,
                                isSelected: selection.contains(macro.id),
                                isRenaming: renamingID == macro.id,
                                renameText: $renameText,
                                onSelect: { event in
                                    handleCardSelect(macro: macro, event: event)
                                },
                                onPlay: {
                                    selection.removeAll()
                                    if activePlayback {
                                        controller.stopAll()
                                    } else {
                                        controller.playMacroByID(macro.id)
                                    }
                                },
                                onEdit: {
                                    selection.removeAll()
                                    controller.selectMacro(macro.id)
                                    controller.openEditor()
                                },
                                onDelete: {
                                    selection.remove(macro.id)
                                    controller.deleteMacro(macro.id)
                                },
                                onDuplicate: {
                                    controller.duplicateMacro(macro.id)
                                },
                                onExport: {
                                    controller.exportMacroToFile(macro.id)
                                },
                                onExportText: {
                                    controller.exportMacroAsText(macro.id)
                                },
                                onStartRename: {
                                    renamingID = macro.id
                                    renameText = macro.name
                                },
                                onCommitRename: {
                                    if let id = renamingID {
                                        controller.renameMacro(id, to: renameText)
                                    }
                                    renamingID = nil
                                },
                                onSetLoops: { newLoops in
                                    controller.setMacroLoops(macro.id, to: newLoops)
                                },
                                onAssignHotkey: { showAssignHotkey = macro },
                                onClearHotkey: { controller.setMacroHotkey(macro.id, to: nil) },
                                onToggleFavorite: { controller.toggleFavorite(macro.id) },
                                onSetIcon: { icon in controller.setMacroIcon(macro.id, to: icon) },
                                onAddTag: { showAddTag = macro },
                                onDragMove: { fromID, toID in
                                    library.move(id: fromID, before: toID)
                                },
                                onOpenNotes: { showNotesFor = macro },
                                onSetSpeed: { speed in
                                    controller.setMacroSpeed(macro.id, to: speed)
                                },
                                onSetAccent: { color in
                                    controller.setMacroAccent(macro.id, to: color)
                                },
                                onSetChain: { target in
                                    controller.setChain(macro.id, to: target)
                                },
                                chainCandidates: allChainCandidates,
                                chainTargetName: macro.chainTo
                                    .flatMap { id in library.macros.first(where: { $0.id == id })?.name }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
                }
            }

            // Transient status / feedback line (auto-clears).
            if !state.statusMessage.isEmpty && !hasLiveActivity {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(state.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .transition(.opacity)
                .onAppear { scheduleStatusClear() }
                .onChange(of: state.statusMessage) { scheduleStatusClear() }
            }

            if !isWindow {
                Divider().opacity(0.5)

                LibraryFooter(controller: controller, state: state)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
    }

    /// Clears the status line a few seconds after the latest message.
    private func scheduleStatusClear() {
        let snapshot = state.statusMessage
        guard !snapshot.isEmpty, !recorder.isRecording, !player.isPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if state.statusMessage == snapshot {
                withAnimation(.easeOut(duration: 0.25)) { state.statusMessage = "" }
            }
        }
    }

    private var hasLiveActivity: Bool {
        state.recordingCountdownActive || recorder.isRecording || player.isPlaying
    }

    /// Selection restricted to what the current filter/search actually shows —
    /// bulk actions must never touch macros the user can't see.
    private var visibleSelection: Set<UUID> {
        selection.intersection(filteredMacros.map(\.id))
    }

    private func handleCardSelect(macro: SavedMacro, event: NSEvent.ModifierFlags) {
        if event.contains(.command) {
            // Toggle in selection
            if selection.contains(macro.id) {
                selection.remove(macro.id)
            } else {
                selection.insert(macro.id)
            }
            lastAnchorID = macro.id
        } else if event.contains(.shift), let lastID = lastAnchorID ?? library.currentMacroID,
                  let lastIdx = filteredMacros.firstIndex(where: { $0.id == lastID }),
                  let thisIdx = filteredMacros.firstIndex(where: { $0.id == macro.id }) {
            let lo = min(lastIdx, thisIdx)
            let hi = max(lastIdx, thisIdx)
            selection.formUnion(filteredMacros[lo...hi].map(\.id))
        } else {
            selection.removeAll()
            lastAnchorID = macro.id
            controller.selectMacro(macro.id)
        }
    }
}

// MARK: - Filter chips (popover mode)

private struct FilterChipRow: View {
    @Binding var filter: LibraryFilter
    let tags: [String]

    private let primaryFilters: [LibraryFilter] = [.all, .favorites, .recent]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(primaryFilters, id: \.self) { item in
                    chip(item)
                }
                if !tags.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 14)
                    ForEach(tags, id: \.self) { t in
                        chip(.tag(t))
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    // Filter chips are content-layer controls: plain capsules, with only the
    // selected one carrying the brand accent (a single emphasis, not glass).
    @ViewBuilder
    private func chip(_ item: LibraryFilter) -> some View {
        let selected = filter == item
        Button {
            withAnimation(Brand.spring) { filter = item }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(item.label)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.redGradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(HoverPressButtonStyle())
        .interactiveLift3D(intensity: 0.72, cornerRadius: 999)
        .accessibilityLabel("Filter: \(item.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar (window mode)

private struct LibrarySidebar: View {
    let controller: MenuBarController
    @Binding var filter: LibraryFilter
    @EnvironmentObject var library: MacroLibrary
    @EnvironmentObject var state: AppState

    private let filterItems: [LibraryFilter] = [.all, .favorites, .recent, .mostPlayed, .withHotkey]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("MACROS")
                    ForEach(filterItems, id: \.self) { item in
                        sidebarRow(item)
                    }

                    if !library.allTags.isEmpty {
                        sectionHeader("TAGS")
                            .padding(.top, 10)
                        ForEach(library.allTags, id: \.self) { t in
                            sidebarRow(.tag(t))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.45)
            LibraryFooter(controller: controller, state: state)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func sidebarRow(_ item: LibraryFilter) -> some View {
        let selected = filter == item
        let count: Int = library.macros(for: item, search: "").count
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { filter = item }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(item.label)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .interactiveLift3D(intensity: 0.62, cornerRadius: 6)
    }
}

// MARK: - Header

private struct LibraryHeader: View {
    let controller: MenuBarController
    @Binding var search: String
    var searchFocused: FocusState<Bool>.Binding
    let isWindow: Bool
    let macroCount: Int
    let onQuickRun: () -> Void
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var player: Player
    @EnvironmentObject var state: AppState

    private var statusText: String {
        if state.recordingCountdownActive { return "Preparing to record…" }
        if recorder.isRecording { return "Recording…" }
        if player.isPlaying     { return "Playing…" }
        return "Idle · \(macroCount) macro\(macroCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 8) {
            // Brand row (popover only — the window shows the wordmark in its titlebar)
            if !isWindow {
                HStack(spacing: 10) {
                    BrandMark(size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Wordmark(size: 13)
                        HStack(spacing: 5) {
                            if recorder.isRecording { RecDot(size: 6) }
                            Text(statusText)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { controller.showSettingsWindow() } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)))
                    }
                    .buttonStyle(HoverPressButtonStyle())
                    .interactiveLift3D(intensity: 0.72, cornerRadius: 8)
                    .accessibilityLabel("Settings")
                }
            }

            if isWindow {
                HStack(alignment: .center, spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Macros")
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 5) {
                            if recorder.isRecording { RecDot(size: 6) }
                            Text(statusText)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()

                    Spacer(minLength: 4)
                    quickRunButton
                    searchField
                        .frame(minWidth: 110, idealWidth: 190, maxWidth: 240)
                        .layoutPriority(1)
                    importButton
                    playbackButton
                    compactRecordButton
                }
            } else {
                HStack(spacing: 7) {
                    compactRecordButton
                        .frame(maxWidth: .infinity)
                    playbackButton
                    quickRunButton
                    importButton
                }
                HStack(spacing: 8) {
                    searchField
                }
            }
        }
    }

    private var compactRecordButton: some View {
        Button { controller.toggleRecording() } label: {
            Label(
                state.recordingCountdownActive ? "Cancel" : (recorder.isRecording ? "Stop" : "Record"),
                systemImage: state.recordingCountdownActive
                    ? "xmark"
                    : (recorder.isRecording ? "stop.fill" : "record.circle")
            )
            .font(.system(size: 11.5, weight: .semibold))
            .frame(minWidth: isWindow ? 70 : 100, maxWidth: isWindow ? 84 : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(Brand.red500)
        .help(recordControlHelp)
        .accessibilityLabel(recordControlLabel)
        .interactiveLift3D(intensity: 0.86, cornerRadius: 8)
    }

    private var playbackButton: some View {
        headerIconButton(
            systemImage: player.isPlaying ? "stop.fill" : "play.fill",
            tint: player.isPlaying ? Brand.red500 : Brand.sigGreen,
            help: player.isPlaying ? "Stop playback (\(state.stopHotkey.name))" : "Play current macro (\(state.playHotkey.name))",
            disabled: !player.isPlaying && (recorder.events.isEmpty || recorder.isRecording || state.recordingCountdownActive)
        ) {
            if player.isPlaying { controller.stopAll() }
            else { controller.play() }
        }
    }

    private var importButton: some View {
        headerIconButton(
            systemImage: "square.and.arrow.down",
            tint: Brand.sigBlue,
            help: "Import macro (⌘O)"
        ) {
            controller.open()
        }
    }

    private var quickRunButton: some View {
        headerIconButton(
            systemImage: "bolt.fill",
            tint: Brand.sigViolet,
            help: recorder.isRecording || state.recordingCountdownActive
                ? "Quick Run is unavailable during recording"
                : "Quick Run (⌘K)",
            disabled: recorder.isRecording || state.recordingCountdownActive,
            action: onQuickRun
        )
    }

    private func headerIconButton(
        systemImage: String,
        tint: Color,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.11))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
                )
        }
        .buttonStyle(HoverPressButtonStyle())
        .interactiveLift3D(intensity: 0.86, cornerRadius: 7)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var recordControlLabel: String {
        if state.recordingCountdownActive { return "Cancel recording countdown" }
        return recorder.isRecording ? "Stop recording" : "Start recording"
    }

    private var recordControlHelp: String {
        let action = state.recordingCountdownActive
            ? "Cancel countdown"
            : (recorder.isRecording ? "Stop recording" : "Start recording")
        return "\(action) (\(state.recordHotkey.name))"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search macros", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(searchFocused)
            if search.isEmpty {
                KeyCapView(text: "⌘F", size: .sm)
            } else {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: isWindow ? 8 : 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: isWindow ? 8 : 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        )
        .interactiveLift3D(intensity: 0.34, cornerRadius: isWindow ? 8 : 12)
    }
}

// MARK: - Selection toolbar

private struct SelectionToolbar: View {
    let selectionCount: Int
    let onClearSelection: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    let onAddTag: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClearSelection) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
            .interactiveLift3D(intensity: 0.46, cornerRadius: 6)
            Text("\(selectionCount) selected")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button("Add Tag…", systemImage: "tag", action: onAddTag)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectionCount != 1)
                .interactiveLift3D(intensity: 0.54, cornerRadius: 7)

            Button("Export", systemImage: "square.and.arrow.up", action: onExport)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .interactiveLift3D(intensity: 0.54, cornerRadius: 7)

            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .interactiveLift3D(intensity: 0.54, cornerRadius: 7)
            .confirmationDialog(
                "Delete \(selectionCount) macro\(selectionCount == 1 ? "" : "s")?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.40), lineWidth: 0.6)
                )
        )
    }
}

// MARK: - Macro card

private struct MacroCard: View {
    let macro: SavedMacro
    let isCurrent: Bool
    let isPlaying: Bool
    let playProgress: Double
    let currentLoop: Int
    let totalLoops: Int
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String

    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onExportText: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onSetLoops: (Int) -> Void
    let onAssignHotkey: () -> Void
    let onClearHotkey: () -> Void
    let onToggleFavorite: () -> Void
    let onSetIcon: (String?) -> Void
    let onAddTag: () -> Void
    let onDragMove: (UUID, UUID) -> Void
    let onOpenNotes: () -> Void
    let onSetSpeed: (Double) -> Void
    let onSetAccent: (String?) -> Void
    let onSetChain: (UUID?) -> Void
    let chainCandidates: [(UUID, String)]
    let chainTargetName: String?

    @State private var hovered = false
    @State private var dragOver = false
    @State private var showCustomSpeed = false
    @State private var customSpeedText = ""
    @State private var confirmDelete = false
    @FocusState private var cardFocused: Bool
    @FocusState private var renameFocused: Bool

    private var durationText: String {
        let d = macro.duration
        let m = Int(d) / 60
        let s = Int(d) % 60
        let cs = Int((d - floor(d)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private var strokeColor: Color {
        if isPlaying { return cardAccentColor(for: macro.accent).opacity(0.95) }
        if isCurrent { return cardAccentColor(for: macro.accent).opacity(0.55) }
        if isSelected { return Brand.sigBlue.opacity(0.85) }
        if dragOver { return Color.accentColor.opacity(0.6) }
        return Color.primary.opacity(0.10)
    }

    var body: some View {
        styledCard
            .onHover { hovered = $0 }
            .interactiveLift3D(intensity: 0.72, cornerRadius: 12)
            .onTapGesture {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                onSelect(mods)
            }
            // Keyboard + assistive access: the card is one focusable element with
            // every action exposed; Delete key removes, Escape commits a rename.
            .focusable()
            .focused($cardFocused)
            .focusEffectDisabled()
            .onDeleteCommand { confirmDelete = true }
            .onExitCommand {
                if isRenaming { onCommitRename() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect([]) }
            .accessibilityAction(named: "Play") { onPlay() }
            .accessibilityAction(named: "Edit") { onEdit() }
            .accessibilityAction(named: macro.favorite ? "Remove favorite" : "Add favorite") { onToggleFavorite() }
            .accessibilityAction(named: "Rename") { onStartRename() }
            .accessibilityAction(named: "Delete") { confirmDelete = true }
            .contextMenu { cardMenuItems }
            .alert("Custom playback speed", isPresented: $showCustomSpeed) {
                TextField("e.g. 1.75", text: $customSpeedText)
                Button("Cancel", role: .cancel) {}
                Button("Set") {
                    let trimmed = customSpeedText.trimmingCharacters(in: .whitespaces)
                    if let v = Double(trimmed) {
                        onSetSpeed(max(0.1, min(10.0, v)))
                    }
                }
            } message: {
                Text("Multiplier between 0.1× and 10×.")
            }
            .confirmationDialog(
                "Delete \(macro.name)?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This macro will be permanently removed.")
            }
            .onDrag {
                NSItemProvider(object: macro.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.text], isTargeted: $dragOver) { providers in
                providers.first?.loadObject(ofClass: NSString.self) { (item, _) in
                    if let s = item as? String, let id = UUID(uuidString: s), id != macro.id {
                        DispatchQueue.main.async { onDragMove(id, macro.id) }
                    }
                }
                return true
            }
    }

    private var styledCard: some View {
        cardContent
            .padding(10)
            .frame(height: macro.tags.isEmpty ? 92 : 112)
            .background { cardBackground }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: (isPlaying || isCurrent || isSelected) ? 1.2 : 0.5)
            )
            .overlay(alignment: .bottomLeading) {
                if isPlaying {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(LinearGradient(
                                colors: [cardAccentColor(for: macro.accent).opacity(0.75),
                                         cardAccentColor(for: macro.accent)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(5, proxy.size.width * max(0, min(1, playProgress))), height: 2.5)
                            .shadow(color: cardAccentColor(for: macro.accent).opacity(0.45), radius: 3)
                            .animation(.linear(duration: 0.10), value: playProgress)
                    }
                    .frame(height: 2.5)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1.5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(cardFocused ? 0.9 : 0), lineWidth: 2.5)
            )
            .shadow(
                color: .black.opacity(hovered ? 0.13 : 0.055),
                radius: hovered ? 5 : 2,
                y: hovered ? 2 : 1
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hovered)
            .animation(Brand.spring, value: isCurrent)
            .animation(Brand.spring, value: isSelected)
            .animation(Brand.spring, value: cardFocused)
            .animation(Brand.spring, value: dragOver)
    }

    /// The card surface. Cards are the CONTENT layer, so per Apple's Liquid Glass
    /// guidance they are NOT glass — glass belongs to the floating control layer
    /// (Record button, HUD, countdown). A card is an opaque adaptive surface;
    /// current state is a restrained accent fill + the stroke overlay,
    /// never a heavy colored wash.
    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint = cardAccentColor(for: macro.accent)
        ZStack {
            shape.fill(Color(nsColor: .controlBackgroundColor))
            shape.fill(tint.opacity(isPlaying ? 0.10 : (isCurrent ? 0.055 : (isSelected ? 0.10 : 0))))
        }
    }

    @ViewBuilder
    private var cardMenuItems: some View {
        Button("Play") { onPlay() }
        Button("Edit…") { onEdit() }
        Divider()
        Button("Rename…") { onStartRename() }
        Button(macro.favorite ? "Unfavorite" : "Favorite") { onToggleFavorite() }
        Divider()
        Button("Notes…") { onOpenNotes() }
        Button("Add Tag…") { onAddTag() }
        Button("Assign Hotkey…") { onAssignHotkey() }
        if macro.hotkey != nil {
            Button("Clear Hotkey") { onClearHotkey() }
        }
        Divider()
        speedSubmenu()
        colorSubmenu()
        chainSubmenu()
        Divider()
        Button("Duplicate") { onDuplicate() }
        Menu("Export") {
            Button("As TinyRecorder File…") { onExport() }
            Button("As Text…") { onExportText() }
        }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete = true }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row
            HStack(spacing: 6) {
                MacroIconView(macro: macro, onSetIcon: onSetIcon)

                if isRenaming {
                    TextField("Name", text: $renameText, onCommit: onCommitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .focused($renameFocused)
                        .onAppear { renameFocused = true }
                } else {
                    Text(macro.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if !macro.notes.isEmpty {
                    Button(action: onOpenNotes) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Has notes — click to open")
                    .interactiveLift3D(intensity: 0.38, cornerRadius: 5)
                }

                if let hk = macro.hotkey {
                    Button(action: onAssignHotkey) {
                        KeyCapView(text: hk.name)
                    }
                    .buttonStyle(.plain)
                    .help("Hotkey: \(hk.name) — click to change")
                    .interactiveLift3D(intensity: 0.38, cornerRadius: 5)
                }

                Button(action: onToggleFavorite) {
                    Image(systemName: macro.favorite ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(macro.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help(macro.favorite ? "Unstar" : "Star")
                .accessibilityLabel(macro.favorite ? "Remove favorite" : "Add favorite")
                .interactiveLift3D(intensity: 0.38, cornerRadius: 5)
            }

            // Tiny waveform
            MiniWaveform(
                events: macro.events,
                progress: isPlaying ? playProgress : nil,
                progressTint: cardAccentColor(for: macro.accent)
            )
                .frame(height: 16)

            // Tags row (if any)
            if !macro.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(macro.tags, id: \.self) { t in
                            Text(t)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.accentColor.opacity(0.18))
                                )
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .frame(height: 16)
            }

            // Bottom row: meta + actions. These controls live INSIDE a content
            // card, so they stay plain (no glass) — glass is reserved for the
            // floating control layer.
            HStack(spacing: 4) {
                metaRow
                Spacer()
                CardActionButton(
                    systemImage: isPlaying ? "stop.fill" : "play.fill",
                    tint: isPlaying ? Brand.red500 : Brand.sigGreen,
                    label: isPlaying ? "Stop \(macro.name)" : "Play \(macro.name)"
                ) { onPlay() }
                    .help(isPlaying ? "Stop" : "Play")
                LoopChip(loops: macro.loops, onChange: onSetLoops)
                CardActionButton(systemImage: "slider.horizontal.below.rectangle", tint: .blue, label: "Edit \(macro.name)") { onEdit() }
                    .help("Edit")
                Menu {
                    Button("Rename…") { onStartRename() }
                    Button(macro.favorite ? "Unfavorite" : "Favorite") { onToggleFavorite() }
                    Divider()
                    Button("Notes…") { onOpenNotes() }
                    Button("Add Tag…") { onAddTag() }
                    Button("Assign Hotkey…") { onAssignHotkey() }
                    if macro.hotkey != nil {
                        Button("Clear Hotkey") { onClearHotkey() }
                    }
                    Divider()
                    speedSubmenu()
                    colorSubmenu()
                    chainSubmenu()
                    Divider()
                    Button("Duplicate") { onDuplicate() }
                    Menu("Export") {
                        Button("As TinyRecorder File…") { onExport() }
                        Button("As Text…") { onExportText() }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 17)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 17)
                .accessibilityLabel("More actions")
                .interactiveLift3D(intensity: 0.46, cornerRadius: 5)
            }
        }
    }

    /// What VoiceOver reads for the whole card.
    private var accessibilitySummary: String {
        var parts = [macro.name, durationText]
        if macro.playCount > 0 { parts.append("played \(macro.playCount) times") }
        if macro.hotkey != nil { parts.append("hotkey \(macro.hotkey!.name)") }
        if macro.favorite { parts.append("favorite") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Meta row

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 4) {
            if isPlaying {
                Image(systemName: "waveform.path")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(cardAccentColor(for: macro.accent))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(totalLoops > 0 ? "\(max(1, currentLoop))/\(totalLoops)" : "loop \(max(1, currentLoop))")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(cardAccentColor(for: macro.accent))
                    .contentTransition(.numericText())
            } else {
                Text(durationText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if abs(macro.speed - 1.0) > 0.01 {
                Text(formatSpeed(macro.speed))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.sigViolet)
            }
            if macro.chainTo != nil {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.tertiary)
                    .help(chainTargetName.map { "Chains to \($0)" } ?? "Chained")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Submenus

    @ViewBuilder
    private func speedSubmenu() -> some View {
        Menu("Speed") {
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { v in
                Button {
                    onSetSpeed(v)
                } label: {
                    if abs(macro.speed - v) < 0.01 {
                        Label(formatSpeed(v), systemImage: "checkmark")
                    } else {
                        Text(formatSpeed(v))
                    }
                }
            }
            Divider()
            Button("Custom…") {
                customSpeedText = String(format: "%g", macro.speed)
                showCustomSpeed = true
            }
        }
    }

    @ViewBuilder
    private func colorSubmenu() -> some View {
        Menu("Color") {
            Button {
                onSetAccent(nil)
            } label: {
                if macro.accent == nil {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(accentNames, id: \.self) { name in
                Button {
                    onSetAccent(name)
                } label: {
                    if (macro.accent ?? "").caseInsensitiveCompare(name) == .orderedSame {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chainSubmenu() -> some View {
        let candidates = chainCandidates.filter { $0.0 != macro.id }
        Menu("Chain to") {
            Button {
                onSetChain(nil)
            } label: {
                if macro.chainTo == nil {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }
            if !candidates.isEmpty { Divider() }
            ForEach(candidates, id: \.0) { (id, name) in
                Button {
                    onSetChain(id)
                } label: {
                    if macro.chainTo == id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
    }

    private func formatSpeed(_ v: Double) -> String {
        // 0.5 → "0.5×", 1.0 → "1×", 1.75 → "1.75×"
        let rounded = (v * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))×"
        }
        return String(format: "%g×", rounded)
    }
}

// MARK: - Card pieces

private struct MacroIconView: View {
    let macro: SavedMacro
    let onSetIcon: (String?) -> Void

    private static let symbolPalette: [String] = [
        "wave.3.right", "bolt.fill", "sparkles", "cursorarrow.click",
        "keyboard", "envelope.fill", "doc.fill", "calendar", "message.fill",
        "globe", "terminal.fill", "hammer.fill", "pencil.tip", "paperplane.fill",
        "music.note", "photo.fill", "gamecontroller.fill", "cart.fill",
        "lock.fill", "star.fill",
    ]

    var body: some View {
        let tint = cardAccentColor(for: macro.accent)
        Menu {
            Section("SF Symbol") {
                ForEach(Self.symbolPalette, id: \.self) { s in
                    Button {
                        onSetIcon(s)
                    } label: {
                        Label(s, systemImage: s)
                    }
                }
            }
            Divider()
            Button("Reset", role: .destructive) { onSetIcon(nil) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
                Image(systemName: macro.icon ?? "wave.3.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20, height: 20)
        .help("Change icon")
        .accessibilityLabel("Change icon")
        .interactiveLift3D(intensity: 0.45, cornerRadius: 5)
    }
}

private struct CardActionButton: View {
    let systemImage: String
    let tint: Color
    var label: String = ""
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary))
                .frame(width: 20, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.10 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label.isEmpty ? systemImage : label)
        .interactiveLift3D(intensity: 0.48, cornerRadius: 5)
    }
}

// MARK: - Mini waveform

struct MiniWaveform: View {
    let events: [RecordedEvent]
    var progress: Double? = nil
    var progressTint: Color = Brand.sigGreen

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let total = events.last?.time ?? 0
            let dur = total > 0 ? total : 1
            let bars = sampleEvents(maxBars: 60, width: w, dur: dur)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: h * 0.5)
                    .frame(maxHeight: .infinity, alignment: .center)

                ForEach(bars.indices, id: \.self) { i in
                    let b = bars[i]
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color(for: b.kind).opacity(b.isImpact ? 1.0 : 0.7))
                        .frame(
                            width: b.isImpact ? 2 : 1.2,
                            height: b.isImpact ? h * 0.95 : h * 0.45
                        )
                        .offset(x: b.x)
                }

                if let progress {
                    let clamped = max(0, min(1, progress))
                    Rectangle()
                        .fill(progressTint.opacity(0.10))
                        .frame(width: w * clamped, height: h)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(progressTint)
                        .frame(width: 1.5, height: h)
                        .offset(x: max(0, w * clamped - 1))
                        .shadow(color: progressTint.opacity(0.55), radius: 2)
                        .animation(.linear(duration: 0.10), value: clamped)
                }
            }
        }
    }

    private struct Bar { let x: CGFloat; let kind: RecordedEvent.Kind; let isImpact: Bool }

    private func sampleEvents(maxBars: Int, width: CGFloat, dur: TimeInterval) -> [Bar] {
        guard !events.isEmpty else { return [] }
        let n = min(events.count, maxBars)
        var result: [Bar] = []
        result.reserveCapacity(n)
        for sample in 0..<n {
            // Evenly sample the complete recording, including its final event.
            // Integer division previously exceeded maxBars for many event counts
            // and biased every waveform toward the beginning of the macro.
            let i = n == 1
                ? 0
                : Int((Double(sample) * Double(events.count - 1) / Double(n - 1)).rounded())
            let ev = events[i]
            let x = CGFloat(ev.time / dur) * width
            result.append(Bar(x: x, kind: ev.kind, isImpact: Brand.isImpact(ev.kind)))
        }
        return result
    }

    private func color(for kind: RecordedEvent.Kind) -> Color {
        Brand.eventColor(kind)
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    let filter: LibraryFilter
    let hasSearch: Bool
    let countdownSeconds: Int
    let onPrimaryAction: () -> Void
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 64, height: 64)
                Image(systemName: hasSearch ? "magnifyingglass" : (filter == .favorites ? "star" : "tray"))
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.tertiary)
                    .scaleEffect(bounce ? 1.0 : 0.8)
                    .animation(.spring(response: 0.6, dampingFraction: 0.55), value: bounce)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button(primaryActionTitle, action: onPrimaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(filter == .all && !hasSearch ? Brand.red500 : Color.accentColor)
                .padding(.top, 2)
                .interactiveLift3D(intensity: 0.72, cornerRadius: 8)
        }
        .padding(24)
        .onAppear { bounce = true }
    }

    private var title: String {
        if hasSearch { return "No matches" }
        switch filter {
        case .favorites:  return "No favorites yet"
        case .recent:     return "Nothing recent"
        case .mostPlayed: return "No playback history"
        case .withHotkey: return "No macros with hotkeys"
        case .tag(let t): return "No macros tagged \(t)"
        case .all:        return "No macros yet"
        }
    }

    private var subtitle: String {
        if hasSearch { return "Try a different search term." }
        switch filter {
        case .favorites: return "Tap the ★ on any card to favorite it."
        case .all:
            if countdownSeconds > 0 {
                return "Capture your first macro. Recording begins after a \(countdownSeconds)-second countdown."
            }
            return "Capture your first macro. Recording starts immediately."
        default:         return "Try the All filter."
        }
    }

    private var primaryActionTitle: String {
        if hasSearch { return "Clear Search" }
        return filter == .all ? "Record First Macro" : "Show All Macros"
    }
}

// MARK: - Footer

private struct LibraryFooter: View {
    let controller: MenuBarController
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            FooterRow(
                icon: "plus",
                label: "New macro",
                rightAccessory: AnyView(KeyCapView(text: "⌘R", size: .sm)),
                action: { controller.toggleRecording() }
            )
            FooterRow(
                icon: "slider.horizontal.below.rectangle",
                label: "Open editor",
                rightAccessory: nil,
                action: { controller.openEditor() }
            )
            FooterRow(
                icon: "gearshape",
                label: "Settings",
                rightAccessory: AnyView(KeyCapView(text: "⌘,", size: .sm)),
                action: { controller.showSettingsWindow() }
            )
        }
    }
}

private struct FooterRow: View {
    let icon: String
    let label: String
    let rightAccessory: AnyView?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let r = rightAccessory { r }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .interactiveLift3D(intensity: 0.58, cornerRadius: 6)
    }
}

// MARK: - Permission banner

// Compiled out of "ship" builds via -DHIDE_PERMISSION_BANNER (see build.sh
// TINYRECORDER_SWIFT_FLAGS); normal builds always include it.
#if !HIDE_PERMISSION_BANNER
private struct PermissionBanner: View {
    let controller: MenuBarController
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions required")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Grant Accessibility & Input Monitoring to record and replay.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Open") {
                if !accessibilityGranted {
                    controller.openAccessibilityPrefs()
                } else if !inputMonitoringGranted {
                    controller.openInputMonitoringPrefs()
                }
            }
            .buttonStyle(PillButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.8)
                )
        )
    }
}
#endif

// MARK: - Loop chip

struct LoopChip: View {
    let loops: Int
    let onChange: (Int) -> Void
    @State private var showCustom = false
    @State private var customText = ""
    @State private var hovered = false

    var body: some View {
        Menu {
            Section("Repeat") {
                Button("1× (no loop)") { onChange(1) }
                Button("2×")           { onChange(2) }
                Button("5×")           { onChange(5) }
                Button("10×")          { onChange(10) }
                Button("25×")          { onChange(25) }
                Button("100×")         { onChange(100) }
            }
            Divider()
            Button { onChange(0) } label: { Label("Continuous", systemImage: "infinity") }
            Divider()
            Button("Custom…") {
                customText = loops > 0 ? "\(loops)" : ""
                showCustom = true
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: loops <= 0 ? "infinity" : "repeat")
                    .font(.system(size: 8, weight: .black))
                Text(loops <= 0 ? "∞" : "\(loops)×")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(minWidth: 24)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.10 : 0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(loops <= 0 ? "Repeats continuously" : (loops == 1 ? "Plays once" : "Repeats \(loops) times"))
        .accessibilityLabel(loops <= 0 ? "Repeat: continuous" : "Repeat: \(loops) times")
        .onHover { hovered = $0 }
        .interactiveLift3D(intensity: 0.45, cornerRadius: 5)
        .alert("Custom repeat count", isPresented: $showCustom) {
            TextField("e.g. 42", text: $customText)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                let trimmed = customText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "∞" { onChange(0) }
                else if let n = Int(trimmed) { onChange(normalizedLoopCount(n)) }
            }
        } message: {
            Text("Enter a number, or 0 (or leave blank) for continuous.")
        }
    }
}

// MARK: - Hotkey assignment sheet

private struct HotkeyAssignmentSheet: View {
    let macro: SavedMacro
    let currentHotkey: HotkeyBinding?
    let allHotkeys: Set<UInt32>
    let onSave: (HotkeyBinding?) -> Void
    let onCancel: () -> Void

    @State private var selected: UInt32?

    private let fkeys: [(UInt32, String)] = [
        (KeyCode.f1, "F1"), (KeyCode.f2, "F2"), (KeyCode.f3, "F3"), (KeyCode.f4, "F4"),
        (KeyCode.f5, "F5"), (KeyCode.f6, "F6"), (KeyCode.f7, "F7"), (KeyCode.f8, "F8"),
        (KeyCode.f9, "F9"), (KeyCode.f10, "F10"), (KeyCode.f11, "F11"), (KeyCode.f12, "F12"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign Hotkey").font(.system(size: 14, weight: .semibold))
                Text("Press F-key to play **\(macro.name)** from any app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 6) {
                ForEach(fkeys, id: \.0) { (code, name) in
                    let inUse = allHotkeys.contains(code) && code != currentHotkey?.keyCode
                    Button {
                        selected = code
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(inUse ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected == code ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(selected == code ? Color.accentColor : Color.primary.opacity(0.10),
                                                          lineWidth: selected == code ? 1.4 : 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inUse)
                    .help(inUse ? "Already in use" : "")
                    .interactiveLift3D(intensity: 0.56, cornerRadius: 7)
                }
            }

            HStack {
                if currentHotkey != nil {
                Button("Clear") { onSave(nil) }
                    .controlSize(.regular)
                    .interactiveLift3D(intensity: 0.50, cornerRadius: 7)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .interactiveLift3D(intensity: 0.50, cornerRadius: 7)
                Button("Assign") {
                    if let s = selected, let pair = fkeys.first(where: { $0.0 == s }) {
                        onSave(HotkeyBinding(keyCode: pair.0, name: pair.1))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .interactiveLift3D(intensity: 0.68, cornerRadius: 8)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { selected = currentHotkey?.keyCode }
    }
}

// MARK: - Notes sheet

private struct NotesSheet: View {
    let macro: SavedMacro
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.system(size: 14, weight: .semibold))
                Text("A free-form scratchpad attached to **\(macro.name)**.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                if text.isEmpty {
                    Text("What does this macro do? When did you build it? Any caveats…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .font(.system(size: 12))
            }
            .frame(minHeight: 200, idealHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .interactiveLift3D(intensity: 0.50, cornerRadius: 7)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .interactiveLift3D(intensity: 0.68, cornerRadius: 8)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Tag assignment sheet

private struct TagAssignmentSheet: View {
    let macro: SavedMacro
    let allTags: [String]
    @Binding var tagText: String
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tags").font(.system(size: 14, weight: .semibold))
                Text("Tag **\(macro.name)** to organize your library.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("New tag", text: $tagText, onCommit: {
                    onAdd(tagText)
                })
                .textFieldStyle(.roundedBorder)
                Button("Add") { onAdd(tagText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .interactiveLift3D(intensity: 0.56, cornerRadius: 7)
            }

            if !macro.tags.isEmpty {
                Text("Current").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                FlowChips(items: macro.tags, onRemove: onRemove)
            }
            if !allTags.isEmpty {
                Text("Suggestions").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                FlowChips(items: allTags.filter { !macro.tags.contains($0) }, onRemove: nil, onAdd: onAdd)
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .interactiveLift3D(intensity: 0.68, cornerRadius: 8)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct FlowChips: View {
    let items: [String]
    let onRemove: ((String) -> Void)?
    var onAdd: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { t in
                    HStack(spacing: 4) {
                        Text(t).font(.system(size: 10, weight: .semibold))
                        if let onRemove {
                            Button { onRemove(t) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .onTapGesture { onAdd?(t) }
                    .interactiveLift3D(intensity: 0.38, cornerRadius: 999)
                }
            }
        }
    }
}

// MARK: - Settings panel

struct SettingsPanel: View {
    let controller: MenuBarController
    /// True when hosted in the dedicated Settings window.
    var inWindow: Bool = false
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: MacroLibrary

    @State private var showCustomLoop = false
    @State private var customLoopText = ""

    private let fkeys: [(UInt32, String)] = [
        (KeyCode.f1, "F1"), (KeyCode.f2, "F2"), (KeyCode.f3, "F3"), (KeyCode.f4, "F4"),
        (KeyCode.f5, "F5"), (KeyCode.f6, "F6"), (KeyCode.f7, "F7"), (KeyCode.f8, "F8"),
        (KeyCode.f9, "F9"), (KeyCode.f10, "F10"), (KeyCode.f11, "F11"), (KeyCode.f12, "F12"),
    ]

    private var appVersion: String {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        return "v" + short
    }

    /// F-keys that another binding already owns (other globals + macro hotkeys).
    private func takenKeyCodes(excluding current: UInt32) -> Set<UInt32> {
        var taken: Set<UInt32> = [
            state.recordHotkey.keyCode,
            state.stopHotkey.keyCode,
            state.playHotkey.keyCode,
        ]
        for m in library.macros {
            if let hk = m.hotkey { taken.insert(hk.keyCode) }
        }
        taken.remove(current)
        return taken
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: inWindow ? .windowBackground : .popover)
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader

                if inWindow {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            generalGroup
                            recordingGroup
                            permissionsGroup
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 14) {
                            hotkeysGroup
                            playbackGroup
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    hotkeysGroup
                    generalGroup
                    recordingGroup
                    playbackGroup
                    permissionsGroup
                }

                settingsFooter
            }
            .padding(inWindow ? 18 : 14)
        }
        .frame(width: inWindow ? 580 : 340)
        .alert("Custom loop count", isPresented: $showCustomLoop) {
            TextField("e.g. 42", text: $customLoopText)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                let trimmed = customLoopText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "∞" { state.loops = 0 }
                else if let n = Int(trimmed) { state.loops = normalizedLoopCount(n) }
            }
        } message: {
            Text("Enter a number, or 0 (or leave blank) for continuous.")
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            BrandMark(size: inWindow ? 32 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("TinyRecorder")
                    .font(.system(size: inWindow ? 16 : 13, weight: .semibold))
                Text("Recording and playback preferences")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(appVersion)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var hotkeysGroup: some View {
        settingsGroup("Hotkeys", systemImage: "keyboard") {
            hotkeyRow(title: "Record / Stop", binding: Binding(
                get: { state.recordHotkey },
                set: { state.recordHotkey = $0; controller.reapplyHotkeys() }
            ))
            hotkeyRow(title: "Stop everything", binding: Binding(
                get: { state.stopHotkey },
                set: { state.stopHotkey = $0; controller.reapplyHotkeys() }
            ))
            hotkeyRow(title: "Play", binding: Binding(
                get: { state.playHotkey },
                set: { state.playHotkey = $0; controller.reapplyHotkeys() }
            ))
        }
    }

    private var generalGroup: some View {
        settingsGroup("General", systemImage: "macwindow") {
            HStack {
                Text("Show as").font(.system(size: 11.5))
                Spacer()
                Picker("", selection: Binding(
                    get: { state.menuBarOnly },
                    set: { controller.setMenuBarOnly($0) }
                )) {
                    Text("Dock app").tag(false)
                    Text("Menu bar only").tag(true)
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Text("Menu bar only hides the Dock icon. Open TinyRecorder from its menu-bar icon.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingGroup: some View {
        settingsGroup("Recording", systemImage: "record.circle") {
            HStack {
                Text("Countdown").font(.system(size: 11.5))
                Spacer()
                Picker("", selection: $state.countdownSeconds) {
                    Text("Off").tag(0)
                    Text("1s").tag(1)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                }
                .labelsHidden()
                .frame(width: 100)
            }
            Toggle("Show floating HUD", isOn: $state.showRecordingHUD)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Sound effects", isOn: $state.soundEnabled)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var playbackGroup: some View {
        settingsGroup("Default playback", systemImage: "play.circle") {
            HStack {
                Text("Repeat").font(.system(size: 11.5))
                Spacer()
                Menu {
                    Button("1× (no loop)") { state.loops = 1 }
                    Button("2×") { state.loops = 2 }
                    Button("5×") { state.loops = 5 }
                    Button("10×") { state.loops = 10 }
                    Button("25×") { state.loops = 25 }
                    Button("100×") { state.loops = 100 }
                    Divider()
                    Button { state.loops = 0 } label: { Label("Continuous", systemImage: "infinity") }
                    Divider()
                    Button("Custom…") {
                        customLoopText = state.loops > 0 ? "\(state.loops)" : ""
                        showCustomLoop = true
                    }
                } label: {
                    Text(state.loops <= 0 ? "∞ Continuous" : "\(state.loops)×")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 115)
            }
            HStack {
                Text("Speed").font(.system(size: 11.5))
                Spacer()
                Picker("", selection: $state.speed) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .labelsHidden()
                .frame(width: 100)
            }
            Toggle("Hide TinyRecorder while playing", isOn: $state.hideDuringPlayback)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.mini)
            Text("Prevents recorded coordinates from clicking TinyRecorder's own windows.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsGroup: some View {
        settingsGroup("Permissions", systemImage: "lock.shield") {
            permissionRow(title: "Accessibility",
                          granted: state.accessibilityGranted,
                          action: controller.openAccessibilityPrefs)
            permissionRow(title: "Input Monitoring",
                          granted: state.inputMonitoringGranted,
                          action: controller.openInputMonitoringPrefs)
        }
    }

    private var settingsFooter: some View {
        HStack {
            Button("Replay Welcome") { controller.showWelcome() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .interactiveLift3D(intensity: 0.44, cornerRadius: 6)
            Spacer()
            Button("Quit TinyRecorder") { controller.quit() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .interactiveLift3D(intensity: 0.44, cornerRadius: 6)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
            }
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .cardSurface(cornerRadius: 10)
        }
    }

    /// One permission row: shows a green "Granted" status when the permission is
    /// held, or a blue "Grant…" button (opens System Settings) when it isn't — so
    /// an already-granted permission never lingers looking like an open prompt.
    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5))
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Granted")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
            } else {
                Button("Grant…") { action() }
                    .buttonStyle(PillButtonStyle(tint: .blue))
            }
        }
    }

    private func hotkeyRow(title: String, binding: Binding<HotkeyBinding>) -> some View {
        let taken = takenKeyCodes(excluding: binding.wrappedValue.keyCode)
        return HStack {
            Text(title).font(.system(size: 11.5))
            Spacer()
            Picker("", selection: Binding(
                get: { binding.wrappedValue.keyCode },
                set: { newValue in
                    // Refuse keys owned by another global or a macro hotkey —
                    // double-registering the same Carbon key breaks both.
                    guard !taken.contains(newValue) else {
                        state.statusMessage = "That key is already assigned."
                        return
                    }
                    if let pair = fkeys.first(where: { $0.0 == newValue }) {
                        binding.wrappedValue = HotkeyBinding(keyCode: pair.0, name: pair.1)
                    }
                }
            )) {
                ForEach(fkeys, id: \.0) { pair in
                    Text(taken.contains(pair.0) ? "\(pair.1) (in use)" : pair.1)
                        .tag(pair.0)
                        .disabled(taken.contains(pair.0))
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }
}

// MARK: - Pill button style

struct PillButtonStyle: ButtonStyle {
    var tint: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .prominentGlassCapsule(tint: tint)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(.spring(response: 0.16, dampingFraction: 0.6), value: configuration.isPressed)
            .interactiveLift3D(intensity: 0.78, cornerRadius: 999)
    }
}
