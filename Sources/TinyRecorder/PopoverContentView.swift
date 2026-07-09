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
    /// Deterministic anchor for shift-click range selection.
    @State private var lastAnchorID: UUID?

    private var filteredMacros: [SavedMacro] {
        library.macros(for: filter, search: search)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: isWindow ? .windowBackground : .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            if isWindow {
                VStack(spacing: 0) {
                    // Custom titlebar strip: wordmark centered, traffic lights
                    // live in the leading inset.
                    ZStack {
                        Wordmark(size: 13)
                    }
                    .frame(height: 38)
                    .frame(maxWidth: .infinity)
                    .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
                    .overlay(Divider().opacity(0.5), alignment: .bottom)

                    HStack(spacing: 0) {
                        LibrarySidebar(filter: $filter)
                            .frame(width: 200)
                        Divider().opacity(0.5)
                        libraryColumn
                    }
                }
            } else {
                libraryColumn
            }

            // File-drop overlay (shown only while user is dragging .tinyrec files in)
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
        .frame(
            minWidth: isWindow ? 600 : 400,
            idealWidth: isWindow ? 880 : 400,
            maxWidth: isWindow ? .infinity : 400,
            minHeight: isWindow ? 520 : 540,
            idealHeight: isWindow ? 620 : 540,
            maxHeight: isWindow ? .infinity : 540
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.accessibilityGranted)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.inputMonitoringGranted)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filteredMacros.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filter)
        .onChange(of: filter) { selection.removeAll() }
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
                isWindow: isWindow,
                macroCount: library.macros.count
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

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

            if filteredMacros.isEmpty {
                EmptyState(filter: filter, hasSearch: !search.isEmpty)
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
                            ? [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)]
                            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: isWindow ? 10 : 8
                    ) {
                        ForEach(filteredMacros) { macro in
                            MacroCard(
                                macro: macro,
                                isCurrent: macro.id == library.currentMacroID,
                                isSelected: selection.contains(macro.id),
                                isRenaming: renamingID == macro.id,
                                renameText: $renameText,
                                onSelect: { event in
                                    handleCardSelect(macro: macro, event: event)
                                },
                                onPlay: {
                                    selection.removeAll()
                                    controller.playMacroByID(macro.id)
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }

            // Transient status / feedback line (auto-clears).
            if !state.statusMessage.isEmpty {
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

            Divider().opacity(0.5)

            LibraryFooter(controller: controller, state: state)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }

    /// Clears the status line a few seconds after the latest message.
    private func scheduleStatusClear() {
        let snapshot = state.statusMessage
        guard !snapshot.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if state.statusMessage == snapshot {
                withAnimation(.easeOut(duration: 0.25)) { state.statusMessage = "" }
            }
        }
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
        .buttonStyle(HoverPressButtonStyle(hoverScale: 1.05))
        .accessibilityLabel("Filter: \(item.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar (window mode)

private struct LibrarySidebar: View {
    @Binding var filter: LibraryFilter
    @EnvironmentObject var library: MacroLibrary

    private let filterItems: [LibraryFilter] = [.all, .favorites, .recent, .mostPlayed, .withHotkey]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("LIBRARY")
                    ForEach(filterItems, id: \.self) { item in
                        sidebarRow(item)
                    }

                    if !library.allTags.isEmpty {
                        sectionHeader("TAGS")
                            .padding(.top, 14)
                        ForEach(library.allTags, id: \.self) { t in
                            sidebarRow(.tag(t))
                        }
                    }

                    sectionHeader("STATS")
                        .padding(.top, 14)
                    StatsSummary()
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(item.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StatsSummary: View {
    @EnvironmentObject var library: MacroLibrary

    private var totalMacros: Int { library.macros.count }
    private var totalPlays: Int { library.macros.reduce(0) { $0 + $1.playCount } }
    private var totalSaved: TimeInterval { library.macros.reduce(0) { $0 + $1.totalRunTime } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Macros", "\(totalMacros)", icon: "tray.full")
            statRow("Total plays", "\(totalPlays)", icon: "play.circle")
            statRow("Time replayed", formatDuration(totalSaved), icon: "clock")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4), value: value)
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 60 { return String(format: "%ds", Int(d)) }
        if d < 3600 { return String(format: "%dm", Int(d / 60)) }
        return String(format: "%.1fh", d / 3600)
    }
}

// MARK: - Header

private struct LibraryHeader: View {
    let controller: MenuBarController
    @Binding var search: String
    let isWindow: Bool
    let macroCount: Int
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var player: Player
    @EnvironmentObject var state: AppState

    private var statusText: String {
        if recorder.isRecording { return "Recording…" }
        if player.isPlaying     { return "Playing…" }
        return "Idle · \(macroCount) macro\(macroCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 10) {
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
                    .buttonStyle(HoverPressButtonStyle(hoverScale: 1.06))
                    .accessibilityLabel("Settings")
                }
            }

            // Big record button
            Button {
                controller.toggleRecording()
            } label: {
                HStack(spacing: 10) {
                    if recorder.isRecording {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .black))
                    } else {
                        RecDot(size: 8, glassWhite: true)
                    }
                    Text(recorder.isRecording ? "Stop recording" : "Start recording")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.1)
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        KeyCapView(text: state.recordHotkey.name, size: .sm, variant: .glass)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Brand.redGradient)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.20), lineWidth: 0.5))
                        .shadow(color: Brand.red500.opacity(0.36), radius: 10, x: 0, y: 5)
                )
            }
            .buttonStyle(HoverPressButtonStyle(hoverScale: 1.012))
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search macros", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if search.isEmpty {
                    KeyCapView(text: "⌘", size: .sm)
                    KeyCapView(text: "K", size: .sm)
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
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            )
        }
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
            Text("\(selectionCount) selected")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button("Add Tag…", systemImage: "tag", action: onAddTag)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectionCount != 1)

            Button("Export", systemImage: "square.and.arrow.up", action: onExport)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
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
        if isCurrent { return cardAccentColor(for: macro.accent).opacity(0.55) }
        if dragOver { return Color.accentColor.opacity(0.6) }
        return Color.primary.opacity(0.10)
    }

    var body: some View {
        styledCard
            .onHover { hovered = $0 }
            .onTapGesture {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                onSelect(mods)
            }
            // Keyboard + assistive access: the card is one focusable element with
            // every action exposed; Delete key removes, Escape commits a rename.
            .focusable()
            .focused($cardFocused)
            .focusEffectDisabled()
            .onDeleteCommand { onDelete() }
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
            .accessibilityAction(named: "Delete") { onDelete() }
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
            .padding(11)
            .frame(height: macro.tags.isEmpty ? 102 : 124)
            .background { cardBackground }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: isCurrent ? 1.0 : 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(cardFocused ? 0.9 : 0), lineWidth: 2.5)
            )
            .shadow(
                color: .black.opacity(hovered ? 0.16 : 0.07),
                radius: hovered ? 7 : 3,
                y: hovered ? 3 : 1.5
            )
            .scaleEffect(hovered ? 1.012 : 1.0)
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
            shape.fill(tint.opacity(isCurrent ? 0.055 : 0))
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
        Button("Delete", role: .destructive) { onDelete() }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                        .font(.system(size: 12, weight: .semibold))
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
                }

                if let hk = macro.hotkey {
                    Button(action: onAssignHotkey) {
                        KeyCapView(text: hk.name)
                    }
                    .buttonStyle(.plain)
                    .help("Hotkey: \(hk.name) — click to change")
                }

                Button(action: onToggleFavorite) {
                    Image(systemName: macro.favorite ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(macro.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help(macro.favorite ? "Unstar" : "Star")
                .accessibilityLabel(macro.favorite ? "Remove favorite" : "Add favorite")
            }

            // Tiny waveform
            MiniWaveform(events: macro.events)
                .frame(height: 18)

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
                CardActionButton(systemImage: "play.fill", tint: .green, label: "Play \(macro.name)") { onPlay() }
                    .help("Play")
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
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 18)
                .accessibilityLabel("More actions")
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
            Text(durationText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
                Image(systemName: macro.icon ?? "wave.3.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .help("Change icon")
        .accessibilityLabel("Change icon")
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
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.10 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label.isEmpty ? systemImage : label)
    }
}

// MARK: - Mini waveform

struct MiniWaveform: View {
    let events: [RecordedEvent]

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
            }
        }
    }

    private struct Bar { let x: CGFloat; let kind: RecordedEvent.Kind; let isImpact: Bool }

    private func sampleEvents(maxBars: Int, width: CGFloat, dur: TimeInterval) -> [Bar] {
        guard !events.isEmpty else { return [] }
        let n = min(events.count, maxBars)
        let stride = max(1, events.count / n)
        var result: [Bar] = []
        var i = 0
        while i < events.count {
            let ev = events[i]
            let x = CGFloat(ev.time / dur) * width
            result.append(Bar(x: x, kind: ev.kind, isImpact: Brand.isImpact(ev.kind)))
            i += stride
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
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 88, height: 88)
                Image(systemName: hasSearch ? "magnifyingglass" : (filter == .favorites ? "star" : "tray"))
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .scaleEffect(bounce ? 1.0 : 0.8)
                    .animation(.spring(response: 0.6, dampingFraction: 0.55), value: bounce)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(40)
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
        case .all:       return "Press Record to capture your first macro. TinyRecorder will count down 3 seconds before it begins."
        default:         return "Try the All filter."
        }
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
                rightAccessory: AnyView(KeyCapView(text: "⌘R")),
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
                rightAccessory: AnyView(KeyCapView(text: "⌘,")),
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer()
                if let r = rightAccessory { r }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions required")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Grant Accessibility & Input Monitoring to record and replay.")
                    .font(.system(size: 10.5))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .alert("Custom repeat count", isPresented: $showCustom) {
            TextField("e.g. 42", text: $customText)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                let trimmed = customText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "∞" { onChange(0) }
                else if let n = Int(trimmed) { onChange(max(0, n)) }
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
                }
            }

            HStack {
                if currentHotkey != nil {
                    Button("Clear") { onSave(nil) }
                        .controlSize(.regular)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Assign") {
                    if let s = selected, let pair = fkeys.first(where: { $0.0 == s }) {
                        onSave(HotkeyBinding(keyCode: pair.0, name: pair.1))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
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
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
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
            HStack(spacing: 4) {
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
        for m in controller.library.macros {
            if let hk = m.hotkey { taken.insert(hk.keyCode) }
        }
        taken.remove(current)
        return taken
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: inWindow ? .windowBackground : .popover)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                }

                settingsGroup("Hotkeys", systemImage: "keyboard") {
                    hotkeyRow(title: "Record / Stop recording", binding: Binding(
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
                        .frame(width: 140)
                    }
                    Text("Menu bar only hides the Dock icon — open TinyRecorder from the menu-bar icon.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                        .frame(width: 110)
                    }
                    Toggle(isOn: $state.showRecordingHUD) {
                        Text("Show floating HUD").font(.system(size: 11.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Toggle(isOn: $state.soundEnabled) {
                        Text("Sound effects").font(.system(size: 11.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

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
                        .frame(width: 120)
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
                        .frame(width: 110)
                    }
                }

                settingsGroup("Permissions", systemImage: "lock.shield") {
                    permissionRow(title: "Accessibility",
                                  granted: state.accessibilityGranted,
                                  action: controller.openAccessibilityPrefs)
                    permissionRow(title: "Input Monitoring",
                                  granted: state.inputMonitoringGranted,
                                  action: controller.openInputMonitoringPrefs)
                }

                HStack {
                    Button("Replay welcome") { controller.showWelcome() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("Quit") { controller.quit() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
        .frame(width: 340)
        .alert("Custom loop count", isPresented: $showCustomLoop) {
            TextField("e.g. 42", text: $customLoopText)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                let trimmed = customLoopText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "∞" { state.loops = 0 }
                else if let n = Int(trimmed) { state.loops = max(0, n) }
            }
        } message: {
            Text("Enter a number, or 0 (or leave blank) for continuous.")
        }
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
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .prominentGlassCapsule(tint: tint)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovered ? 1.04 : 1.0))
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovered)
            .animation(.spring(response: 0.16, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}
